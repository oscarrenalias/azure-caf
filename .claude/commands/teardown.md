---
description: Destroy Azure resources in the correct reverse order — workload landing zones, then lz-platform, then hub — and purge the soft-deleted Foundry and APIM instances. Always confirms with the user before triggering destructive workflows.
allowed-tools: [Bash, Read]
---

You are helping the user tear down Azure infrastructure deployed by this repo. Order matters in two ways: landing zones must go before the hub, because they hold private endpoints and App Services that reference hub-managed DNS zones, route tables and VNets; and workload landing zones must go before `lz-platform`, because their Foundry connections point at its APIM gateway.

Destroy order: **workload LZs (lz01, lz02, …) → lz-platform → hub.**

**Always confirm with the user before triggering any destroy workflow. This is irreversible.**

## Step 1 — Determine scope

Ask the user what they want to destroy:
- A single workload landing zone (e.g. lz01 only)
- Everything: workload LZs, then lz-platform, then hub
- lz-platform only (breaks every workload LZ's model access — confirm that is intended)
- Hub only (only safe if all landing zones are already destroyed)

Tearing down `lz-platform` is more disruptive than it looks: APIM takes 30-45 minutes to
re-provision, and its name and subscription key change on re-create, so every
`config/lz<n>.tfvars` `apim_gateway_url` and the `APIM_SUBSCRIPTION_KEY_LZ<n>` repo
secret must be updated afterwards.

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

## Step 2b — Remove the toolbox and its connection

Only if the orders stack was deployed. These are created by hand from the jump host
(`app/toolbox/README.md`), so Terraform does not own them and a destroy leaves them
behind pointing at an APIM gateway that no longer exists.

**Confirm with user before running.** On the jump host:

```bash
azd ai project set "$FOUNDRY_PROJECT_ENDPOINT"
azd ai toolbox delete orders-toolbox --force
azd ai connection delete apim-orders-mcp --force
```

Do this before destroying lz-platform, so the toolbox is removed while the MCP server it
references still exists.

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

## Step 3b — Destroy lz-platform

Only after every workload landing zone is destroyed.

If the orders stack was deployed, destroying lz01 first leaves lz-platform holding an
`orders-api` whose backend no longer exists, and a `data.azurerm_function_app_host_keys`
lookup for a Function App that has gone — which fails the plan rather than the apply. If
the destroy errors on that lookup, blank `orders_function_name` in
`config/lz-platform.tfvars` and re-run: with it empty, `orders.tf` creates nothing and
Terraform simply removes what is in state.

Within the stack, MCP tools must go before the operations they reference. Terraform
destroys children first, so a normal destroy is fine; deleting the REST API by hand
first is not.

**Confirm with user before running.**

```bash
gh workflow run terraform.yml \
  -f environment=lz-platform \
  -f action=destroy \
  -f runner=ubuntu-latest
gh run watch
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

## Step 5 — Purge soft-deleted services

Two resource types here are soft-deleted rather than removed, and both keep consuming
their name and quota until purged. This bites on the next deploy, not on the destroy,
so it is easy to miss.

**Cognitive Services / AI Foundry accounts** (`hub<hex>` in a workload LZ, `aif<hex>`
in lz-platform) are recoverable for 48 hours:

```bash
az cognitiveservices account list-deleted --query "[].{name:name,location:location}" -o table
az cognitiveservices account purge --name <name> --location <location> --resource-group <rg>
```

**API Management** is soft-deleted for 48 hours and holds its name:

```bash
az apim deletedservice list --query "[].{name:name,location:location}" -o table
az apim deletedservice purge --service-name <name> --location <location>
```

Skipping this is usually harmless because both names carry a `random_id` suffix that
changes on re-create — but it matters if a deploy is retried from unchanged Terraform
state, and the deleted instances count against subscription quota either way.

## Step 6 — Manual cleanup (if full teardown)

If the user wants a complete cleanup including the bootstrap resources:

```bash
NUMBER=$(grep number config/global.tfvars | grep -oP '\d+')

# Delete state storage account + resource group
az group delete --name rgstate${NUMBER} --yes --no-wait

# Delete managed identity + resource group
az group delete --name rgmi${NUMBER} --yes --no-wait
```

Warn the user that deleting the state backend means Terraform state is lost. If they want to re-deploy later, they must re-run bootstrap and start fresh.

## Step 7 — Verify

```bash
NUMBER=$(grep number config/global.tfvars | grep -oP '\d+')
az group list --query "[?starts_with(name, 'rg${NUMBER}')].name" -o tsv
```

Expected output: empty (or only the bootstrap groups if Step 5 was skipped).

Report what was destroyed and what (if anything) remains.
