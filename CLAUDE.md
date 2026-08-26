# azure-caf

Hub-and-spoke Azure landing zone, purpose-built for deploying agentic application reference architectures using Azure runtime services (App Service, Container Apps) and Azure AI Foundry.

## Architecture

```
Hub VNet (10.0.0.0/16)
  ├── AzureFirewallSubnet (10.0.1.0/24) — reserved; firewall off by default (see below)
  ├── vm subnet (10.0.0.0/24)           — jump host / GitHub Actions self-hosted runner
  └── VNet peerings → lz01, lz02

lz01 VNet (10.1.0.0/16)
  ├── vm (10.1.0.0/24)
  ├── gw (10.1.1.0/24)
  ├── private-endpoint (10.1.2.0/24)    — private endpoints for App Service, AI Foundry
  ├── app-service-integration (10.1.3.0/24)  — VNet-integrated App Service (delegated)
  └── ai-agents (10.1.4.0/24)          — Container Apps environments (delegated)
```

Hub creates all VNets and peerings; landing zones consume hub resources via the `lz-data` module (data sources). **Deploy hub before any landing zone.**

Private DNS zones live in the hub resource group and are linked to every VNet:
- `privatelink.azurewebsites.net`
- `privatelink.cognitiveservices.azure.com`
- `privatelink.openai.azure.com`

## Repository layout

```
infra/
  hub/          Terraform: all VNets, peerings, jump VM, DNS zones, optional firewall
  lz01/         Terraform: lz01 subnets, App Service, AI Foundry, private endpoints
  modules/
    lz-data/    Data-source module — resolves hub RG + VNet by name for a given lz
config/
  global.env    ARM credentials + storage backend (written from bootstrap output)
  global.tfvars number, location, ssh_public_key
  hub.tfvars    Hub-specific networks, peerings, subnets
  lz01.tfvars   lz01-specific subnets
  hub.env / lz01.env  Per-env GitHub Actions env overrides
app/            azd project: ui/ (FastAPI chat UI on App Service) and agent/ (LangGraph
                agent on Foundry Agent Service). See "Hosted agent (app/)" below.
docs/           Longer-form guides that don't belong in this file
                vscode-remote-development.md — the jump-host development loop
.github/workflows/
  terraform.yml   Terraform plan/apply/destroy — runs on ubuntu-latest
  appdeploy.yml   UI container build + App Service deploy — self-hosted runner (jump VM)
  agentdeploy.yml Hosted agent deploy via azd — self-hosted runner (jump VM)
bootstrap.sh    One-time setup: storage account, managed identity, OIDC federated credential
```

## Naming convention

All resources use a numeric suffix (`number`) from `config/global.tfvars` to ensure globally unique names. Resource groups follow `rg<number>-<env>`, VNets `vnet<number>-<env>`, etc. AI Foundry and App Service use a `random_id` hex suffix instead.

## One-time bootstrap

Run once per Azure subscription to create the remote state backend and managed identity used by GitHub Actions OIDC:

```bash
# Pre-requisites: azure-cli installed, logged in, correct subscription selected
az account set -s <subscription-guid>

# Edit bootstrap.sh before running:
# 1. Set `number` to a unique random value (avoid collisions with existing storage account names)
# 2. Update the --subject line in `az identity federated-credential create` to match your repo:
#    "repo:<gh-org>/<gh-repo>:ref:refs/heads/main"

bash bootstrap.sh
```

Bootstrap outputs the values you need to copy into `config/global.env` and `config/global.tfvars`:

```
ARM_CLIENT_ID=...
ARM_TENANT_ID=...
ARM_SUBSCRIPTION_ID=...
STORAGE_ACCOUNT_NAME=...
STORAGE_RESOURCE_GROUP=...
number = ...
```

After copying those values:
1. Update `ssh_public_key` in `config/global.tfvars` with your public key.
2. Update the NSG source IP in `infra/hub/vm.tf` (`azurerm_network_security_group.rule1`) to your public IP (`/32`).
3. In GitHub → Settings → Actions → Runners → New self-hosted runner: copy the registration token and add it as a repository secret named `GH_RUNNER_PAT`.

## Deploying infrastructure

Both workflows are manually triggered via `workflow_dispatch`.

### `terraform.yml`

Inputs:
- `environment`: `hub` or `lz01`
- `action`: `plan`, `apply`, or `destroy`
- `runner`: `ubuntu-latest` (default) or `self-hosted`

The workflow merges `config/global.tfvars` + `config/<env>.tfvars` into `infra/<env>/value.auto.tfvars` and similarly for `.env` files. Terraform state is stored per-environment as `<env>.tfstate` in the Azure Blob backend.

**Deployment order:**
1. Run `apply` for `hub` — creates VNets, peerings, jump VM, DNS zones (firewall only if `enable_firewall = true`). The jump VM installs the GitHub Actions runner on first boot via `cloud-init`.
2. Run `apply` for `lz01` — creates subnets (using hub VNet/RG via `lz-data`), App Service, AI Foundry, private endpoints.

### `appdeploy.yml`

Inputs:
- `environment`: `lz01` (or `lz02`)
- `appservice`: the App Service name (find it in the portal or from Terraform state, e.g. `app<hex>`)

Runs on the **self-hosted runner** (the hub jump VM), which has the VNet access and Docker needed to build and push. Builds `app/ui/Dockerfile`, pushes it to the landing zone's ACR, and points the App Service at the new tag. The App Service pulls with its own managed identity — ACR has `admin_enabled = false`, so registry credentials in app settings cannot work.

## Verifying deployment

SSH to the jump host (public IP, port 22, user `azureuser`) and curl the App Service via its private IP:

```bash
ssh azureuser@<jump-host-public-ip>
curl https://<app-service-name>.azurewebsites.net/
# Expected: Hello World
```

## AI Foundry and the AI Gateway

Models are a **shared platform resource**, not a workload resource:

```
lz-platform                                   lz01 (workload)
  AI Foundry `aif<hex>`  ◄── private ────  APIM `apim<hex>`        Foundry hub `hub<hex>`
    gpt-4o                  endpoint         (AI Gateway)            └── project `proj<hex>`
    text-embedding-3-small                         ▲                       └── connection `apim-gateway`
    public access disabled                         └──── connected mode ───┘
```

- `infra/lz-platform/aifoundry.tf` — the shared Foundry account holding the model
  deployments. Public access disabled; reachable only via its private endpoint.
- `infra/lz-platform/apim.tf` — APIM as the AI Gateway in front of it. Swaps the
  consumer subscription key for an APIM managed-identity token, enforces a
  per-subscription token limit, and reaches the Foundry backend privately.
- `infra/lz01/foundry.tf` — the workload Foundry account and project that host the
  Agent Service, plus the `apim-gateway` connection. Agents reference models as
  `apim-gateway/<deployment>` (e.g. `apim-gateway/gpt-4o`).

The `ai-agents` subnet (10.1.4.0/24) is reserved for agent compute.

### The `apim-gateway` connection

An APIM gateway is a *ModelGateway* connection, which is a different object from a
connection to a Cognitive Services account. It needs:

- `category = "ApiManagement"` (not `AzureOpenAI`)
- `metadata.deploymentInPath` — `"true"` here, since the gateway passes through the
  Azure OpenAI URL shape `<target>/deployments/<deployment>/chat/completions`
- `metadata.models` — a JSON-string static list of the deployments the gateway
  exposes, which must be kept in sync with `infra/lz-platform/aifoundry.tf`. The
  alternative is `metadata.modelDiscovery`, which requires `/deployments` operations
  on the APIM API backed by ARM.

Get any of these wrong and model resolution fails with `Connection 'apim-gateway'
not found` — the name resolves fine over the management API, so the error is
misleading. Schema:
[foundry-samples 01-connections/apim](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/01-connections/apim).

### Network posture

The workload Foundry account is **network-injected** (BYO VNet): agent compute runs in
the `ai-agents` subnet, delegated to `Microsoft.App/environments`, rather than on
Microsoft-managed infrastructure. This is the "basic agent with VNet injection" shape —
agent state uses platform-managed storage, so no BYO Storage, Cosmos DB or AI Search is
required. See Microsoft's
[networking options](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/networking-options)
and [template 11](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-terraform/11-private-network-basic-vnet).

What that buys, and what it costs:

| Component | Posture |
|---|---|
| Workload Foundry account | Private endpoint only; `public_network_access_enabled = false`, ACL `Deny` |
| Platform Foundry (models) | Private endpoint only, reached by APIM |
| ACR | Private endpoint only; App Service pulls via `vnet_image_pull_enabled` |
| AI Search | Private endpoint only |
| APIM gateway | Public ingress, subscription key + api policy (see below) |
| App Service (UI) | Public ingress restricted to `allowed_ips` — the one public front door |
| `azd ai agent run` | **Jump VM only.** The Foundry endpoint has no public inbound |

Injection is set at account creation and cannot be added later, so changing it replaces
the account. `random_id.foundry` carries a `keepers` entry for exactly this: without a
new suffix the replacement collides with the name the soft-deleted account still holds
for 48 hours. On any future rebuild, delete the capability host before the account and
purge the account afterwards, or the delegated subnet stays linked and the next apply
fails with "Subnet already in use".

APIM remains in **External** VNet mode: inbound public, outbound in the VNet so the
platform Foundry account is only ever reached privately. Now that agent egress is in the
VNet, moving APIM to Internal (or to Standard v2 with an inbound private endpoint) would
close the last public ingress that carries model traffic — worthwhile follow-on work,
but it means re-provisioning APIM and rotating the gateway URL and subscription key.

### Hosted agent (`app/`)

Dependencies are managed with **uv only** — `pyproject.toml` + `uv.lock`. There is no
`requirements.txt` and none should be added: `azure.yaml` sets
`codeConfiguration.dependencyResolution: remote_build`, and the Foundry remote build
resolves from the uv lock, the same as the
[uv-pyproject hosted agent sample](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/bring-your-own/responses/uv-pyproject).
A stale `requirements.txt` is worse than none at all: it silently wins over
`pyproject.toml` in the remote build, which is how the hosted agent once ended up
running a mismatched `azure-ai-agentserver` pair that `pyproject.toml` had fixed.

`.azdignore` matters for the same reason — without it the local `.venv` (macOS
binaries, ~145 MB) and `__pycache__` get uploaded into a Linux build.

`app/azure.yaml` is authoritative for the agent definition. `agentdeploy.yml` patches
in only the Foundry project name, which can't live in the file because it carries a
`random_id` suffix and appears as a service key rather than a value.

Two identities are involved and they are easy to confuse:

- The **App Service** user-assigned identity calls the agent endpoint. Managed in
  `infra/lz01/roles.tf`, needs `Foundry Project Manager`.
- The **agent's own** identity (`<account>-<project>-<agent>-AgentIdentity`) is created
  by the platform on first deploy and starts with no role assignments, so the
  container cannot call the project data plane for its model calls. Terraform can't own
  a principal that doesn't exist until deploy time, so `agentdeploy.yml` grants it
  after `azd deploy`. It is stable across agent versions.

### Developer access

**`azd ai agent run` must run on the jump VM, not a workstation.** It runs the agent
process locally but still calls the Foundry data plane, which has no public inbound
since the account was network-injected.

The jump host is set up for this: `uv` installed, a checkout at `~/azure-caf` (separate
from the runner's workspace, which every deploy wipes), and an azd environment called
`jumpdev` holding the project endpoint, model names and Search settings. The VM's
system-assigned identity has `Foundry Project Manager` on the account (`roles.tf`), so
`DefaultAzureCredential` authenticates over IMDS — no `az login`, no credentials on disk.

A `Host azure-jump` entry with the port forwards belongs in `~/.ssh/config`:

```
Host azure-jump
  HostName <jump-host-public-ip>
  User azureuser
  IdentityFile ~/.ssh/id_ed25519
  LocalForward 8088 localhost:8088
  LocalForward 8087 localhost:8087
```

Then:

```bash
ssh azure-jump                       # terminal 1 — keeps the forwards open
cd ~/azure-caf/app && git pull && azd ai agent run

# terminal 2, on the workstation — 8088 is forwarded, so this reaches the VM
curl -X POST http://localhost:8088/responses \
  -H "Content-Type: application/json" \
  -d '{"input":"hello","stream":false}'
```

Editing over SSH is not the intended workflow — use VS Code Remote-SSH, which keeps the
IDE local while files and processes stay on the VM. Setup, the git-credentials caveat
and troubleshooting are in
[docs/vscode-remote-development.md](docs/vscode-remote-development.md).

If the forward fails with `bind: Address already in use`, something local already holds
the port — usually an `azure-ai-inspector` left over from an earlier workstation run.

Remember the NSG rule in `infra/hub/vm.tf` gates SSH by source IP. A stale value there
now blocks local development entirely, not just SSH.

`config/lz01.tfvars` still carries `allowed_ips`, but it now applies **only** to the App
Service (`appservice.tf`) — that is what lets the UI open in a browser. Update it when
your public IP changes. The Foundry account, ACR and AI Search are all private-endpoint
only and ignore it.

Quickest end-to-end check from a workstation is the UI, which exercises the whole
private chain from outside it:

```bash
curl -s -X POST "https://<app>.azurewebsites.net/chat" \
  -H "Content-Type: application/json" -d '{"message":"hello"}'
```

**Changes to a Cognitive Services ACL take minutes to reach the data plane, and it
serves the old state meanwhile.** This makes network troubleshooting actively
misleading in both directions:

- After tightening, calls keep succeeding for a while. A permissive setting tested
  immediately after a stricter one can look like it works when it does not — this is
  how `bypass = "AzureServices"` was wrongly recorded as sufficient for hosted agents.
- After loosening, calls keep failing with
  `403 Public access is disabled. Please configure private endpoint.` (look for
  `policy-id: ThrowExceptionDueToTrafficDenied`) even though ARM reports the new
  values. Toggling `publicNetworkAccess` Disabled → Enabled forces a refresh.

Wait several minutes before drawing a conclusion, and re-test from a cold state
rather than immediately after changing the setting you are testing.

## Adding a new landing zone

1. Copy `infra/lz01/` to `infra/lz<n>/`.
2. Add a new VNet entry to `networks` in `config/hub.tfvars` and add the bidirectional peering entries.
3. Create `config/lz<n>.tfvars` and `config/lz<n>.env`.
4. Add `lz<n>` as a choice in both GitHub Actions workflow `environment` inputs.
5. Deploy hub first (to create the new VNet), then deploy lz<n>.

## Claude Code skills

Four skills are available in `.claude/commands/` to automate the most common workflows. Invoke them with `/skill-name` in Claude Code.

| Skill | Command | Use when |
|-------|---------|----------|
| deploy-hub-spoke | `/deploy-hub-spoke` | First-time deployment of the entire platform from scratch |
| add-landing-zone | `/add-landing-zone` | Adding a new LZ (lz02, lz03, …) to the existing hub |
| deploy-app | `/deploy-app` | Deploying or updating an app on an existing landing zone's App Service |
| teardown | `/teardown` | Destroying resources in safe reverse order (LZs first, hub last) |
| pause-resume | `/pause-resume` | Pause (deallocate the VM, and the firewall if enabled) or resume |
| jump-host | `/jump-host` | Check, start or repair the jump VM on its own — runner host and the only place `azd ai agent run` works |

### `/deploy-hub-spoke`

Walks through the full initial deployment sequence: prerequisite checks → bootstrap (storage account, managed identity, OIDC federated credential) → config file updates (ARM creds, SSH key, NSG source IP, GitHub runner PAT secret) → hub apply → lz01 apply → initial app deploy → verification via jump host. Skips the bootstrap phase if `config/global.env` is already populated.

### `/add-landing-zone`

Prompts for the new LZ name and VNet CIDR, then: creates `config/<lzname>.tfvars` and `.env`, updates the `networks` and `peerings` lists in `config/hub.tfvars`, copies `infra/lz01/` to `infra/<lzname>/`, adds the new environment choice to both workflow files, re-applies hub (to create the new VNet), and deploys the new LZ.

### `/deploy-app`

Looks up the App Service name if not provided, confirms the self-hosted runner on the jump VM is online, triggers `appdeploy.yml`, and verifies the app responds via a curl from the jump host. Includes troubleshooting steps for runner-offline and app-crash scenarios.

### `/teardown`

Confirms scope with the user (single LZ, all LZs + hub, or full cleanup including bootstrap resources), lists all resource groups that will be deleted, then destroys in order: each LZ individually → hub. Prompts for explicit confirmation before each destructive workflow. Optionally cleans up the state storage account and managed identity resource groups that are not managed by Terraform.

## Terraform provider versions

- `hashicorp/azurerm`: `4.81.0`
- Terraform CLI: `1.15.8` (pinned in `terraform.yml`)

## Key files to edit when personalizing

| File | What to change |
|------|---------------|
| `bootstrap.sh` | `number` variable; federated credential `--subject` |
| `config/global.env` | All values — output from `bootstrap.sh` |
| `config/global.tfvars` | `number`, `location`, `ssh_public_key` |
| `infra/hub/vm.tf` | `source_address_prefix` in the NSG rule (your IP) |
