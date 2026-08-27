---
description: Deploy or update the chat UI on App Service, the hosted agent on Foundry Agent Service, the orders backend on Azure Functions, or any combination. Triggers the deploy workflows on the self-hosted runner and verifies the result end to end.
allowed-tools: [Bash, Read]
---

You are helping the user deploy or update the application in a landing zone. There are
three deployables in `app/`, each with its own workflow, and all run on the self-hosted
GitHub Actions runner on the hub jump VM because they need VNet access and Docker.

| Deployable | Source | Workflow | Target |
|---|---|---|---|
| Chat UI | `app/ui/` | `appdeploy.yml` | App Service container |
| Agent | `app/agent/` | `agentdeploy.yml` | Foundry Agent Service (hosted agent) |
| Orders API | `app/orders/` | `ordersdeploy.yml` | Function App (Flex Consumption) |

Deploy whichever the change touches. Where more than one is involved, go bottom-up —
orders, then agent, then UI — since each calls the one before it.

Two things that are not this skill's job, and should be pointed at instead of
improvised:

- Changing `app/orders/openapi.yaml` changes the APIM contract, so `infra/lz-platform`
  has to be re-applied afterwards or the gateway keeps serving the old operations. If
  an `operationId` changed, a tool in `infra/lz-platform/orders.tf` needs updating to
  match or the apply fails.
- Changing which tools the agent has is a toolbox change, not an agent deploy — see
  `app/toolbox/README.md`. That is the point of the Toolbox: tools change without the
  container being rebuilt.

## Step 1 — Confirm inputs

Ask which landing zone (default `lz01`) and which deployable. Look up the App Service
name if the UI is being deployed:

```bash
source config/global.env
az webapp list --resource-group rg${NUMBER}-<lzname> --query "[].{name:name,state:state}" -o table
```

## Step 2 — Check the self-hosted runner is online

```bash
REPO=$(git remote get-url origin | sed 's|https://github.com/||;s|\.git$||')
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | {name,status,busy}'
```

If nothing shows `online`, the jump VM may be deallocated (see `/pause-resume`) or the
runner service stopped. Start the VM with
`az vm start --resource-group rg<number>-hub --name jump7`, or SSH in and check
`sudo systemctl status actions.runner.*`.

## Step 3 — Deploy

All three workflows build on the checked-out ref, so make sure the changes are
**committed and pushed** first — deploying uncommitted work silently ships the previous
commit.

```bash
# Orders API
gh workflow run ordersdeploy.yml -f environment=<lzname>

# Agent (drop -f toolbox= to deploy without the order tools)
gh workflow run agentdeploy.yml -f environment=<lzname> -f toolbox=orders-toolbox

# UI
gh workflow run appdeploy.yml -f environment=<lzname> -f appservice=<app-service-name>

gh run watch
```

`agentdeploy.yml` patches the Foundry project name into `app/azure.yaml` with `yq`,
runs `azd deploy` (the platform builds from `pyproject.toml` + `uv.lock` — there is no
`requirements.txt`, and adding one would override the lock), then grants the agent's
platform-created identity `Foundry Project Manager` and `Foundry User` on the account.

`appdeploy.yml` builds `app/ui/Dockerfile`, pushes to the landing zone ACR, and points
the App Service at the new tag. The App Service pulls with its managed identity.

`ordersdeploy.yml` exports `requirements.txt` from `uv.lock` (Functions' remote build
reads only that), zip-deploys to the Function App, and then smoke-tests it: `listOrders`
must return 200 and an unknown order id must return 404. Treat a smoke-test failure as a
failed deploy — the agent's behaviour depends on that 404 being unambiguous.

## Step 4 — Verify

The App Service allows the IPs in `allowed_ips`, so check from the workstation:

```bash
source config/global.env
APP=$(az webapp list --resource-group rg${NUMBER}-<lzname> --query "[0].name" -o tsv)
curl -s -o /dev/null -w "UI: HTTP %{http_code}\n" "https://${APP}.azurewebsites.net/"
curl -s -X POST "https://${APP}.azurewebsites.net/chat" \
  -H "Content-Type: application/json" -d '{"message":"hello"}'
```

To exercise the agent without the UI, POST to the agent endpoint directly with an Entra
token. **This only works from inside the VNet** — run it on the jump VM. The Foundry
account is private-endpoint only, so from a workstation it returns
`403 Public access is disabled`:

```bash
TOKEN=$(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)
curl -s -X POST "${FOUNDRY_PROJECT_ENDPOINT}/agents/rag-agent/endpoint/protocols/openai/responses?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"input":"hello","stream":false}'
```

A `200` with `"status": "completed"` is success. A `200` whose body says
`"status": "failed"` means the container ran and raised — that is an application error.

## Step 5 — Troubleshooting

**Read the container logs before theorising.** Hosted agent logs are only reachable
through a session; there is no log route on the data plane and no App Insights wired
up. Run these on the jump VM — they talk to the Foundry data plane, which is
private-endpoint only:

```bash
export FOUNDRY_PROJECT_ENDPOINT="https://<hub>.services.ai.azure.com/api/projects/<proj>"
azd ai agent sessions create --agent-name rag-agent --version <n>
azd ai agent monitor rag-agent --session-id <id> --follow
# then invoke with -H "x-agent-session-id: <id>" to pin the request to that session
```

Distinguish the two failure shapes:

- **Bare `500`, no response envelope, and no inbound `POST /responses` in the container
  log.** The platform rejected the call before the container — almost always the
  Foundry account's network ACL. Note that ACL changes take minutes to reach the data
  plane and it serves the old state meanwhile, so never conclude anything from a test
  run seconds after changing it.
- **`200` with `"status": "failed"`.** The container ran and the handler raised. The
  traceback is in the session log.

For the UI, container startup problems show up in the App Service docker log:

```bash
az webapp log download --name <app> --resource-group rg<number>-<lz> --log-file /tmp/logs.zip
unzip -o /tmp/logs.zip -d /tmp/logs && tail -40 /tmp/logs/LogFiles/*docker.log
```

`ImagePullUnauthorizedFailure` means registry auth, not networking: ACR has
`admin_enabled = false`, so the pull must use the app's managed identity
(`container_registry_use_managed_identity`), and any leftover
`DOCKER_REGISTRY_SERVER_*` app settings take precedence and must be deleted.
