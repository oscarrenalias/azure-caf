# Roadmap

Open work, roughly in the order it makes sense to tackle it. Each item says why it
exists and how you would know it worked.

## RAG over the books — done, with quality follow-ups

The pipeline is live: `tools/epub2md.py` converts the epubs to markdown with one h2
heading per chapter, `tools/upload_content.py` uploads them with work metadata, and the
definitions in `search/` drive a blob indexer with integrated vectorization — markdown
`oneToMany` parsing, a Split skill, an embedding skill, and index projections producing
**873 chunks across 48 chapters**, each carrying its work, chapter, author and translator.
The agent queries with `VectorizableTextQuery`, so the index vectorizes the question and
the container holds no model credentials. Retrieval is hybrid (BM25 fused with vector
similarity by RRF) followed by semantic reranking.

Four constraints cost real time and are worth remembering, because each presented as a
different problem than it was:

- **Same-region storage cannot use a shared private link.** It needs a resource instance
  rule on the storage firewall, which requires the public endpoint present but denied by
  default. Symptom: "Credentials provided in the connection string are invalid or have
  expired", which points at auth.
- **Skillsets run in a multitenant environment by default**, where private endpoint
  connections do not work. Symptom: the embedding skill getting `403 Public access is
  disabled` while the data source connection on the same indexer succeeded. Fix:
  `executionEnvironment: private`.
- The vectorizer config key is `azureOpenAIParameters`, not `parameters`.
- The managed-identity connection string needs a trailing slash before the semicolon.

### Quality follow-ups

- **Grounding is not enforced.** On a corpus this famous, the model blends its own
  knowledge with the retrieved passages: asked to quote the Iliad's opening it produced a
  line from a different translation, not the Bryant text in the index. Worth raising
  `_TOP_K`, instructing it to answer only from the passages and quote verbatim, and
  considering whether to surface the retrieved text in the UI so drift is visible.
- **No work filter.** `title` is filterable in the index but the tool never uses it, so a
  question about the Odyssey can retrieve Iliad passages. Exposing a filter argument on
  the tool would let the agent scope a search.
- **Chunking is untuned.** 2000 characters with 200 of overlap was a starting point, never
  compared against alternatives. Broad questions retrieve five chunks and fall back on
  model knowledge.
- **Stale documents on re-index.** In `oneToMany` mode, removing sections leaves orphaned
  documents behind; delete a blob's documents before re-running if the markdown changes
  shape.
- **Dead app settings.** `infra/lz01/appservice.tf` sets `SEARCH_ENDPOINT` and
  `SEARCH_API_KEY` on the App Service, which the UI has never read — the agent does the
  retrieval. Worth removing, not least because it puts a search key where nothing uses it.
- **No ingestion runbook.** `docs/` should carry the convert → upload → apply → run
  sequence, including that all of it happens from the jump host.

## Open questions to settle

### Can APIM move to Internal VNet mode?

`infra/lz-platform/apim.tf` runs the gateway in **External** mode, which is the last
public ingress carrying model traffic. The original justification is obsolete: it existed
because connected-mode model calls came from Microsoft-managed compute outside the VNet,
and the workload Foundry account is now network-injected.

Whether Internal actually works is untested. Microsoft's
[template 16](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/16-private-network-standard-agent-apim-setup)
pairs an injected account with a private APIM, which suggests the Foundry-to-gateway leg
traverses the VNet once injected — but that is inference, not evidence.

To settle it:

1. Restore the `azure-api.net` private DNS zone in `infra/hub/main.tf` and an A record
   for the gateway's private IP. It was removed deliberately in `18afc6e`, because under
   External mode APIM exposes no private IP and a linked zone would shadow the public
   name — so this only makes sense as part of the flip.
2. Change `virtual_network_type` to `Internal`. Note azurerm treats this as force-new, so
   drive it out-of-band with `az apim update` as before; a Terraform-driven replacement
   would leave the new instance with no API, product, policy or subscription, because
   those children keep the same resource IDs.
3. Azure requires a **different public IP** when changing VNet type on an existing
   instance, even when moving to Internal. Expect the same dance as the last flip.
4. Invoke the hosted agent and confirm a model call completes.

Revert to External if the model call fails. Budget 30-45 minutes per direction.

If it does work, the follow-on question is whether the App Service and jump host still
resolve the gateway correctly, since both would then depend on the private DNS zone.

### Is the agent identity's role assignment actually needed?

`agentdeploy.yml` grants the platform-created agent identity `Foundry Project Manager` on
the account. It was added while chasing a different bug and never proven necessary — the
real causes turned out to be a dependency mismatch and the account ACL.

To settle it: remove the role assignment for the current agent identity, invoke the
hosted agent, and see whether it still completes. If it does, drop the step; if it does
not, the step stays and now has a reason.

## Cleanups

- **One source for the developer IP.** `config/lz01.tfvars` (`allowed_ips`, gating the
  App Service) and `infra/hub/vm.tf` (`source_address_prefix`, gating SSH) hardcode the
  same address independently. When it changes you lose the UI *and* SSH — and with SSH
  goes local development entirely. Drive both from one variable.
- **Per-LZ APIM subscription keys.** `terraform.yml` passes
  `secrets.APIM_SUBSCRIPTION_KEY_LZ01` to every environment, so a second landing zone
  would silently share lz01's key and its token limits. Either create a subscription per
  LZ in `lz-platform` and select the secret per environment, or document the sharing as
  deliberate.
- ~~**The `build-push` job in `agentdeploy.yml` is dead work.**~~ Done — the job, the
  Docker install, the ACR login and the unused image tag are gone. Deployment goes
  through `dependency_resolution: remote_build`, which builds from `pyproject.toml` +
  `uv.lock`, so nothing on the runner needs to build or push an image. If the deploy ever
  needs to ship a pre-built image instead, that is a switch to container mode, not a
  restoration of this job.
- **Git credentials on the jump host.** The checkout at `~/azure-caf` uses an `https`
  remote with no credentials, so pushes fail. See `docs/vscode-remote-development.md` for
  the options.
- **Federated credentials.** Per-branch entries accumulate on the
  `mihubspoke<number>` identity — `github-feature-lz-platform` and
  `github-feature-foundry-vnet-injection` are both merged and can go. Consider a wildcard
  subject or a `pull_request` credential instead of one per branch.

## Egress after removing the firewall

Azure Firewall is gone and `enable_firewall` defaults to off — it cost ~$900/month against
a ~$150 monthly credit and exhausted it in about five days, disabling the subscription and
stopping every resource. As configured it filtered nothing (any source, any destination,
443 and 53), so what was lost is the hub-and-spoke *pattern* of central egress, not a
control.

Routed subnets now rely on **Azure's default outbound access**. That works today — all
three report `defaultOutboundAccess: true`, and a `/chat` call through the whole chain was
verified after removal — but it has two weaknesses:

- **No stable egress IP.** Azure assigns them, so nothing downstream can allowlist us. If
  APIM ever moved back to Internal mode, or a third party needed an IP allowlist, this
  would block it.
- **Microsoft is retiring implicit outbound access** for newly created subnets. Existing
  subnets keep it, but a rebuild of the VNets would land on the new behaviour and leave
  the injected agent subnet with no route to APIM.

A **NAT Gateway** (~$0.045/hour, about $33/month plus data) is the durable answer: explicit
outbound, a stable IP, and roughly 4% of the firewall's cost. It is plumbing rather than a
firewall — no inspection or filtering — so re-enabling `enable_firewall` remains the option
if the demo needs to show egress control.

Worth doing before either the VNets are rebuilt or anything needs to allowlist this
environment. Until then, be aware that `enable_firewall = true` must be applied to the hub
*before* the landing zones, and removed from the landing zones *before* the hub.

## Deferred

- **Point-to-site VPN** on the reserved `gw` subnet (`10.1.1.0/24`). Would restore fully
  local development — local IDE, local files, local `azd`, and AI Search reachable for
  RAG work — instead of the jump-host loop. Roughly $0.19/hr for a VpnGw1 and about 30
  minutes to provision. Worth it if the remote loop stays irritating.
- **BYO data resources for the agent.** The account uses platform-managed storage for
  agent state (threads, files, vector stores). Moving to customer-managed Storage, Cosmos
  DB and AI Search is Microsoft's
  [template 15](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup)
  and matters if a client needs agent data in their own tenant. Adds three resources,
  their private endpoints, and both account- and project-level capability hosts.
- **Skill docs for the from-scratch path.** `.claude/commands/deploy-hub-spoke.md` has
  been updated for the current architecture but never exercised end to end from an empty
  subscription.
