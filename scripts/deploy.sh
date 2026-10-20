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
az config set extension.use_dynamic_install=yes_without_prompt -o none 2>/dev/null  # containerapp extension

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
az acr build -r "$REGISTRY" -t "graphrag:$TAG" . -o none

echo "==> 3/4 pointing the API and indexer job at the new image"
az deployment group create -g "$RG" -n main -f infra/main.bicep \
  -p apiKey="$API_KEY" image="$SERVER/graphrag:$TAG" -o none

echo "==> 4/4 indexing"
./scripts/reindex.sh

echo
echo "API:     $(output apiUrl)"
echo "API key: in .deploy.env"
