---
description: Deploy or update an application to an existing landing zone App Service. Packages the app, triggers the appdeploy workflow on the self-hosted runner, and verifies the deployment.
allowed-tools: [Bash, Read]
---

You are helping the user deploy or update an application to an Azure App Service in one of the landing zones. The App Service is private-only, so deployment runs through the self-hosted GitHub Actions runner on the hub jump VM.

## Step 1 — Confirm inputs

Ask the user for:
1. Which landing zone to deploy to (e.g. `lz01`)
2. Which app directory to deploy (default: `app1`)
3. The App Service name — if they don't know it, look it up:

```bash
NUMBER=$(grep number config/global.tfvars | grep -oP '\d+')
LZ=<lzname>
az webapp list --resource-group rg${NUMBER}-${LZ} --query "[].{name:name, state:state}" -o table
```

## Step 2 — Check self-hosted runner is online

The appdeploy workflow requires the self-hosted runner (hub jump VM). Check it is registered and online:

```bash
gh api repos/${{ github.repository }}/actions/runners --jq '.runners[] | {name,status,busy}'
```

If no runner shows as `online`, the hub jump VM may need to be started or the runner service restarted. Instruct the user to SSH to the jump host and check `sudo systemctl status actions.runner.*`.

## Step 3 — Trigger deployment

```bash
gh workflow run appdeploy.yml \
  -f environment=<lzname> \
  -f appservice=<app-service-name>
```

Watch the run:
```bash
gh run list --workflow=appdeploy.yml --limit=3
gh run watch
```

The workflow:
1. Zips the app directory
2. Sets the startup command (`gunicorn --bind=0.0.0.0 --timeout 600 app:app`)
3. Deploys the zip via `az webapp deploy`

## Step 4 — Verify

After the workflow completes, verify the app is responding. The App Service has no public access, so the check must go through the jump host:

```bash
NUMBER=$(grep number config/global.tfvars | grep -oP '\d+')
JUMP_IP=$(az network public-ip show \
  --resource-group rg${NUMBER}-hub \
  --name publicip-jump \
  --query ipAddress -o tsv)
echo "SSH to jump host: ssh azureuser@${JUMP_IP}"
echo "Then run: curl https://<app-service-name>.azurewebsites.net/"
```

Instruct the user to run the curl from the jump host. The private DNS zone resolves the App Service hostname to a private IP reachable from within the VNets.

## Step 5 — Troubleshooting

If the deployment fails:
- Check the workflow logs: `gh run view --log`
- If the runner is missing: hub VM may be stopped — `az vm start --resource-group rg<number>-hub --name jump7`
- If the app crashes on startup: check App Service logs via `az webapp log tail --resource-group ... --name ...` from the jump host
- Startup command assumes `gunicorn` is in `requirements.txt` — verify it is present
