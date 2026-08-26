#!/usr/bin/env python3
"""Upload converted markdown to the content container, with per-work blob metadata.

Must run inside the VNet — the storage account is private-endpoint only — and
authenticates with Entra ID rather than a key, because the account has shared key access
disabled. On the jump host that means the VM's managed identity:

    az login --identity
    python3 tools/upload_content.py

Each blob carries the work's metadata (title, author, translator, year, language). The
indexer copies those into the search index, but **only into fields that already exist
there**: a metadata key with no matching index field is extracted and silently discarded.
So this script and search/index.json have to agree on names.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

# Keys promoted to blob metadata. Must match field names in search/index.json.
METADATA_KEYS = ("title", "author", "translator", "year", "language")


def az(*args: str) -> str:
    result = subprocess.run(["az", *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"az {' '.join(args[:3])}... failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--resource-group", help="defaults to the lz01 group from config/global.tfvars")
    ap.add_argument("--account", help="storage account name; discovered from the resource group if omitted")
    ap.add_argument("--container", default="books")
    ap.add_argument("--source", type=Path, default=Path("content/markdown"))
    args = ap.parse_args()

    rg = args.resource_group
    if not rg:
        number = next(
            line.split("=")[1].strip().strip('"')
            for line in Path("config/global.tfvars").read_text().splitlines()
            if line.strip().startswith("number")
        )
        rg = f"rg{number}-lz01"

    account = args.account or az(
        "storage", "account", "list", "-g", rg, "--query", "[0].name", "-o", "tsv"
    )
    if not account:
        sys.exit(f"no storage account found in {rg}")

    manifest = json.loads((args.source / "metadata.json").read_text())
    print(f"uploading {len(manifest)} file(s) to {account}/{args.container}\n")

    for work in manifest:
        path = args.source / work["file"]
        metadata = [f"{k}={work[k]}" for k in METADATA_KEYS if work.get(k)]
        az(
            "storage", "blob", "upload",
            "--auth-mode", "login",
            "--account-name", account,
            "--container-name", args.container,
            "--name", work["file"],
            "--file", str(path),
            "--overwrite",
            "--output", "none",
            "--metadata", *metadata,
        )
        size_kb = path.stat().st_size // 1024
        print(f"  {work['file']:20} {size_kb:>5} KB   {', '.join(metadata)}")

    listing = az(
        "storage", "blob", "list",
        "--auth-mode", "login",
        "--account-name", account,
        "--container-name", args.container,
        "--query", "[].name", "-o", "tsv",
    )
    print(f"\ncontainer now holds: {', '.join(listing.split())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
