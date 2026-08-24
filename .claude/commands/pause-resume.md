---
description: Pause or resume the hub's expensive resources (Azure Firewall + jump VM). Pause saves ~$1.25/hr; resume takes ~10 minutes.
allowed-tools: [Bash, Read]
---

You are helping the user pause or resume the most expensive hourly resources in the hub — the Azure Firewall and the jump VM.

What this does and does not cover:

- **Still billed while paused:** APIM Developer SKU in lz-platform, the App Service plan, AI Search, and any model usage. Pausing does not make the environment free — it removes the ~$1.25/hr firewall and the VM's compute.
- **Still working while paused:** the chat UI and the hosted agent. The agent runs on Foundry-managed compute outside the VNet, and the App Service reaches it over a private endpoint. The workflow removes the route table along with the firewall, so VNet egress goes direct to the internet rather than through a next hop that no longer exists.
- **Not working while paused:** anything needing the self-hosted runner. `appdeploy.yml` and `agentdeploy.yml` both run on the jump VM, so deployments must wait for a resume. Terraform runs on `ubuntu-latest` and are unaffected.

## Determine the action

If the user typed `/pause-resume` without arguments, check the current state first to suggest the right action:

```bash
source config/global.env
FW=$(az network firewall show --resource-group rg${NUMBER}-hub --name fw-001 --query provisioningState -o tsv 2>/dev/null || echo "not found")
VM=$(az vm get-instance-view --resource-group rg${NUMBER}-hub --name jump7 --query instanceView.statuses[1].displayStatus -o tsv 2>/dev/null || echo "unknown")
echo "Firewall : $FW"
echo "Jump VM  : $VM"
```

- If firewall is `Succeeded` → suggest **pause**
- If firewall is `not found` → suggest **resume**

## Get the current branch

```bash
BRANCH=$(git branch --show-current)
echo "Current branch: $BRANCH"
```

Use this branch for the `--ref` flag when triggering the workflow.

## Pause

Pauses billing for the firewall (~$1.25/hr) and VM compute. Async — completes in ~8 minutes.

```bash
gh workflow run pause-resume.yml \
  --ref $BRANCH \
  -f action=pause
```

Then watch:
```bash
sleep 5 && gh run list --workflow=pause-resume.yml --limit=3
gh run watch
```

After completion:
- Azure Firewall: destroyed (route table also cleaned up — will be recreated on resume)
- Jump VM: deallocated (runner goes offline; disk and NIC preserved)
- Savings: ~$1.25/hr while paused

## Resume

Recreates the firewall and starts the VM. Takes ~10 minutes total.

```bash
gh workflow run pause-resume.yml \
  --ref $BRANCH \
  -f action=resume
```

Watch:
```bash
sleep 5 && gh run list --workflow=pause-resume.yml --limit=3
gh run watch
```

After completion:
- Firewall is back with a fresh private IP; the route table is updated automatically by Terraform
- VM starts and the self-hosted runner comes back online within ~2 minutes of the VM reaching `Running` state

Verify runner is online:
```bash
REPO=$(git remote get-url origin | sed 's|https://github.com/||;s|\.git$||')
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | {name, status}'
```
