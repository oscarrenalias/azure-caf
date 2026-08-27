# Foundry Toolbox for the orders MCP server

The Toolbox is the seam between the agent and everything it can do to the system of
record. The agent knows one URL and authenticates to it as itself; the Toolbox holds the
credential for the APIM MCP server and injects it per call. Tools can be added, changed
or withdrawn here without redeploying the agent container.

```
agent container ──[Entra token, ai.azure.com]──▶ Toolbox MCP endpoint
                                                   └─ connection apim-orders-mcp [api key]
                                                        └─ APIM orders-mcp  ──▶ orders-api ──▶ Function App
```

Everything below runs **on the jump host**. The Foundry project has no public inbound,
and `DefaultAzureCredential` picks up the VM's managed identity over IMDS, so there is
no `az login` and no credential on disk.

## Prerequisites

- `infra/lz01` applied (Function App), `infra/lz01` deployed (`ordersdeploy.yml`), and
  `infra/lz-platform` applied a second time with `orders_function_name` filled in.
- The identity creating the toolbox needs **Foundry User** on the project, and so does
  the agent's own identity. See [agent identity](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/agent-identity).
- The `microsoft.foundry` azd extension bundle, which provides `azd ai connection` and
  `azd ai toolbox`:

  ```bash
  azd ext install microsoft.foundry
  ```

## 1. Collect the values

```bash
cd ~/azure-caf
terraform -chdir=infra/lz-platform output -raw orders_mcp_url          # ORDERS_MCP_URL
terraform -chdir=infra/lz-platform output -raw orders_subscription_key # ORDERS_SUBSCRIPTION_KEY
terraform -chdir=infra/lz01 output -raw foundry_project_name
```

Or, without Terraform state to hand:

```bash
APIM=$(az apim list -g rg<number>-lz-platform --query "[0].name" -o tsv)
export ORDERS_MCP_URL="https://${APIM}.azure-api.net/orders-mcp/mcp"
export ORDERS_SUBSCRIPTION_KEY=$(az apim subscription list \
  -g rg<number>-lz-platform -n "$APIM" \
  --query "[?displayName=='Orders Default'].primaryKey | [0]" -o tsv)
export FOUNDRY_PROJECT_ENDPOINT="https://<account>.services.ai.azure.com/api/projects/<project>"
```

Before going further, check the MCP server itself answers — this fails fast and
separates an APIM problem from a Toolbox one:

```bash
curl -s -X POST "$ORDERS_MCP_URL" \
  -H "Ocp-Apim-Subscription-Key: $ORDERS_SUBSCRIPTION_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

All four tools — `getOrder`, `listOrders`, `createOrder`, `updateOrder` — should come
back with the descriptions from `infra/lz-platform/orders.tf`.

## 2. Create the project connection

The connection is where the subscription key lives. Nothing downstream of it — not the
toolbox definition, not the agent — ever holds the key.

```bash
azd ai project set "$FOUNDRY_PROJECT_ENDPOINT"

azd ai connection create apim-orders-mcp \
  --kind remote-tool \
  --target "$ORDERS_MCP_URL" \
  --auth-type custom-keys \
  --custom-key "Ocp-Apim-Subscription-Key=$ORDERS_SUBSCRIPTION_KEY"
```

## 3. Create the toolbox

```bash
cd ~/azure-caf/app/toolbox
export ORDERS_CONNECTION_NAME=apim-orders-mcp
uv run --with azure-ai-projects --with azure-identity python create_toolbox.py
```

The script prints two endpoints. The **versioned** one is for probing a specific
version; the **unversioned** one always serves the toolbox's default version and is
what the agent should be given, so that publishing a new version reaches the agent
without a redeploy.

`toolbox.yaml` is the equivalent `azd ai toolbox create --from-file` path. It is kept
for reference but is not the path used here: that form cannot set `require_approval`.

## 4. Probe it before the agent sees it

```bash
uv run --with 'mcp>=2.0,<3' --with httpx2 --with azure-identity \
  python probe_toolbox.py --endpoint '<versioned endpoint>'
```

This is verification step 3, and it is worth doing properly: it proves credential
injection works with no agent in the picture, so if the agent then fails you know the
fault is in the agent.

## 5. Point the agent at it

```bash
cd ~/azure-caf/app
azd env set TOOLBOX_ENDPOINT '<unversioned endpoint>'
```

`agentdeploy.yml` sets this automatically when `TOOLBOX_NAME` is configured; see the
`Configure azd environment` step there.

## About `require_approval`

`require_approval` is set **per MCP server**, not per tool. One connection carrying all
four orders tools can only say `always` or `never` for the lot.

More to the point, the Toolbox documentation is explicit that it does not act on the
setting:

> The MCP endpoint doesn't block `tools/call`. Enforcement is entirely the agent
> runtime's responsibility.

So `require_approval: always` here is a policy statement that travels with the tools,
and the actual gate is `app/agent/approvals.py`, which holds a write until the user has
said yes in a later turn. `TOOLBOX_APPROVAL_TOOLS` (default `createOrder,updateOrder`)
is what narrows the server-wide flag down to the two tools that write. Set it to an
empty string to defer to whatever the Toolbox reports instead.

`probe_toolbox.py` prints what the server actually says under `_meta.tool_configuration`,
so this can be confirmed against a live Toolbox rather than taken on trust.

## Known issue worth remembering

There is a reported problem where the Toolbox's data proxy cannot resolve private DNS
for MCP servers behind a BYO VNet. Our APIM runs in External VNet mode with a public
gateway, so the Toolbox reaches it over the internet and this should not apply — but it
is a concrete reason not to move APIM to Internal mode while this is in place. See the
network posture notes in `CLAUDE.md`.
