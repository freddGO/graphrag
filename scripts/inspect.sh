#!/usr/bin/env bash
# Print the index tables. See scripts/inspect.py for options.
set -euo pipefail
cd "$(dirname "$0")/.."

RG="${RG:-rg-graphrag}"
# shellcheck disable=SC1091
. ./.deploy.env
export API_KEY
export API_URL="$(az deployment group show -g "$RG" -n main --query properties.outputs.apiUrl.value -o tsv)"
python scripts/inspect.py "$@"
