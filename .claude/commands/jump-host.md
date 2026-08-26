---
description: Check, start or repair the hub jump VM on its own — the self-hosted runner host and the only place local agent development works. Use after a subscription is re-enabled, after /pause-resume, or when a deploy workflow has no runner.
allowed-tools: [Bash, Read]
---

You are helping the user get the hub jump VM back into service without touching the rest
of the infrastructure. This VM matters more than its size suggests:

- It hosts the **self-hosted GitHub Actions runner**, so `appdeploy.yml` and
  `agentdeploy.yml` cannot run without it. `terraform.yml` runs on `ubuntu-latest` and is
  unaffected.
- Since the workload Foundry account became private-endpoint only, it is the **only place
  `azd ai agent run` works**. See `docs/vscode-remote-development.md`.

Common reasons it is down: `/pause-resume` deallocated it to save cost, or the
subscription hit its spending limit and Azure deallocated everything.

## Step 1 — Check the current state

```bash
source config/global.env

echo "subscription:"
az rest --method get --url "https://management.azure.com/subscriptions/${ARM_SUBSCRIPTION_ID}?api-version=2022-12-01" \
  --query "{state:state, spendingLimit:subscriptionPolicies.spendingLimit}" -o json

echo "jump VM:"
az vm get-instance-view -n jump7 -g rg${NUMBER}-hub \
  --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv

echo "runner:"
REPO=$(git remote get-url origin | sed 's|https://github.com/||;s|\.git$||')
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | "\(.name) \(.status)"'
```

**Check the subscription first.** Do not try to start anything while it reports
`Disabled` — every write fails with `ReadOnlyDisabledSubscription`, and a
`spendingLimit: On` with a `MSDN_*` quota id means the monthly credit is exhausted and it
will stay that way until the next billing period or the limit is removed. Note that
`az account show` reads the CLI's local cache and will happily report `Enabled` when the
subscription is disabled — always use the ARM GET above.

## Step 2 — Start it

Only if the state is `VM deallocated` or `VM stopped`:

```bash
source config/global.env
az vm start --resource-group rg${NUMBER}-hub --name jump7
```

Takes a minute or two. The runner service starts with the VM and registers itself again
within a couple of minutes of the VM reaching `VM running`.

## Step 3 — Confirm it is usable

```bash
source config/global.env
REPO=$(git remote get-url origin | sed 's|https://github.com/||;s|\.git$||')

# Runner back online?
gh api "repos/${REPO}/actions/runners" --jq '.runners[] | "\(.name) \(.status) busy=\(.busy)"'

# SSH reachable? (prints the VM's own hostname, so a reply of jump7 confirms end to end)
ssh -o BatchMode=yes -o ConnectTimeout=15 azure-jump hostname
```

If SSH times out, it is almost always the NSG source IP in `infra/hub/vm.tf`, which
allows a single address. Compare `curl -s ifconfig.me` with `source_address_prefix` and
apply the hub stack if they differ. If the `azure-jump` alias is unknown, the
`~/.ssh/config` entry is in `docs/vscode-remote-development.md`.

## Step 4 — If the runner does not come back

The VM is running but no runner registers:

```bash
ssh azure-jump 'sudo systemctl status actions.runner.* --no-pager | head -20'
ssh azure-jump 'sudo systemctl restart actions.runner.*'
```

If the service is missing entirely, the registration token from `cloud-init` has expired
(they last one hour) and the runner was never installed. Re-register by hand rather than
rebuilding the VM:

```bash
REPO=$(git remote get-url origin | sed 's|https://github.com/||;s|\.git$||')
gh api "repos/${REPO}/actions/runners/registration-token" --method POST --jq '.token'
# then on the VM, in ~/actions-runner: ./config.sh --url https://github.com/<repo> --token <token>
```

Rebuilding the VM is a last resort: `custom_data` is under `ignore_changes`, so a
Terraform apply will not re-run `cloud-init`, and tainting the VM destroys the
development environment set up on it (`~/azure-caf`, the `jumpdev` azd environment, uv).

## Step 5 — Report

Tell the user the subscription state, the VM power state, whether the runner is online,
and whether SSH works. If you started the VM, remind them it bills while running and that
`/pause-resume` deallocates it again.
