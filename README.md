# Weekly Cluster Health

Automates the two recurring chores around the weekly ACM cluster:

1. **Troubleshoot a deploy that failed** — why didn't the cluster come up?
2. **Verify a deploy that succeeded** — is the hub actually in good working order?

The weekly cluster is provisioned by [rhacmstackem](https://github.com/KevinFCormier/rhacmstackem),
which claims a cluster from a Hive ClusterPool and deploys RHACM on it. When that
job fails, someone has to go digging by hand. That's what this repo is for.

## Failure domains

Deploy failures split into two very different investigations, and conflating them
is what makes manual debugging slow:

| Domain | What happened | Where to look |
|--------|---------------|---------------|
| **A** | No cluster came up — the claim never got a running cluster | ClusterPool host (collective): ClusterClaim, ClusterPool, ClusterDeployment, ClusterProvision |
| **A′** | Cluster came up, but RHACM failed to install on it | The claimed cluster: CatalogSource, image pulls, CSVs, MultiClusterHub |
| **B** | Cluster and RHACM are up, but the hub is degraded | The claimed cluster, via the ACM hub health agent |

Domains A and A′ are deterministic enough for plain `oc` + `jq` — that's `diagnose.sh`.
Domain B is where an AI agent earns its keep (planned, see below).

## diagnose.sh

Read-only. Never creates, patches, or deletes anything.

```bash
./diagnose.sh                          # defaults to the weekly claim
CLUSTERCLAIM_NAME=weekly-managed ./diagnose.sh
```

Run it while logged into the **ClusterPool host** (collective). It walks the
chain top-down and stops at the first conclusive answer:

1. **ClusterClaim** — `Pending` / `ClusterRunning` conditions. `Pending=True/NoClusters`
   means the pool had nothing to hand out.
2. **ClusterPool** (only if no cluster was ever assigned) — `ready`/`standby`/`size`
   against spec, pool conditions, and the pool-owned ClusterDeployments, so you can
   catch a provision failing in flight before Hive deprovisions and retries it.
3. **ClusterDeployment** — the provisioning conditions, with polarity handled
   correctly (most are negative polarity, `Provisioned` and `RequirementsMet` are not).
4. **ClusterProvision** — the classified failure reason and the tail of the
   installer log, reached via `.status.provisionRef.name`.
5. **Domain A′** — if a kubeconfig for the claimed cluster is available.

### Environment

| Variable | Default |
|----------|---------|
| `CLUSTERPOOL_TARGET_NAMESPACE` | `console-squad` |
| `CLUSTERCLAIM_NAME` | `weekly` |
| `CLUSTERPOOL_NAME` | read from the claim, else derived from the ISO week |
| `CLAIMED_KUBECONFIG` | Lifeguard's path, else `ck kubeconfig -r` |
| `INSTALL_LOG_LINES` | `40` |

The weekly CronJob alternates pools by ISO week parity (even → `cs-aws-50`,
odd → `cs-aws-422`); `diagnose.sh` mirrors that when it can't read the pool off
a claim. Pass `CLUSTERPOOL_NAME` explicitly when diagnosing an older run, since
the parity of *today* isn't the parity of the week that failed.

Needs `oc` and `jq`. `ck` ([cluster-keeper](https://github.com/stolostron/cluster-keeper))
is optional — it's only used to fetch a kubeconfig for the domain A′ checks.

### Notes on the implementation

A few things are deliberate, and worth knowing before changing them:

- **No `set -e`.** A diagnostic has to finish even when half its probes fail.
- **Provision failure reasons are reported, not interpreted.** Hive derives them
  from its `install-log-regexes` ConfigMap, which sites extend with their own
  patterns — any hardcoded list here would rot.
- **Resource names are looked up, never concatenated.** Hive truncates and hashes
  names past 63 characters, so `<cd>-<attempt>-<rand>` is not safe to build by hand.
- **The installer log comes from the `installer` container.** Hive's own
  troubleshooting docs say `hive`, but that's an init container that only copies
  binaries.

## Planned: domain B

[`acm-hub-health`](https://github.com/stolostron/acm-ai-qe/tree/main/apps/acm-hub-health)
is a Claude Code agent that diagnoses a running ACM hub. The intent is to run it
against the weekly cluster after a successful deploy and post the report to Slack.

Open items before that can be automated:

- Runs as a separate image/CronJob — the deploy image stays lean.
- Needs a GCP service account for Vertex; the interactive `setup.sh` steps
  (on-cluster `acm-search` MCP deployment) must be pre-baked, not run at runtime.
- Read-only to start. Gated auto-remediation only after it's been trusted for a while.
