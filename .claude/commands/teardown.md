---
description: Destroy Azure resources in the correct reverse order — landing zones first, then hub. Prevents orphaned private endpoints and DNS records. Always confirms with the user before triggering destructive workflows.
allowed-tools: [Bash, Read]
---

You are helping the user tear down Azure infrastructure deployed by this repo. Order matters: landing zones must be destroyed before hub because they hold resources (private endpoints, App Services) that reference hub-managed resources (DNS zones, route tables, VNets).

**Always confirm with the user before triggering any destroy workflow. This is irreversible.**

## Step 1 — Determine scope

Ask the user what they want to destroy:
- A single landing zone (e.g. lz01 only)
- All landing zones, then hub (full teardown)
- Hub only (only safe if all landing zones are already destroyed)

## Step 2 — List deployed resources before proceeding

Show the user what will be destroyed:

```bash
NUMBER=$(grep number config/global.tfvars | grep -oP '\d+')
az group list --query "[?starts_with(name, 'rg${NUMBER}')].{name:name, location:location}" -o table
```

Also show any state backend resources:
```bash
az group list --query "[?starts_with(name, 'rgstate') || starts_with(name, 'rgmi')].{name:name}" -o table
```

Note: the state storage account (`rgstate<number>`) and managed identity (`rgmi<number>`) are NOT managed by Terraform — they must be deleted manually if doing a full cleanup.

## Step 3 — Destroy landing zones (in reverse order)

For each landing zone (lz01, lz02, etc.) that needs to be destroyed, run the destroy workflow. If multiple LZs exist, destroy them one at a time and wait for each to complete before starting the next.

**Confirm with user before each:**

```bash
gh workflow run terraform.yml \
  -f environment=<lzname> \
  -f action=destroy \
  -f runner=ubuntu-latest
gh run watch
```

Verify the resource group is empty after the workflow:
```bash
az resource list --resource-group rg<number>-<lzname> -o table
```

## Step 4 — Destroy hub

Only proceed after all landing zones are confirmed destroyed.

**Confirm with user before running.**

Note: the hub destroy workflow will also destroy the self-hosted runner VM. The `terraform.yml` workflow itself runs on `ubuntu-latest` so this is safe — it does not depend on the self-hosted runner.

```bash
gh workflow run terraform.yml \
  -f environment=hub \
  -f action=destroy \
  -f runner=ubuntu-latest
gh run watch
```

This destroys all VNets, peerings, firewall, route table, DNS zones, and the jump VM. The resource groups created by hub (`rg<number>-hub`, `rg<number>-lz01`, `rg<number>-lz02`) will be removed.

## Step 5 — Manual cleanup (if full teardown)

If the user wants a complete cleanup including the bootstrap resources:

```bash
NUMBER=$(grep number config/global.tfvars | grep -oP '\d+')

# Delete state storage account + resource group
az group delete --name rgstate${NUMBER} --yes --no-wait

# Delete managed identity + resource group
az group delete --name rgmi${NUMBER} --yes --no-wait
```

Warn the user that deleting the state backend means Terraform state is lost. If they want to re-deploy later, they must re-run bootstrap and start fresh.

## Step 6 — Verify

```bash
NUMBER=$(grep number config/global.tfvars | grep -oP '\d+')
az group list --query "[?starts_with(name, 'rg${NUMBER}')].name" -o tsv
```

Expected output: empty (or only the bootstrap groups if Step 5 was skipped).

Report what was destroyed and what (if anything) remains.
