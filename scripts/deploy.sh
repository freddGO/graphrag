#!/usr/bin/env bash
# Provision everything, build the image in Azure, and run the first index.
#
#   az login && az account set -s <subscription>
#   ./scripts/deploy.sh
#
# Overridable: RG (default rg-graphrag), LOCATION (default eastus2).
# The API key is generated once and kept in .deploy.env (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."

RG="${RG:-rg-graphrag}"
LOCATION="${LOCATION:-eastus2}"
export MSYS_NO_PATHCONV=1  # Git Bash: don't rewrite /subscriptions/... into Windows paths
az config set extension.use_dynamic_install=yes_without_prompt -o none 2>/dev/null  # containerapp extension

echo "==> 0/4 registering resource providers (first run on a new subscription takes a minute)"
for ns in Microsoft.App Microsoft.CognitiveServices Microsoft.ContainerRegistry \
          Microsoft.OperationalInsights Microsoft.Storage Microsoft.ManagedIdentity; do
  az provider register -n "$ns" --wait -o none
done

touch .deploy.env
# shellcheck disable=SC1091
. ./.deploy.env
if [ -z "${API_KEY:-}" ]; then
  API_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
  echo "API_KEY=$API_KEY" >> .deploy.env
fi

output() { az deployment group show -g "$RG" -n main --query "properties.outputs.$1.value" -o tsv; }

echo "==> 1/4 resource group + infrastructure (placeholder image)"
az group create -n "$RG" -l "$LOCATION" -o none
if az containerapp show -g "$RG" -n ca-graphrag-api -o none 2>/dev/null; then
  # Already deployed: keep the current image so a re-run doesn't swap in the placeholder.
  IMAGE="$(az containerapp show -g "$RG" -n ca-graphrag-api --query 'properties.template.containers[0].image' -o tsv)"
  az deployment group create -g "$RG" -n main -f infra/main.bicep -p apiKey="$API_KEY" image="$IMAGE" -o none
else
  az deployment group create -g "$RG" -n main -f infra/main.bicep -p apiKey="$API_KEY" -o none
fi

REGISTRY="$(output registryName)"
SERVER="$(output registryServer)"
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"

echo "==> 2/4 building image $SERVER/graphrag:$TAG in Azure (no local Docker needed)"
# Queue the build without streaming logs: on Windows, az crashes printing non-ASCII
# build output. Poll instead, and on failure fetch the raw log over REST.
# (-g everywhere: ignore any default group set with `az config`.)
RUN_ID="$(az acr build -g "$RG" -r "$REGISTRY" -t "graphrag:$TAG" . --no-logs --query runId -o tsv)"
while :; do
  STATUS="$(az acr task show-run -g "$RG" -r "$REGISTRY" --run-id "$RUN_ID" --query status -o tsv)"
  case "$STATUS" in
    Succeeded) echo "build $RUN_ID succeeded"; break ;;
    Queued|Started|Running) echo "  $(date +%H:%M:%S) build $RUN_ID $STATUS"; sleep 20 ;;
    *)
      echo "build $RUN_ID $STATUS - log:"
      SUB="$(az account show --query id -o tsv)"
      LOG_URL="$(az rest --method post --query logLink -o tsv --url \
        "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/$REGISTRY/runs/$RUN_ID/listLogSasUrl?api-version=2019-06-01-preview")"
      curl -fsS "$LOG_URL" | tail -40
      exit 1 ;;
  esac
done

echo "==> 3/4 pointing the API and indexer job at the new image"
az deployment group create -g "$RG" -n main -f infra/main.bicep \
  -p apiKey="$API_KEY" image="$SERVER/graphrag:$TAG" -o none

echo "==> 4/4 indexing"
./scripts/reindex.sh

echo
echo "API:     $(output apiUrl)"
echo "API key: in .deploy.env"
