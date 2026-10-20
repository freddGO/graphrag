#!/usr/bin/env bash
# Ask the deployed API a question.
#   ./scripts/ask.sh local  "What is Priya Nair's role and why is it controversial?"
#   ./scripts/ask.sh global "What are the main themes in these documents?"
set -euo pipefail
cd "$(dirname "$0")/.."

RG="${RG:-rg-graphrag}"
# shellcheck disable=SC1091
. ./.deploy.env
API_URL="$(az deployment group show -g "$RG" -n main --query properties.outputs.apiUrl.value -o tsv)"

METHOD="$1"; shift
BODY="$(python -c 'import json,sys; print(json.dumps({"method": sys.argv[1], "query": sys.argv[2]}))' "$METHOD" "$*")"
curl -fsS "$API_URL/query" -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" -d "$BODY" \
  | python -c 'import json,sys; print(json.load(sys.stdin)["response"])'
