---
description: Scaffold and deploy a new landing zone (e.g. lz02, lz03). Creates tfvars, updates hub peerings, and deploys both hub and the new LZ in order.
allowed-tools: [Bash, Read, Edit, Write]
---

You are helping the user add a new landing zone to the hub-and-spoke architecture. A landing zone is a separate VNet peered to hub, with its own subnets, App Service, and AI Foundry instance.

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
```

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
```

No edits needed — the module and variable references are generic and driven by the tfvars values.

## Step 5 — Add LZ to GitHub Actions workflows

Edit `.github/workflows/terraform.yml`: add `<lzname>` to the `environment` input options list.
Edit `.github/workflows/appdeploy.yml`: add `<lzname>` to the `environment` input options list.

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
- AI Foundry endpoint
- Any next steps (deploy an app, configure model deployments)
