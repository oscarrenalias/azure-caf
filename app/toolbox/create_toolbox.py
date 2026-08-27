"""Create (or version) the Foundry Toolbox that exposes the orders MCP server.

Run from the jump host — the Foundry project has no public inbound.

    cd ~/azure-caf/app/toolbox
    export FOUNDRY_PROJECT_ENDPOINT=https://<account>.services.ai.azure.com/api/projects/<project>
    export ORDERS_CONNECTION_NAME=apim-orders-mcp     # created with `azd ai connection create`
    export ORDERS_MCP_URL=https://<apim>.azure-api.net/orders-mcp/mcp
    uv run --with azure-ai-projects --with azure-identity python create_toolbox.py

The connection has to exist first, and it is what holds the APIM subscription key — see
README.md in this directory. Nothing here ever sees that key: the toolbox definition
references the connection by name and the Toolbox injects the credential at call time,
which is the whole reason the agent container holds no secret.

Every run creates a new *version*. The first version becomes the default automatically;
later ones do not, so promote them deliberately (`azd ai toolbox publish`) once probed.
"""

from __future__ import annotations

import os
import sys

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import MCPToolboxTool
from azure.identity import DefaultAzureCredential

ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"].rstrip("/")
TOOLBOX_NAME = os.environ.get("TOOLBOX_NAME", "orders-toolbox")
CONNECTION = os.environ["ORDERS_CONNECTION_NAME"]
MCP_URL = os.environ["ORDERS_MCP_URL"]

# "always" for the whole server, because require_approval is a per-server setting and
# this server contains two tools that write to the system of record. It is a statement
# of policy, not a control: the Toolbox documents that it does not block tools/call and
# that enforcement belongs to the agent runtime. The narrowing to just createOrder and
# updateOrder therefore happens in the agent, via TOOLBOX_APPROVAL_TOOLS — see
# app/agent/approvals.py.
REQUIRE_APPROVAL = os.environ.get("ORDERS_REQUIRE_APPROVAL", "always")

# Becomes the tool-name prefix the agent sees: `orders.getOrder`, `orders.createOrder`.
SERVER_LABEL = os.environ.get("ORDERS_SERVER_LABEL", "orders")


def main() -> int:
    with (
        DefaultAzureCredential() as credential,
        AIProjectClient(endpoint=ENDPOINT, credential=credential) as project,
    ):
        created = project.toolboxes.create_version(
            name=TOOLBOX_NAME,
            description=(
                "Customer orders, served by the APIM MCP gateway over the orders REST API."
            ),
            tools=[
                MCPToolboxTool(
                    server_label=SERVER_LABEL,
                    server_url=MCP_URL,
                    require_approval=REQUIRE_APPROVAL,
                    project_connection_id=CONNECTION,
                )
            ],
        )

    versioned = f"{ENDPOINT}/toolboxes/{created.name}/versions/{created.version}/mcp?api-version=v1"
    default = f"{ENDPOINT}/toolboxes/{created.name}/mcp?api-version=v1"

    print(f"Created {created.name} version {created.version}")
    print()
    print(f"Probe this version:  {versioned}")
    print(f"Agent endpoint:      {default}")
    print()
    print("Probe it before pointing the agent at it:")
    print(f"  TOOLBOX_ENDPOINT='{versioned}' python probe_toolbox.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
