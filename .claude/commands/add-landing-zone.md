---
description: Scaffold and deploy a new landing zone (e.g. lz02, lz03). Creates tfvars wired to the shared AI Gateway, updates hub peerings, and deploys hub then the new LZ in order.
allowed-tools: [Bash, Read, Edit, Write]
---

You are helping the user add a new landing zone to the hub-and-spoke architecture. A landing zone is a separate VNet peered to hub, with its own subnets, App Service, AI Search, and a Foundry account and project that host its agents. It does **not** get its own models: those are shared platform resources in `lz-platform`, reached through the APIM AI Gateway via a connection on the project (connected mode).

Ask the user for the new landing zone name (e.g. `lz02`) and its VNet address space (e.g. `10.2.0.0/16`) before starting. Subnet prefixes should be derived from the VNet range following the same pattern as lz01.

## Step 1 — Read current config

Read these files to understand the current state before making any changes:
- `config/global.tfvars` (get the current `number` and `location`)
- `config/hub.tfvars` (current networks list and peerings)
- `config/lz01.tfvars` (template for subnet structure)
- `config/lz01.env` (template for env vars)

## Step 2 — Create lz config files

Create `config/<lzname>.tfvars` following the lz01 pattern. Derive subnet prefixes from the new VNet range (same offsets as lz01):

```
lz  = "<lzname>"
hub = "hub"
subnets = [
  { name = "vm",                    prefix = "<vnet-third-octet>.0.0/24",  route = true },
  { name = "gw",                    prefix = "<vnet-third-octet>.1.0/24",  route = false },
  { name = "private-endpoint",      prefix = "<vnet-third-octet>.2.0/24",  route = false },
  { name = "app-service-integration", prefix = "<vnet-third-octet>.3.0/24", route = true, delegation = "Microsoft.Web/serverFarms" },
  { name = "ai-agents",             prefix = "<vnet-third-octet>.4.0/24",  route = true, delegation = "Microsoft.App/environments" },
]

# Models are shared and live in lz-platform; workloads reach them through the gateway.
# Take this from the deployed APIM: az apim list -g rg<number>-lz-platform --query "[0].name" -o tsv
apim_gateway_url = "https://apim<hex>.azure-api.net/openai"

# Developer IPs — gates the App Service only, i.e. browser access to the UI. The
# Foundry account, ACR and AI Search are private-endpoint only.
allowed_ips = ["<developer-public-ip>"]
```

`lz-platform` must already be deployed: the Foundry connection created in the new LZ
is configured with the gateway URL above and a subscription key, and neither exists
until that stack is up.

Create `config/<lzname>.env` as an empty file (or copy lz01.env structure if it has content).

## Step 3 — Update hub.tfvars

Add the new VNet to the `networks` list and add bidirectional peerings:

```hcl
# In networks list:
{ name = "<lzname>", range = "<vnet-cidr>" },

# In peerings list (add both directions):
{ name = "hub-<lzname>", source = "hub", destination = "<lzname>" },
{ name = "<lzname>-hub", source = "<lzname>", destination = "hub" },
```

## Step 4 — Copy lz01 Terraform to new LZ

```bash
cp -r infra/lz01 infra/<lzname>
rm -rf infra/<lzname>/.terraform infra/<lzname>/.terraform.lock.hcl
```

Most of it is generic and driven by tfvars, but two things must be cleaned up in the
copy or the first apply fails:

1. **Remove the `import` block in `infra/<lzname>/roles.tf`.** It hardcodes a
   subscription id, resource group and role assignment GUID belonging to lz01's Foundry
   account. Left in place, the new LZ tries to import a role assignment that isn't its
   own.
2. **Delete any `.terraform/` directory or `.terraform.lock.hcl`** that came along with
   the copy (the `rm -rf` above) — provider caches must not be shared between stacks.

## Step 5 — Add LZ to GitHub Actions workflows

Add `<lzname>` to the `environment` input options in all three workflows:
`.github/workflows/terraform.yml`, `appdeploy.yml`, and `agentdeploy.yml`.

`terraform.yml` also hardcodes the APIM key it passes to Terraform:

```yaml
TF_VAR_apim_subscription_key: ${{ secrets.APIM_SUBSCRIPTION_KEY_LZ01 }}
```

Every environment therefore receives lz01's key. If each landing zone should have its
own APIM subscription — the usual reason being per-workload token limits and
revocation — create a subscription per LZ in `lz-platform`, store it as
`APIM_SUBSCRIPTION_KEY_<LZNAME>`, and select it per environment. Otherwise the shared
key works, and the limitation should at least be a conscious choice.

## Step 6 — Deploy hub first (for the new VNet)

The new VNet and its peering are managed by the hub Terraform stack. It must be re-applied before the new LZ can be deployed.

Confirm with the user before running:
```bash
gh workflow run terraform.yml \
  -f environment=hub \
  -f action=apply \
  -f runner=ubuntu-latest
gh run watch
```

Wait for hub to complete successfully.

## Step 7 — Deploy the new landing zone

```bash
gh workflow run terraform.yml \
  -f environment=<lzname> \
  -f action=apply \
  -f runner=ubuntu-latest
gh run watch
```

## Step 8 — Report

After both workflows succeed, report:
- New VNet CIDR and subnet layout
- Resource group name
- App Service name (find it: `az webapp list --resource-group rg<number>-<lzname> --query "[].name" -o tsv`)
- The Foundry project endpoint, and confirmation that the `apim-gateway` connection
  resolves — models are referenced as `apim-gateway/<deployment>`, not by a per-LZ
  Foundry endpoint
- Next steps: deploy the agent and UI with `/deploy-app`

Verify the connection before handing over, since a broken one fails at inference time
with a misleading `Connection 'apim-gateway' not found`:

```bash
TOKEN=$(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)
curl -s "${FOUNDRY_PROJECT_ENDPOINT}/connections?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer $TOKEN"
```

Expect `"type": "ApiManagement"` with `metadata.deploymentInPath` and a `models` list.
