# azure-caf

Hub-and-spoke Azure landing zone, purpose-built for deploying agentic application reference architectures using Azure runtime services (App Service, Container Apps) and Azure AI Foundry.

## Architecture

```
Hub VNet (10.0.0.0/16)
  ├── AzureFirewallSubnet (10.0.1.0/24) — Azure Firewall (Standard), central egress
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
  hub/          Terraform: all VNets, peerings, firewall, route table, jump VM, DNS zones
  lz01/         Terraform: lz01 subnets, App Service, AI Foundry, private endpoints
  modules/
    lz-data/    Data-source module — resolves hub RG + VNet by name for a given lz
config/
  global.env    ARM credentials + storage backend (written from bootstrap output)
  global.tfvars number, location, ssh_public_key
  hub.tfvars    Hub-specific networks, peerings, subnets
  lz01.tfvars   lz01-specific subnets
  hub.env / lz01.env  Per-env GitHub Actions env overrides
app1/           Flask placeholder app ("Hello World"), deployed to lz01 App Service
.github/workflows/
  terraform.yml  Terraform plan/apply/destroy — runs on ubuntu-latest
  appdeploy.yml  App deploy to App Service — runs on self-hosted runner (jump VM)
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
1. Run `apply` for `hub` — creates VNets, peerings, firewall, jump VM, DNS zones. The jump VM installs the GitHub Actions runner on first boot via `cloud-init`.
2. Run `apply` for `lz01` — creates subnets (using hub VNet/RG via `lz-data`), App Service, AI Foundry, private endpoints.

### `appdeploy.yml`

Inputs:
- `environment`: `lz01` (or `lz02`)
- `appservice`: the App Service name (find it in the portal or from Terraform state, e.g. `app<hex>`)

Runs on the **self-hosted runner** (the hub jump VM) because the App Service has no public network access and must be reached via private endpoint. Packages `app1/` as a zip and deploys with `az webapp deploy`.

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

### AI Gateway network posture

APIM runs in **External** VNet mode. Inbound is public (subscription key + api
policy); outbound stays in the VNet, so the platform Foundry account is only ever
reached over its private endpoint.

External rather than Internal because the Foundry inference service must reach the
gateway for connected-mode model calls. Internal mode publishes no public DNS record
for `<name>.azure-api.net`, and the workload Foundry account is Microsoft-managed
multi-tenant compute (`networkInjections: null`) whose egress is not in this VNet —
so with Internal mode the gateway is unreachable and every model call fails.

**Target state (follow-on work): end-to-end private gateway.** Mirrors Microsoft's
[template 16](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/16-private-network-standard-agent-apim-setup):

1. Recreate the lz01 Foundry account with **VNet injection** into a /24 delegated to
   `Microsoft.App/environments` (the `ai-agents` subnet). Network injection cannot be
   added to an existing account — the account must be rebuilt, and deleted/purged
   with its capability hosts first or the subnet stays locked.
2. Add the BYO resources standard agent setup requires — Storage, Cosmos DB, AI
   Search — plus account and project capability hosts.
3. Migrate APIM from classic `Developer_1` to `StandardV2` with outbound VNet
   integration and an inbound private endpoint (`privatelink.azure-api.net`).
   Classic tiers cannot have an inbound private endpoint while VNet-injected.
4. Local development then has to run inside the VNet — on the hub jump VM with ports
   8088 and 8087 forwarded — which is what Microsoft's own guidance prescribes for a
   VNet-only Foundry endpoint.

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

### Developer access for local `azd` runs

`azd ai agent run` / `invoke --local` runs the agent process on the workstation but
still calls the Foundry data plane, so `config/lz01.tfvars` carries `allowed_ips`,
an IP allowlist applied to the workload Foundry account (`foundry.tf`) and to AI
Search (`search.tf`). Update it when your public IP changes.

Note that a Cognitive Services account can serve stale network config: after
flipping `publicNetworkAccess` or the ACL, the data plane may keep answering
`403 Public access is disabled. Please configure private endpoint.` (look for
`policy-id: ThrowExceptionDueToTrafficDenied` on the response) even though ARM
reports the new values. Toggling `publicNetworkAccess` Disabled → Enabled forces the
data plane to pick them up.

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
| pause-resume | `/pause-resume` | Pause (destroy firewall + deallocate VM, saves ~$1.25/hr) or resume (recreate firewall + start VM, ~10 min) |

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
