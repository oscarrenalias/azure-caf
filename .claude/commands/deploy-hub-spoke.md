---
description: Full from-scratch deployment of the hub-and-spoke landing zone. Walks through bootstrap, config, hub deploy, lz01 deploy, and initial app deploy in the correct order.
allowed-tools: [Bash, Read, Edit, Write]
---

You are helping the user deploy this Azure hub-and-spoke landing zone from scratch. Follow each phase in order, verifying prerequisites before proceeding. Stop and ask the user to confirm before any step that triggers a GitHub Actions workflow run, since those incur Azure costs.

## Phase 0 — Prerequisites check

Run these checks and report any missing tools before continuing:

```bash
az --version
jq --version
gh --version
```

Also verify the user is logged in to both Azure and GitHub:

```bash
az account show --query "{name:name, id:id, tenantId:tenantId}" -o table
gh auth status
```

If not logged into Azure, instruct them to run `! az login`.
If not logged into GitHub (`gh`), instruct them to run `! gh auth login`.

## Phase 1 — Bootstrap (one-time)

Read `config/global.env`. Then run these checks to determine whether bootstrap has already been run for the **current user's subscription**:

```bash
source config/global.env

ACTIVE_SUB=$(az account show --query id -o tsv)
echo "Active subscription : $ACTIVE_SUB"
echo "Config subscription : $ARM_SUBSCRIPTION_ID"
echo "ARM_CLIENT_ID       : ${ARM_CLIENT_ID:-(empty)}"

SA_STATE=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --query provisioningState -o tsv 2>&1)
echo "Storage account     : $STORAGE_ACCOUNT_NAME → $SA_STATE"
```

Only skip this phase if **all three** are true:
1. `ARM_CLIENT_ID` in `config/global.env` is non-empty
2. `ARM_SUBSCRIPTION_ID` matches the active Azure subscription
3. The storage account exists and returns `Succeeded`

If any check fails, bootstrap must be run:

1. Derive the GitHub repo from the git remote:
   ```bash
   git remote get-url origin | sed 's|https://github.com/||;s|\.git$||'
   ```
   Update `GITHUB_REPO` in `config/global.env` if it doesn't match.

2. Generate a fresh unique `NUMBER`:
   ```bash
   date +%s%N | cut -c1-14
   ```
   Update `NUMBER` in `config/global.env` and `number` in `config/global.tfvars` to match.

3. Run bootstrap and capture the output values into `config/global.env`:
   ```bash
   bash bootstrap.sh
   ```
   After it completes, update the outputs section of `config/global.env` with the printed `ARM_*` and `STORAGE_*` values.

## Phase 1b — Pre-deploy configuration

After bootstrap (or if it was already done), automate the three remaining config steps:

### SSH public key

Check whether `config/global.tfvars` already has a real SSH key (non-empty, starts with `ssh-`):

```bash
grep ssh_public_key config/global.tfvars
```

If absent or placeholder, find or generate one:

```bash
# Look for existing keys, prefer ed25519
for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
  [[ -f "$f" ]] && echo "Found: $f" && cat "$f" && break
done
```

If no key is found, generate one (confirm with user first):
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

Update `config/global.tfvars` with the public key value.

### NSG source IP

Get the user's current public IP and update the NSG rule in `infra/hub/vm.tf`:

```bash
MY_IP=$(curl -s ifconfig.me)
echo "Your public IP: $MY_IP"
```

Edit `infra/hub/vm.tf`: set `source_address_prefix = "${MY_IP}/32"` in the `azurerm_network_security_group.rule1` security rule.

### GitHub runner registration token (GH_RUNNER_PAT)

The runner registration token expires after 1 hour, so generate it immediately before triggering the hub deploy. Use the `gh` CLI to generate it and set it as a repo secret in one step:

```bash
source config/global.env
REPO=$(git remote get-url origin | sed 's|https://github.com/||;s|\.git$||')

TOKEN=$(gh api "repos/${REPO}/actions/runners/registration-token" --method POST --jq '.token')
gh secret set GH_RUNNER_PAT --body "$TOKEN" --repo "$REPO"
echo "GH_RUNNER_PAT set successfully (expires in 1 hour — trigger hub deploy promptly)"
```

Confirm with the user that the secret was set before proceeding.

## Phase 2 — Deploy Hub

The hub Terraform stack creates all VNets, peerings, Azure Firewall, the route table, the jump VM (which installs the GitHub Actions runner via cloud-init on first boot), and private DNS zones.

**Confirm with the user before running** — this incurs Azure costs (Azure Firewall is ~$1/hr).

```bash
gh workflow run terraform.yml \
  -f environment=hub \
  -f action=apply \
  -f runner=ubuntu-latest
```

Watch the run until complete:
```bash
gh run list --workflow=terraform.yml --limit=3
gh run watch
```

After the workflow completes, wait ~5 minutes for the jump VM's cloud-init to finish installing the runner. Then verify it is online:

```bash
REPO=$(git remote get-url origin | sed 's|https://github.com/||;s|\.git$||')
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | {name, status}'
```

Do not proceed to lz01 until a runner shows `"status": "online"`.

## Phase 3 — Deploy lz01

```bash
gh workflow run terraform.yml \
  -f environment=lz01 \
  -f action=apply \
  -f runner=ubuntu-latest

gh run watch
```

## Phase 3b — Deploy lz-platform (AI Gateway)

lz-platform hosts shared AI Foundry (gpt-4o) and APIM as the AI Gateway. All workload LZs call APIM instead of AI Foundry directly.

**Warning: APIM (Developer SKU) takes 30-45 minutes to provision. This is normal — do not cancel the workflow.**

```bash
gh workflow run terraform.yml \
  -f environment=lz-platform \
  -f action=apply \
  -f runner=ubuntu-latest

gh run watch
```

After the workflow completes, note the `apim_gateway_url` output — workload apps use this as their Azure OpenAI base URL (e.g. `https://apim<hex>.azure-api.net/openai`). The `api-key` header accepts an APIM product subscription key.

To get an APIM subscription key for a workload team:
```bash
source config/global.env
APIM=$(az apim list --resource-group rg${NUMBER}-lz-platform --query "[0].name" -o tsv)
az apim product subscription list \
  --resource-group rg${NUMBER}-lz-platform \
  --service-name $APIM \
  --product-id ai-platform \
  --query "[0].primaryKey" -o tsv
```

## Phase 4 — Deploy app1

Look up the App Service name:

```bash
source config/global.env
az webapp list --resource-group rg${NUMBER}-lz01 --query "[].name" -o tsv
```

Trigger the app deploy (runs on the self-hosted runner — the App Service is private-only):
```bash
gh workflow run appdeploy.yml \
  -f environment=lz01 \
  -f appservice=<app-service-name>

gh run watch
```

## Phase 5 — Verify

Get the jump host IP and print connection instructions:

```bash
source config/global.env
JUMP_IP=$(az network public-ip show \
  --resource-group rg${NUMBER}-hub \
  --name publicip-jump \
  --query ipAddress -o tsv)
APP=$(az webapp list --resource-group rg${NUMBER}-lz01 --query "[0].name" -o tsv)

echo "Jump host : ssh azureuser@${JUMP_IP}"
echo "Then run  : curl https://${APP}.azurewebsites.net/"
echo "Expected  : Hello World"
```

Report a full summary: resource groups created, jump host IP, App Service name and private URL, AI Foundry endpoint.
