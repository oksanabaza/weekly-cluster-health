#! /bin/bash

# Print the path to a kubeconfig for the cluster a ClusterClaim currently holds.
#
# Read-only. Run it while logged into the ClusterPool host (collective).
#
#   KUBECONFIG=$(./claimed-kubeconfig.sh) oc get nodes
#
# This is its own script because two very different things need the same answer:
# diagnose.sh, for its domain A' and import checks, and anything that has to run
# *on* the claimed cluster - the domain B hub-health agent - which would
# otherwise mean copying an oc login line out of the web console by hand.
#
# Sources, in order:
#   1. CLAIMED_KUBECONFIG, if the caller already has one
#   2. the path Lifeguard writes, when running inside the deploy job
#   3. the admin kubeconfig Secret Hive keeps for the ClusterDeployment
#   4. cluster-keeper, if it happens to be installed
#
# Source 3 is the one that needs no extra tooling and no browser: Hive put that
# Secret on the pool host when it provisioned the cluster, and we are already
# logged in there.
#
# Prints nothing and exits 1 when nothing works.

set -uo pipefail

CLUSTERPOOL_TARGET_NAMESPACE=${CLUSTERPOOL_TARGET_NAMESPACE:-"console-squad"}
CLUSTERCLAIM_NAME=${CLUSTERCLAIM_NAME:-"weekly"}
CLAIMED_KUBECONFIG=${CLAIMED_KUBECONFIG:-""}

# 1. Already have one
if [[ -n "${CLAIMED_KUBECONFIG}" && -f "${CLAIMED_KUBECONFIG}" ]]; then
  echo "${CLAIMED_KUBECONFIG}"
  exit 0
fi

# 2. Inside the deploy job, Lifeguard has written one
LIFEGUARD_KUBECONFIG="${LIFEGUARD_PATH:-/lifeguard}/clusterclaims/${CLUSTERCLAIM_NAME}/kubeconfig"
if [[ -f "${LIFEGUARD_KUBECONFIG}" ]]; then
  echo "${LIFEGUARD_KUBECONFIG}"
  exit 0
fi

# 3. Hive's admin kubeconfig Secret, read off the ClusterDeployment.
#
# The claim's .spec.namespace is both the name and the namespace of the
# ClusterDeployment - and it is empty until a cluster is actually assigned,
# which is the whole of domain A and not something to report on here.
CLUSTERDEPLOYMENT=$(oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterclaim.hive \
  "${CLUSTERCLAIM_NAME}" -o jsonpath='{.spec.namespace}' 2>/dev/null)

if [[ -n "${CLUSTERDEPLOYMENT}" ]]; then
  # Look the Secret name up rather than guessing it: Hive generates it, and the
  # naming has changed across versions.
  SECRET=$(oc get -n "${CLUSTERDEPLOYMENT}" clusterdeployment.hive "${CLUSTERDEPLOYMENT}" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)

  if [[ -n "${SECRET}" ]]; then
    # 077 so the kubeconfig is not world-readable even for the instant it takes
    # oc extract to fill it - it holds admin credentials for the cluster.
    umask 077
    OUT="${TMPDIR:-/tmp}/weekly-cluster-health-${CLUSTERCLAIM_NAME}.kubeconfig"

    # Always overwrite, never reuse what is already there. The claim name is
    # recycled every week, so a file left from last week would point at a real
    # cluster that is simply the wrong one - the worst kind of stale.
    if oc extract -n "${CLUSTERDEPLOYMENT}" "secret/${SECRET}" \
         --keys=kubeconfig --to=- >"${OUT}" 2>/dev/null && [[ -s "${OUT}" ]]; then
      echo "${OUT}"
      exit 0
    fi
    rm -f "${OUT}"
  fi
fi

# 4. cluster-keeper, if the team has it set up. -r forces a fresh fetch.
if command -v ck &>/dev/null; then
  CK_PATH=$(ck kubeconfig -r "${CLUSTERCLAIM_NAME}" 2>/dev/null | tail -1)
  if [[ -n "${CK_PATH}" && -f "${CK_PATH}" ]]; then
    echo "${CK_PATH}"
    exit 0
  fi
fi

exit 1
