"""Copy GraphRAG folders between the local project root and Azure Blob Storage.

GraphRAG reads and writes plain files. In Azure, the indexer job uploads its
results here when it finishes, and the API downloads them when it starts:

    python -m app.blob_sync download cache
    python -m app.blob_sync upload output cache

Authentication uses DefaultAzureCredential (the container's managed identity
in Azure, or your `az login` locally).
"""
import os
import sys
from pathlib import Path

from azure.identity import DefaultAzureCredential
from azure.storage.blob import ContainerClient

ROOT = Path(os.getenv("GRAPHRAG_ROOT", "project"))


def enabled() -> bool:
    return bool(os.getenv("STORAGE_ACCOUNT_URL"))


def _container() -> ContainerClient:
    return ContainerClient(
        account_url=os.environ["STORAGE_ACCOUNT_URL"],
        container_name=os.getenv("STORAGE_CONTAINER", "graphrag"),
        credential=DefaultAzureCredential(),
    )


def upload(folder: str) -> int:
    """Replace blobs under `folder/` with the local folder's contents."""
    container = _container()
    base = ROOT / folder
    if not base.exists():
        return 0
    # Remove old blobs first so files deleted by a re-index don't linger.
    for blob in container.list_blobs(name_starts_with=f"{folder}/"):
        container.delete_blob(blob.name)
    count = 0
    for path in base.rglob("*"):
        if path.is_file():
            with path.open("rb") as data:
                container.upload_blob(f"{folder}/{path.relative_to(base).as_posix()}", data, overwrite=True)
            count += 1
    return count


def download(folder: str) -> int:
    """Download every blob under `folder/` into the local project root."""
    container = _container()
    count = 0
    for blob in container.list_blobs(name_starts_with=f"{folder}/"):
        target = ROOT / blob.name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("wb") as out:
            container.download_blob(blob.name).readinto(out)
        count += 1
    return count


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("upload", "download"):
        sys.exit(__doc__)
    action = upload if sys.argv[1] == "upload" else download
    for name in sys.argv[2:]:
        print(f"{sys.argv[1]} {name}: {action(name)} files", flush=True)
