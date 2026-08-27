"""Probe the Toolbox MCP endpoint directly — verification step 3, and the stage-3 spike.

Run from the jump host, with no agent involved:

    cd ~/azure-caf/app/toolbox
    export TOOLBOX_ENDPOINT='https://<account>.services.ai.azure.com/api/projects/<p>/toolboxes/orders-toolbox/versions/1/mcp?api-version=v1'
    uv run --with 'mcp>=2.0,<3' --with httpx2 --with azure-identity python probe_toolbox.py

What it proves, in order:

  1. The Toolbox authenticates this identity (an Entra token for ai.azure.com).
  2. Credential injection works — the tools appear without this process ever holding the
     APIM subscription key, which is the point of putting the key in a connection.
  3. All four orders tools are present with usable descriptions and input schemas.
  4. How `require_approval` is actually reported. The Toolbox documentation says it
     comes back under `_meta.tool_configuration` and that the endpoint does *not* block
     `tools/call` — enforcement is the agent runtime's job. This prints what the server
     really says, so that claim is confirmed here rather than assumed in agent code.

Add `--call listOrders --customer <id>` to make one read call end to end. There is
deliberately no way to invoke a mutating tool from this script.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

import httpx2
from azure.identity import DefaultAzureCredential
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

SCOPE = "https://ai.azure.com/.default"
EXPECTED = {"getOrder", "listOrders", "createOrder", "updateOrder"}


async def probe(endpoint: str, call: str | None, customer: str | None) -> int:
    token = DefaultAzureCredential().get_token(SCOPE).token
    headers = {"Authorization": f"Bearer {token}"}

    async with httpx2.AsyncClient(headers=headers, timeout=60.0) as http_client:
        async with streamable_http_client(endpoint, http_client=http_client) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                print("initialize: ok\n")

                listed = await session.list_tools()
                if not listed.tools:
                    print("No tools. The toolbox version was not provisioned correctly.")
                    return 1

                for tool in listed.tools:
                    meta = getattr(tool, "meta", None) or {}
                    configuration = meta.get("tool_configuration") or {}
                    approval = configuration.get("require_approval", "(not reported)")
                    schema = getattr(tool, "input_schema", None) or {}

                    print(f"{tool.name}")
                    print(f"  require_approval : {approval}")
                    print(f"  parameters       : {sorted((schema.get('properties') or {}))}")
                    print(f"  required         : {schema.get('required', [])}")
                    print(f"  description      : {(tool.description or '').strip()[:160]}")
                    if meta:
                        print(f"  _meta            : {json.dumps(meta)[:300]}")
                    print()

                short_names = {t.name.split(".")[-1] for t in listed.tools}
                missing = EXPECTED - short_names
                if missing:
                    print(f"MISSING: {', '.join(sorted(missing))}")
                    print("Check the tools sub-resources on the APIM MCP server.")
                    return 1
                print(f"All four orders tools present ({len(listed.tools)} tools total).")

                if call:
                    name = next(
                        (t.name for t in listed.tools if t.name.split(".")[-1] == call), None
                    )
                    if name is None:
                        print(f"\nNo tool named {call}.")
                        return 1
                    if call not in ("getOrder", "listOrders"):
                        print(f"\nRefusing to call {call} from a probe — it writes.")
                        return 1

                    arguments = {"customerId": customer} if customer else {}
                    print(f"\ncalling {name} with {arguments}")
                    result = await session.call_tool(name, arguments)
                    print(f"is_error: {getattr(result, 'is_error', None)}")
                    for content in result.content or []:
                        if getattr(content, "type", None) == "text":
                            print(content.text)

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default=os.environ.get("TOOLBOX_ENDPOINT", ""))
    parser.add_argument("--call", help="A read-only tool to invoke: getOrder or listOrders")
    parser.add_argument("--customer", help="customerId argument for the call")
    args = parser.parse_args()

    if not args.endpoint:
        parser.error("set TOOLBOX_ENDPOINT or pass --endpoint")

    print(f"endpoint: {args.endpoint}\n")
    return asyncio.run(probe(args.endpoint, args.call, args.customer))


if __name__ == "__main__":
    sys.exit(main())
