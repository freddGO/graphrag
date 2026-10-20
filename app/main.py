"""HTTP API over the GraphRAG v3 query engine.

    GET  /health        -> is the index loaded?
    POST /query         -> {"query": "...", "method": "local|global|drift|basic"}
    POST /reload        -> re-download the index after a re-index
    GET  /tables/{name} -> an index table as JSON (for scripts/inspect.py)

Every endpoint except /health requires the `X-API-Key` header, so strangers
can't spend your Azure OpenAI tokens.
"""
import asyncio
import logging
import os
import secrets
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

import graphrag.api as api
from fastapi import Depends, FastAPI, Header, HTTPException, Response
from graphrag.config.load_config import load_config
from graphrag.data_model.data_reader import DataReader
from graphrag_storage import create_storage
from graphrag_storage.tables.table_provider_factory import create_table_provider
from pydantic import BaseModel

from app import blob_sync

log = logging.getLogger("graphrag-api")
ROOT = Path(os.getenv("GRAPHRAG_ROOT", "project"))
TABLES = ["entities", "communities", "community_reports", "text_units", "relationships"]

state: dict = {"config": None, "tables": None, "error": "index not loaded yet"}


async def load_index() -> None:
    """Download the index from blob storage (in Azure) and read it into DataFrames.

    Mirrors what `graphrag query` does in graphrag/cli/query.py.
    """
    try:
        if blob_sync.enabled():
            files = await asyncio.to_thread(blob_sync.download, "output")
            log.info("downloaded %d index files", files)
        config = load_config(root_dir=ROOT)
        provider = create_table_provider(config.table_provider, storage=create_storage(config.output_storage))
        reader = DataReader(provider)
        tables = {name: await getattr(reader, name)() for name in TABLES}
        tables["covariates"] = await reader.covariates() if await provider.has("covariates") else None
        state.update(config=config, tables=tables, error=None)
        log.info("index loaded: %d entities, %d communities", len(tables["entities"]), len(tables["communities"]))
    except Exception as exc:  # keep serving /health so the problem is visible
        log.exception("could not load index")
        state.update(config=None, tables=None, error=f"{type(exc).__name__}: {exc}")


@asynccontextmanager
async def lifespan(_: FastAPI):
    await load_index()
    yield


app = FastAPI(title="GraphRAG API", lifespan=lifespan)


def require_key(x_api_key: str = Header(default="")) -> None:
    expected = os.getenv("API_KEY", "")
    if not expected or not secrets.compare_digest(x_api_key, expected):
        raise HTTPException(status_code=401, detail="invalid or missing X-API-Key")


class QueryRequest(BaseModel):
    query: str
    method: Literal["local", "global", "drift", "basic"] = "local"
    community_level: int = 2
    response_type: str = "Multiple Paragraphs"


@app.get("/health")
def health():
    tables = state["tables"]
    return {
        "ready": tables is not None,
        "error": state["error"],
        "counts": {name: len(df) for name, df in tables.items() if df is not None} if tables else {},
    }


@app.post("/query", dependencies=[Depends(require_key)])
async def query(req: QueryRequest):
    config, t = state["config"], state["tables"]
    if t is None:
        raise HTTPException(status_code=503, detail=f"index not ready: {state['error']}")

    common = {"config": config, "response_type": req.response_type, "query": req.query}
    if req.method == "global":
        response, _ = await api.global_search(
            **common, entities=t["entities"], communities=t["communities"],
            community_reports=t["community_reports"], community_level=req.community_level,
            dynamic_community_selection=False,
        )
    elif req.method == "local":
        response, _ = await api.local_search(
            **common, entities=t["entities"], communities=t["communities"],
            community_reports=t["community_reports"], text_units=t["text_units"],
            relationships=t["relationships"], covariates=t["covariates"],
            community_level=req.community_level,
        )
    elif req.method == "drift":
        response, _ = await api.drift_search(
            **common, entities=t["entities"], communities=t["communities"],
            community_reports=t["community_reports"], text_units=t["text_units"],
            relationships=t["relationships"], community_level=req.community_level,
        )
    else:
        response, _ = await api.basic_search(**common, text_units=t["text_units"])
    return {"method": req.method, "response": response}


@app.get("/tables/{name}", dependencies=[Depends(require_key)])
def table(name: Literal["entities", "relationships", "communities", "community_reports", "text_units"], limit: int = 1000):
    """Return an index table exactly as GraphRAG wrote it (parquet -> JSON records)."""
    if state["tables"] is None:
        raise HTTPException(status_code=503, detail=f"index not ready: {state['error']}")
    df = state["tables"][name].head(limit)
    return Response(content=df.to_json(orient="records", default_handler=str), media_type="application/json")


@app.post("/reload", dependencies=[Depends(require_key)])
async def reload():
    await load_index()
    return health()
