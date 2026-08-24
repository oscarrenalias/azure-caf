# Developing on the jump host with VS Code Remote-SSH

## Why this is necessary

The lz01 Foundry account is network-injected (BYO VNet) and its data plane is
private-endpoint only. Tools like `azd` cannot be used for local development.

The jump host sits inside the hub VNet, which is peered to lz01, so it can reach the
Foundry account, AI Search and ACR over their private endpoints. Remote-SSH keeps the
IDE on your machine while the files and processes live there — you are not editing over
a terminal.

The App Service UI is unaffected: it keeps a public front door restricted to
`allowed_ips`, so `https://<app>.azurewebsites.net/` and its `/chat` endpoint stay
reachable from your workstation and are the quickest end-to-end smoke test.

## One-time setup

### 1. SSH access

The jump host accepts the key in `ssh_public_key` (`config/global.tfvars`) as user
`azureuser`, and its NSG allows one source IP, hardcoded in `infra/hub/vm.tf`. **If your
public IP has changed, update that rule and apply the hub stack first**, or nothing
below will connect:

```bash
curl -s ifconfig.me     # compare with source_address_prefix in infra/hub/vm.tf
```

Add a host entry to `~/.ssh/config`. Remote-SSH reads this file, so the alias is all you
need later:

```
Host azure-jump
  HostName <jump-host-public-ip>       # az network public-ip show -g rg<number>-hub -n publicip-jump --query ipAddress -o tsv
  User azureuser
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  LocalForward 8088 localhost:8088
  LocalForward 8087 localhost:8087
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

The `LocalForward` lines are only needed when driving the agent from a plain terminal.
VS Code forwards ports automatically, so they are harmless but redundant once you are
working in Remote-SSH.

Check it. This runs the `hostname` command on the VM and prints its name, so a
successful reply confirms the key, the NSG rule and the config entry are all correct:

```bash
$ ssh azure-jump hostname
jump7
```

### 2. VS Code extension

```bash
code --install-extension ms-vscode-remote.remote-ssh
```

Or intall the Remote-SSH extension from the VS Code marketplace.

### 3. Connect

```
Cmd+Shift+P → Remote-SSH: Connect to Host → azure-jump
File → Open Folder → /home/azureuser/azure-caf
```

The first connection installs the VS Code server on the VM (a minute or so; the hub
firewall already allows outbound 443). 

## What is already provisioned on the VM

| Item | Detail |
|---|---|
| `uv` | In `~/.local/bin`. Required — the agent's startup command is `uv run python main.py` |
| Checkout | `~/azure-caf`, deliberately separate from the runner workspace, which every deploy `rm -rf`s |
| azd environment | `jumpdev`, holding `FOUNDRY_PROJECT_ENDPOINT`, model deployment names and the Search settings |
| Azure auth | The VM's system-assigned identity has `Foundry Project Manager` on the account (`infra/lz01/roles.tf`), so `DefaultAzureCredential` uses IMDS. No `az login`, no credentials on disk |

## Running the agent

In a VS Code terminal, run this in the VM:

```bash
cd ~/azure-caf/app
git pull
azd ai agent run
```

VS Code detects port and forwards the following ports via the local workstation:

- 8088: managed agent port, exposes the `/readiness` and `/responses` endpoints
- 8087: web based user interface

The following should work:

`azd ai agent invoke --local` works the same way. Reading hosted agent logs
(`azd ai agent monitor`, `azd ai agent sessions`) also has to happen here, since those
talk to the same private data plane. These can all be conveniently run from Terminal sessions
in VS Code.

## Using Git from the VM

The checkout uses an `https` remote and the VM has no GitHub credentials — `gh` is not
installed and `git user.name` is unset — so **pushing from the VM will fail until you set
one up**. Pulling works. Three options:

1. **Agent forwarding** — add `ForwardAgent yes` to the `azure-jump` block, switch the
   remote to `git@github.com:<org>/<repo>.git`, and your local key is used from the VM.
   Requires that key to be registered on your GitHub account; at the time of writing
   `ssh -T git@github.com` returns `Permission denied (publickey)`, so it is not yet.
2. **`gh auth login` on the VM** — device-code flow, then the `https` remote works.

Set `git config --global user.name` and `user.email` on the VM whichever way you go.

## Troubleshooting

**`bind: Address already in use` on connect.** Something local holds 8087 or 8088 —
usually an `azure-ai-inspector` left over from an earlier workstation run. Find it with
`lsof -nP -iTCP:8087 -sTCP:LISTEN` and stop it. SSH still connects; only that forward is
skipped.

**SSH times out.** Almost always the NSG source IP. Check `curl -s ifconfig.me` against
`infra/hub/vm.tf` and apply the hub stack.

**`403 Public access is disabled` in a VS Code terminal.** You are on the workstation,
not the VM. Confirm with `hostname` — it should print `jump7`.

**Agent starts but the model call fails.** The VM identity may have lost its role
assignment, which is recreated whenever the Foundry account is replaced. Re-run
`agentdeploy.yml`, or apply the lz01 stack to restore `jump_vm_foundry_manager`.

**The VM is deallocated.** `/pause-resume` stops it to save cost, which also takes the
GitHub Actions runner offline. `az vm start --resource-group rg<number>-hub --name jump7`.