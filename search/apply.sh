#!/usr/bin/env bash
# Apply the AI Search definitions: index, data source, skillset, indexer.
#
# Terraform cannot manage these — they are data-plane REST objects, and azurerm only
# covers the service itself and its shared private links. So they live here as JSON and
# this script PUTs them.
#
# Must run inside the VNet: the search service is private-endpoint only. Use the jump
# host (see docs/vscode-remote-development.md).
#
#   export SEARCH_API_KEY=...      # az search admin-key show, from a machine with
#                                  # management access — the jump VM identity has none
#   ./search/apply.sh
#
# Order matters: the index must exist before the skillset that projects into it, and both
# before the indexer that references them. Creating the indexer starts a run immediately.
set -euo pipefail

API_VERSION="${API_VERSION:-2026-04-01}"
SEARCH_SERVICE="${SEARCH_SERVICE:-}"
STORAGE_ACCOUNT_ID="${STORAGE_ACCOUNT_ID:-}"
OPENAI_URI="${OPENAI_URI:-}"

: "${SEARCH_API_KEY:?set SEARCH_API_KEY (az search admin-key show --service-name <svc> -g <rg> --query primaryKey -o tsv)}"
: "${SEARCH_SERVICE:?set SEARCH_SERVICE to the search service name}"
: "${STORAGE_ACCOUNT_ID:?set STORAGE_ACCOUNT_ID to the content storage account resource id}"
: "${OPENAI_URI:?set OPENAI_URI to the platform Foundry endpoint, e.g. https://aif<hex>.openai.azure.com}"

here="$(cd "$(dirname "$0")" && pwd)"
base="https://${SEARCH_SERVICE}.search.windows.net"

apply() {
  local kind="$1" file="$2" name
  name="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$here/$file")"

  # The definitions carry placeholders rather than hard-coded resource ids, so the same
  # JSON works against a rebuilt environment where the random_id suffixes have changed.
  body="$(sed -e "s|__STORAGE_ACCOUNT_ID__|${STORAGE_ACCOUNT_ID}|g" \
              -e "s|__OPENAI_URI__|${OPENAI_URI}|g" "$here/$file")"

  code="$(curl -s -o /tmp/apply-out.json -w '%{http_code}' \
    -X PUT "${base}/${kind}/${name}?api-version=${API_VERSION}" \
    -H "api-key: ${SEARCH_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "$body")"

  if [[ "$code" =~ ^2 ]]; then
    printf '  %-12s %-20s HTTP %s\n' "$kind" "$name" "$code"
  else
    printf '  %-12s %-20s HTTP %s\n' "$kind" "$name" "$code"
    python3 -m json.tool /tmp/apply-out.json 2>/dev/null | head -20 || head -c 600 /tmp/apply-out.json
    exit 1
  fi
}

echo "applying to ${base} (api-version ${API_VERSION})"
apply indexes      index.json
apply datasources  datasource.json
apply skillsets    skillset.json
apply indexers     indexer.json

echo
echo "indexer status:"
curl -s "${base}/indexers/books-indexer/status?api-version=${API_VERSION}" -H "api-key: ${SEARCH_API_KEY}" |
  python3 -c "
import json,sys
d = json.load(sys.stdin)
last = d.get('lastResult') or {}
print(f\"  status={d.get('status')} last={last.get('status')} processed={last.get('itemsProcessed')} failed={last.get('itemsFailed')}\")
for e in (last.get('errors') or [])[:3]:
    print('  error:', e.get('errorMessage', '')[:300])
"
