#! /bin/bash

# Domain B: run the acm-hub-health agent against the claimed cluster.
#
# Chains onto diagnose.sh, which exits 0 only on a clean deploy - a hub that
# never installed has nothing for the agent to inspect:
#
#   ./diagnose.sh && ./hub-health.sh
#   ./hub-health.sh sanity      # 30s pulse instead of the standard check
#
# Run from the ClusterPool host: the kubeconfig for the hub is fetched from
# there, so you never log into the weekly cluster by hand.
#
# Needs a checkout of stolostron/acm-ai-qe. Run `claude` and then /onboard in
# apps/acm-hub-health once first - it configures the MCP servers and credentials.
#
# acm-hub defaults to print mode, which presents a remediation plan but cannot
# execute it. Leave it that way until the agent has earned more trust.

set -euo pipefail

ACM_HUB=${ACM_HUB:-"${HOME}/work/acm-ai-qe/apps/acm-hub-health/acm-hub"}

# Resolve while still logged into the pool host, before KUBECONFIG is replaced.
KUBECONFIG=$("$(dirname "${BASH_SOURCE[0]}")/claimed-kubeconfig.sh")
export KUBECONFIG

(( $# )) || set -- check

"${ACM_HUB}" "$@"
