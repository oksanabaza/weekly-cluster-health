# Weekly Cluster Health

Automates the two recurring chores around the weekly ACM cluster:

1. **Troubleshoot a deploy that failed** — why didn't the cluster come up?
2. **Verify a deploy that succeeded** — is the hub actually in good working order?

The weekly cluster is provisioned by [rhacmstackem](https://github.com/KevinFCormier/rhacmstackem),
which claims a cluster from a Hive ClusterPool and deploys RHACM on it. When that
job fails, someone has to go digging by hand. That's what this repo is for.

## Failure domains

Deploy failures split into very different investigations, and conflating them
is what makes manual debugging slow:

| Domain | What happened | Where to look |
|--------|---------------|---------------|
| **A** | No cluster came up — the claim never got a running cluster | ClusterPool host (collective): ClusterClaim, ClusterPool, ClusterDeployment, ClusterProvision |
| **A′** | Cluster came up, but RHACM failed to install on it | The claimed cluster: CatalogSource, image pulls, CSVs, MultiClusterHub |
| **Import** | Hub is up, but the managed cluster never joined it | The hub: ManagedCluster `weekly-managed` |
| **B** | Cluster and RHACM are up, but the hub is degraded | The claimed cluster, via the ACM hub health agent |

A, A′ and Import are deterministic enough for plain `oc` + `jq` — that's `diagnose.sh`.
Domain B is where an AI agent earns its keep (planned, see below).

Import is its own domain because a hub can be flawless while the second CronJob,
`import-weekly-managed`, never landed its cluster — nothing in A or A′ would
notice. Its fix is also different: re-run that job, see `retry-import.sh`.

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
6. **Import** — on the hub, whether `weekly-managed` registered and its
   `HubAccepted` / `Joined` / `Available` conditions are all `True`. `Unknown`
   counts as bad: an `Available` that never reports is a half-finished import.

### Output

One table, printed once at the end — findings only mean anything next to each
other, and a report that streams out over twenty seconds can't be read as a whole.
Long Hive messages, resource listings and the installer log go under `DETAILS`
and `INSTALLER LOG` below it, so the table stays one line per check.

```
  ACM WEEKLY CLUSTER   weekly   2026-09-14 09:49 EDT
  api.collective.dev02.red-chesterfield.com:6443  |  ns console-squad  |  pool cs-aws-422

  ────────────────────────  ──────  ──────────────────────────────────────
  ClusterClaim              ok      created 2026-09-11T11:15:03Z
  ClusterDeployment         FAIL    ProvisionFailed=AWSInsufficientCapacity
  ClusterProvision          FAIL    stage=failed
  ────────────────────────  ──────  ──────────────────────────────────────
   DOMAIN A   Provisioning failed: AWSInsufficientCapacity
```

Progress goes to **stderr** and is erased when the report prints, so
`./diagnose.sh > report.txt` captures the report and nothing else. Colour is
used only when stdout is a terminal; `NO_COLOR=1` turns it off there too.

Domain A needs the ClusterPool host. Run against anything else and the claim,
pool and deployment rows read `skip` rather than `FAIL` — a cluster that was
never meant to hold those resources isn't evidence of a failed deploy. Domain A′
is independent and still runs, since it uses its own kubeconfig.

### Exit codes

The verdict, for callers that shouldn't have to grep the table:

| Code | Meaning |
|------|---------|
| `0` | Healthy — deploy is clean, safe to go on to a hub-health check |
| `1` | Domain A — no cluster came up |
| `2` | Domain A′ — cluster came up, RHACM did not install |
| `3` | Inconclusive, or domain A wasn't checked |
| `4` | Import — hub is up, managed cluster never joined it |

### Environment

| Variable | Default |
|----------|---------|
| `CLUSTERPOOL_TARGET_NAMESPACE` | `console-squad` |
| `CLUSTERCLAIM_NAME` | `weekly` |
| `MANAGED_CLUSTER_NAME` | `weekly-managed` |
| `CLUSTERPOOL_NAME` | read from the claim, else `cs-aws-50` |
| `CLAIMED_KUBECONFIG` | Lifeguard's path, else `ck kubeconfig -r` |
| `INSTALL_LOG_LINES` | `40` |

The weekly CronJob now claims from `cs-aws-50` only; `diagnose.sh` assumes that
pool when it can't read one off a claim. It used to alternate by ISO week parity
(even → `cs-aws-50`, odd → `cs-aws-422`), so pass `CLUSTERPOOL_NAME` explicitly
when diagnosing a run from back then.

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

## Re-running a job by hand

Once `diagnose.sh` has named the cause, the fix is often just to run the job
again. Instantiate it from the CronJob rather than applying a saved manifest —
Kubernetes fills in a fresh `ownerReference` and picks up the CronJob's current
spec, so there is no second copy to keep in sync:

```bash
oc create job -n console-squad \
  --from=cronjob/import-weekly-managed \
  retry-import-$(date +%m%d)
```

The job template sets `backoffLimit: 0`, so a retry that fails stops instead of
looping — read its logs and create another one.

## Planned: domain B

[`acm-hub-health`](https://github.com/stolostron/acm-ai-qe/tree/main/apps/acm-hub-health)
is a Claude Code agent that diagnoses a running ACM hub. The intent is to run it
against the weekly cluster after a successful deploy and post the report to Slack.

Open items before that can be automated:

- Runs as a separate image/CronJob — the deploy image stays lean.
- Needs a GCP service account for Vertex; the interactive `setup.sh` steps
  (on-cluster `acm-search` MCP deployment) must be pre-baked, not run at runtime.
- Read-only to start. Gated auto-remediation only after it's been trusted for a while.
