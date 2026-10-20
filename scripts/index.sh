#!/bin/sh
# Entrypoint of the indexer Container Apps Job.
# Restores the LLM cache (so re-indexing unchanged text is nearly free),
# builds the index, then publishes output/ and cache/ to blob storage.
set -eu
cd /app

python -m app.blob_sync download cache
graphrag index --root project --verbose
python -m app.blob_sync upload output cache
echo "indexing complete"
