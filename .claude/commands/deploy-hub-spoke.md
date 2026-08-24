---
description: Full from-scratch deployment of the hub-and-spoke landing zone. Walks through bootstrap, config, hub, lz-platform (AI Gateway), lz01, and the agent and UI deploys in the correct order.
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

## Phase 3 — Deploy lz-platform (shared models + AI Gateway)

lz-platform holds the shared AI Foundry models and APIM as the AI Gateway in front of
them. It must be applied **before** any workload landing zone: lz01's Foundry
connection is configured with the gateway URL and a subscription key that don't exist
until this stack is up.

**APIM (Developer SKU) takes 30-45 minutes to provision. This is normal — do not
cancel the workflow.**

```bash
gh workflow run terraform.yml \
  -f environment=lz-platform \
  -f action=apply \
  -f runner=ubuntu-latest

gh run watch
```

### Wire the gateway into lz01

```bash
source config/global.env
REPO=$(git remote get-url origin | sed 's|https://github.com/||;s|\.git$||')
APIM=$(az apim list --resource-group rg${NUMBER}-lz-platform --query "[0].name" -o tsv)
APIM_RG="rg${NUMBER}-lz-platform"
BASE="https://management.azure.com/subscriptions/${ARM_SUBSCRIPTION_ID}/resourceGroups/${APIM_RG}/providers/Microsoft.ApiManagement/service/${APIM}"

echo "Set this in config/lz01.tfvars:"
echo "apim_gateway_url = \"https://${APIM}.azure-api.net/openai\""

SUB=$(az rest --method get --url "${BASE}/subscriptions?api-version=2024-05-01" \
  --query "value[?properties.displayName=='AI Platform Default'].name | [0]" -o tsv)
KEY=$(az rest --method post --url "${BASE}/subscriptions/${SUB}/listSecrets?api-version=2024-05-01" \
  --query primaryKey -o tsv)

gh secret set APIM_SUBSCRIPTION_KEY_LZ01 --body "$KEY" --repo "$REPO"
```

Set `apim_gateway_url` in `config/lz01.tfvars` to the URL printed above. The workflow
passes the secret to Terraform as `TF_VAR_apim_subscription_key`.

Also set `allowed_ips` in `config/lz01.tfvars` to the developer's public IP. It gates
the App Service only — how the UI is opened in a browser. The Foundry account, ACR and
AI Search are private-endpoint only, so nothing else uses it:

```bash
echo "allowed_ips = [\"$(curl -s ifconfig.me)\"]"
```

## Phase 4 — Deploy lz01

```bash
gh workflow run terraform.yml \
  -f environment=lz01 \
  -f action=apply \
  -f runner=ubuntu-latest

gh run watch
```

## Phase 5 — Deploy the application

Two deployables, both on the self-hosted runner. Deploy the agent first — the UI calls
it.

```bash
# LangGraph agent → Foundry Agent Service
gh workflow run agentdeploy.yml -f environment=lz01
gh run watch

# FastAPI chat UI → App Service
source config/global.env
APP=$(az webapp list --resource-group rg${NUMBER}-lz01 --query "[0].name" -o tsv)
gh workflow run appdeploy.yml -f environment=lz01 -f appservice=$APP
gh run watch
```

## Phase 6 — Verify

The App Service allows the IPs in `allowed_ips`, so verify directly from the
workstation — no jump host needed. This exercises the whole chain: UI → hosted agent →
connected-mode model → APIM → shared Foundry.

```bash
source config/global.env
APP=$(az webapp list --resource-group rg${NUMBER}-lz01 --query "[0].name" -o tsv)

curl -s -o /dev/null -w "UI: HTTP %{http_code}\n" "https://${APP}.azurewebsites.net/"

curl -s -X POST "https://${APP}.azurewebsites.net/chat" \
  -H "Content-Type: application/json" \
  -d '{"message":"hello"}'
```

Expect `HTTP 200` and a JSON `{"response": "...", "response_id": "..."}`.

If `/chat` returns 502 with an agent 500 inside it, the request is failing before it
reaches the agent container. Check the container is healthy and see whether it logs an
inbound request at all:

```bash
export FOUNDRY_PROJECT_ENDPOINT="https://<hub>.services.ai.azure.com/api/projects/<proj>"
azd ai agent sessions create --agent-name rag-agent --version <n>
azd ai agent monitor rag-agent --session-id <id> --follow
```

A healthy container serving `/readiness` with no inbound `POST /responses` means the
platform rejected the call upstream — usually the Foundry account's network ACL. See
"AI Gateway network posture" in CLAUDE.md.

Report a full summary: resource groups created, jump host IP, App Service name and
URL, APIM gateway URL, and the Foundry project endpoint.
