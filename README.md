# GraphRAG on Azure

A production-style deployment of [Microsoft GraphRAG](https://github.com/microsoft/graphrag) **v3.3.0** on Azure:
- an indexing job that builds the knowledge graph,
- an HTTP API that answers questions with local, global, DRIFT or basic search,
- Bicep infrastructure that authenticates every service with **managed identity**, so there are no keys in code or config.

For a from-scratch walkthrough of what GraphRAG does internally, see the companion
[tiny GraphRAG tutorial](https://github.com/freddGO/portfolio/tree/main/graphrag-tutorial).

## Architecture

```
              ┌──────────────────────── resource group ────────────────────────┐
              │                                                                │
 deploy.sh ──►│  Container Registry ◄── az acr build (image built in Azure)    │
              │        │ AcrPull                                               │
              │        ▼                                                       │
              │  ┌─ Container Apps environment ──────────────────────────┐     │
              │  │                                                       │     │
              │  │  Job  caj-graphrag-index   graphrag index ──► upload  │     │
              │  │  App  ca-graphrag-api      FastAPI /query ◄── download│     │
              │  └───────────┬──────────────────────────┬────────────────┘     │
              │   managed identity (user-assigned)      │                      │
              │              ▼                          ▼                      │
              │  Azure OpenAI                    Blob Storage                  │
              │  · gpt-4.1-mini (chat)           · output/  (parquet + LanceDB)│
              │  · text-embedding-3-small        · cache/   (LLM call cache)   │
              └────────────────────────────────────────────────────────────────┘
```

| Piece | File | What it does |
|---|---|---|
| GraphRAG config | `project/settings.yaml` | v3 schema: Azure OpenAI via `azure_managed_identity`, file storage, LanceDB vectors |
| Corpus | `project/input/*.txt` | Three short fictional documents, so answers can only come from the graph |
| Prompts | generated at build | `graphrag init` runs in the Dockerfile, so prompts always match the library version |
| Indexer | `scripts/index.sh` | Restore cache → `graphrag index` → publish `output/` + `cache/` to blob |
| API | `app/main.py` | Loads the index tables like `graphrag query` does, then calls `graphrag.api.*_search` |
| Blob sync | `app/blob_sync.py` | Copies `output/` and `cache/` between the container disk and blob storage |
| Infra | `infra/main.bicep` | OpenAI, storage, ACR, Log Analytics, Container Apps env/app/job, RBAC |

### Design choices
- **Managed identity everywhere.** Azure OpenAI and storage have key auth **disabled**
  (`disableLocalAuth`, `allowSharedKeyAccess: false`). The containers get tokens from their
  user-assigned identity through `DefaultAzureCredential`.
- **The image is built in the cloud** with `az acr build`, so you don't need Docker locally.
- **GraphRAG uses plain file storage**, and blob sync is a separate ~50-line module. This keeps
  `settings.yaml` close to the library defaults and makes the index portable.
- **The cache is persisted**, so re-indexing unchanged documents costs almost nothing in LLM calls.
- **The API scales to zero** (`minReplicas: 0`). The first request after idle time waits for a cold start.
- **The API requires a key** (`X-API-Key`). The endpoint is public, so without it anyone could
  spend your Azure OpenAI tokens.

## Deploy

Requirements: [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), bash
(Git Bash on Windows), Python, and an Azure subscription where you can create role assignments
(Owner, or Contributor + User Access Administrator) and have Azure OpenAI quota.

```bash
az login
az account set -s <subscription-id>
./scripts/deploy.sh                  # RG=rg-graphrag LOCATION=eastus2 by default
```

`deploy.sh` provisions the infrastructure, builds and pushes the image, rolls it out,
runs the first index and reloads the API. The generated API key is saved in `.deploy.env`
(gitignored).

## Use

```bash
./scripts/ask.sh local  "What is Priya Nair's role and why is it controversial?"
./scripts/ask.sh global "What are the main themes in these documents?"
./scripts/ask.sh drift  "How did the storm affect Northwind Robotics?"
./scripts/ask.sh basic  "Who leads the marine science program?"
```

Or call the API directly:

```bash
curl -X POST "$API_URL/query" -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
     -d '{"query": "Who did Samuel Okafor argue with?", "method": "local"}'
curl "$API_URL/health"     # index status + table row counts
```

| Method | Best for | How it works |
|---|---|---|
| `local` | Questions about specific entities | Embeds the query, finds nearby entities, adds their relationships, text units and community reports |
| `global` | "What are the main themes?" | Map-reduce over community reports |
| `drift` | Exploratory questions | Starts from community reports, then runs local follow-up queries |
| `basic` | Baseline comparison | Plain vector RAG over the text chunks |

## Change the data

Put `.txt` files in `project/input/`, then rebuild and re-index:

```bash
./scripts/deploy.sh      # rebuilds the image with the new input, then re-indexes
./scripts/reindex.sh     # re-index only (same image)
```

To tune prompts for your domain, run `graphrag prompt-tune` and commit the results to
`project/prompts/`. Committed prompts override the defaults generated at build time.

## Cost

With the sample corpus, indexing makes a few dozen LLM calls, which costs cents.
The fixed costs are small: Container Registry Basic (~$5/month), Log Analytics ingestion
and storage. The API and job only cost money while they run.

To remove everything:

```bash
az group delete -n rg-graphrag --yes
```

Azure OpenAI accounts are soft-deleted. Run `az cognitiveservices account purge` if you
need to reuse the name.
