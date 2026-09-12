#! /bin/bash

# Diagnose a failed RHACMStackEm deployment and print a report.
#
# Read-only: this script never creates, patches, or deletes anything.
#
# It covers two failure domains:
#   A  - No cluster came up (ClusterClaim never got a running cluster)
#   A' - Cluster came up but RHACM failed to deploy on it
#
# Run against the ClusterPool cluster (collective). If a kubeconfig for the
# claimed cluster is available, domain A' checks run too.
#
# Required : CLUSTERPOOL_TARGET_NAMESPACE, CLUSTERCLAIM_NAME
# Optional : CLUSTERPOOL_NAME, CLAIMED_KUBECONFIG, INSTALL_LOG_LINES

# No `set -e` on purpose: a diagnostic must keep going when a probe fails.
set -uo pipefail

CLUSTERPOOL_TARGET_NAMESPACE=${CLUSTERPOOL_TARGET_NAMESPACE:-"console-squad"}
CLUSTERCLAIM_NAME=${CLUSTERCLAIM_NAME:-"weekly"}
CLUSTERPOOL_NAME=${CLUSTERPOOL_NAME:-""}
CLAIMED_KUBECONFIG=${CLAIMED_KUBECONFIG:-""}
INSTALL_LOG_LINES=${INSTALL_LOG_LINES:-40}

# Headline verdict, refined as evidence is gathered
VERDICT="Unknown - no conclusive evidence found"
DOMAIN="?"

# Condition polarity per Hive's apis/hive/v1. Most ClusterDeployment conditions
# are negative polarity (True means something is wrong); these two are not.
CD_BAD_WHEN_TRUE="ProvisionFailed ProvisionStopped DNSNotReady InstallImagesNotResolved InstallerImageResolutionFailed InstallLaunchError AuthenticationFailure"
CD_BAD_WHEN_FALSE="Provisioned RequirementsMet"

function section {
  echo ""
  echo "$(date) ##### $*"
}

# The weekly CronJob alternates pools by ISO week parity. Mirrored here so the
# usual case needs no arguments - pass CLUSTERPOOL_NAME to inspect another pool.
#
# 10# forces base 10: date +%V zero-pads, and bash reads 08 and 09 as invalid
# octal, which aborts the whole if-statement rather than falling through.
function poolForCurrentWeek {
  local week
  week=$(date +%V)
  if (( 10#${week} % 2 == 0 )); then
    echo "cs-aws-50"
  else
    echo "cs-aws-422"
  fi
}

# Find a kubeconfig for the claimed cluster. Three sources, in order:
#   1. CLAIMED_KUBECONFIG, if the caller set it
#   2. the path Lifeguard writes, when running inside the deploy job
#   3. cluster-keeper, which fetches a fresh copy from the ClusterDeployment
# Echoes the path, or nothing if none is available.
function resolveClaimedKubeconfig {
  if [[ -n "${CLAIMED_KUBECONFIG}" && -f "${CLAIMED_KUBECONFIG}" ]]; then
    echo "${CLAIMED_KUBECONFIG}"
    return
  fi

  local lifeguardPath="${LIFEGUARD_PATH:-/lifeguard}/clusterclaims/${CLUSTERCLAIM_NAME}/kubeconfig"
  if [[ -f "${lifeguardPath}" ]]; then
    echo "${lifeguardPath}"
    return
  fi

  if command -v ck &>/dev/null; then
    # -r forces a fresh fetch; a stale kubeconfig would misreport the cluster
    ck kubeconfig -r "${CLUSTERCLAIM_NAME}" 2>/dev/null | tail -1
  fi
}

# Print "type=reason: message" for a condition, or nothing if it looks healthy.
# $1 JSON conditions array, $2 condition type, $3 status that means "bad"
function reportCondition {
  echo "$1" | jq -r --arg t "$2" --arg bad "$3" '
    .[]? | select(.type == $t and .status == $bad)
    | "  [!] \(.type)=\(.reason // "?") - \(.message // "" | .[0:400])"'
}

section "Diagnosing ${CLUSTERCLAIM_NAME} in ${CLUSTERPOOL_TARGET_NAMESPACE}"
echo "* Hub: $(oc whoami --show-server 2>/dev/null || echo "unknown")"

##############################################################################
# ClusterClaim
##############################################################################
section "ClusterClaim"
CLAIM_JSON=$(oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterclaim.hive "${CLUSTERCLAIM_NAME}" -o json 2>/dev/null)
if [[ -z "${CLAIM_JSON}" ]]; then
  echo "* No ClusterClaim named ${CLUSTERCLAIM_NAME} exists in ${CLUSTERPOOL_TARGET_NAMESPACE}"

  # Easy mistake: passing the pool name instead of the claim name. rhacmstackem
  # names claims "rhacmstackem-<pool>" by default, but the CronJob may override it.
  if oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterpool.hive "${CLUSTERCLAIM_NAME}" &>/dev/null; then
    echo "  Note: ${CLUSTERCLAIM_NAME} is a ClusterPool, not a ClusterClaim."
    CLUSTERPOOL_NAME="${CLUSTERCLAIM_NAME}"
    echo "  Claims against this pool:"
    oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterclaim.hive -o json 2>/dev/null \
      | jq -r --arg p "${CLUSTERPOOL_NAME}" '.items[]? | select(.spec.clusterPoolName == $p)
        | "    \(.metadata.name)  created=\(.metadata.creationTimestamp)  cluster=\(.spec.namespace // "(none)")"' \
      | sed '/^$/d' || true
    echo "  Re-run with CLUSTERCLAIM_NAME set to one of the above."
    VERDICT="${CLUSTERCLAIM_NAME} is a pool name - re-run with an actual claim name"
  else
    echo "  Claims that do exist in this namespace:"
    oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterclaim.hive \
      -o custom-columns='NAME:.metadata.name,POOL:.spec.clusterPoolName,CREATED:.metadata.creationTimestamp' \
      2>/dev/null | sed 's/^/    /'
    echo "  If the name is right, the deploy failed before it created a claim -"
    echo "  check the job logs for StartRHACM errors."
    VERDICT="No ClusterClaim named ${CLUSTERCLAIM_NAME} - verify the name before concluding the deploy failed"
  fi
else
  CLAIM_CONDITIONS=$(echo "${CLAIM_JSON}" | jq -r '.status.conditions // []')
  CLUSTERDEPLOYMENT=$(echo "${CLAIM_JSON}" | jq -r '.spec.namespace // ""')
  echo "* Created:          $(echo "${CLAIM_JSON}" | jq -r '.metadata.creationTimestamp')"
  echo "* Assigned cluster: ${CLUSTERDEPLOYMENT:-"(none yet)"}"
  echo "* Pool:             $(echo "${CLAIM_JSON}" | jq -r '.spec.clusterPoolName // "?"')"

  # ClusterClaim has exactly two conditions: Pending (True is bad) and
  # ClusterRunning (False is bad).
  PENDING_REASON=$(echo "${CLAIM_CONDITIONS}" | jq -r '.[]? | select(.type == "Pending" and .status == "True") | .reason // ""')
  reportCondition "${CLAIM_CONDITIONS}" "Pending" "True"
  reportCondition "${CLAIM_CONDITIONS}" "ClusterRunning" "False"

  if [[ -z "${CLUSTERPOOL_NAME}" ]]; then
    CLUSTERPOOL_NAME=$(echo "${CLAIM_JSON}" | jq -r '.spec.clusterPoolName // ""')
  fi

  case "${PENDING_REASON}" in
    NoClusters)
      VERDICT="ClusterPool had no cluster ready to claim"
      DOMAIN="A"
      ;;
    AssignmentConflict)
      VERDICT="Assigned cluster was claimed by a different ClusterClaim"
      DOMAIN="A"
      ;;
    ClusterAssigned)
      VERDICT="Cluster was assigned but never finished resuming"
      DOMAIN="A"
      ;;
  esac
fi

##############################################################################
# ClusterPool - only interesting when nothing was claimable
##############################################################################
# With no claim to read the pool from, fall back to the CronJob's week parity.
if [[ -z "${CLUSTERPOOL_NAME}" && -z "${CLUSTERDEPLOYMENT:-}" ]]; then
  CLUSTERPOOL_NAME=$(poolForCurrentWeek)
  echo "* Pool unknown - assuming ${CLUSTERPOOL_NAME} for ISO week $(date +%V)"
  echo "  Diagnosing an older run? Pass CLUSTERPOOL_NAME explicitly."
fi

if [[ -n "${CLUSTERPOOL_NAME}" && -z "${CLUSTERDEPLOYMENT:-}" ]]; then
  section "ClusterPool ${CLUSTERPOOL_NAME}"
  POOL_JSON=$(oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterpool.hive "${CLUSTERPOOL_NAME}" -o json 2>/dev/null)
  if [[ -z "${POOL_JSON}" ]]; then
    echo "* ClusterPool ${CLUSTERPOOL_NAME} not found in ${CLUSTERPOOL_TARGET_NAMESPACE}"
    VERDICT="ClusterPool ${CLUSTERPOOL_NAME} does not exist"
  else
    echo "${POOL_JSON}" | jq -r '"* ready=\(.status.ready // 0) standby=\(.status.standby // 0) size=\(.status.size // 0)  (spec: size=\(.spec.size) runningCount=\(.spec.runningCount // 0) maxSize=\(.spec.maxSize // "unset"))"'

    # rhacmstackem scales the pool down after a deploy (CLUSTERPOOL_POST_DEPLOY_SIZE),
    # so spec.size=0 is normal *between* deploys - but fatal if a claim is waiting.
    if [[ "$(echo "${POOL_JSON}" | jq -r '.spec.size')" == "0" ]]; then
      echo "  [!] Pool is scaled to 0, so nothing can be claimed from it."
      echo "      Expected between deploys; a problem if a claim is still Pending."
      if [[ "${PENDING_REASON:-}" == "NoClusters" ]]; then
        VERDICT="ClusterPool ${CLUSTERPOOL_NAME} is scaled to 0 and was never scaled back up"
      fi
    fi

    POOL_CONDITIONS=$(echo "${POOL_JSON}" | jq -r '.status.conditions // []')
    # MissingDependencies is negative polarity; the rest here are positive.
    reportCondition "${POOL_CONDITIONS}" "MissingDependencies" "True"
    reportCondition "${POOL_CONDITIONS}" "CapacityAvailable" "False"
    reportCondition "${POOL_CONDITIONS}" "InventoryValid" "False"

    # A pool that can't fill itself is usually failing to provision its own
    # clusters, which Hive then deprovisions and retries - so catch one in flight.
    # Built from JSON rather than custom-columns: with pipefail, a non-zero exit
    # from oc on an empty result made the fallback fire alongside a header row.
    echo "* Pool-owned ClusterDeployments:"
    POOL_CDS=$(oc get clusterdeployment.hive -A -l "hive.openshift.io/clusterpool-name=${CLUSTERPOOL_NAME}" -o json 2>/dev/null \
      | jq -r '.items[]? | "    \(.metadata.namespace)/\(.metadata.name)  installed=\(.spec.installed // false)  provisioned=\([.status.conditions[]? | select(.type == "Provisioned") | .reason] | first // "?")  restarts=\(.status.installRestarts // 0)"')
    echo "${POOL_CDS:-"    (none)"}"
  fi
fi

##############################################################################
# ClusterDeployment + ClusterProvision - the real provisioning failure
##############################################################################
if [[ -n "${CLUSTERDEPLOYMENT:-}" ]]; then
  section "ClusterDeployment ${CLUSTERDEPLOYMENT}"
  CD_JSON=$(oc get -n "${CLUSTERDEPLOYMENT}" clusterdeployment.hive "${CLUSTERDEPLOYMENT}" -o json 2>/dev/null)
  if [[ -z "${CD_JSON}" ]]; then
    echo "* ClusterDeployment ${CLUSTERDEPLOYMENT} not found (already cleaned up?)"
  else
    echo "${CD_JSON}" | jq -r '"* installed=\(.spec.installed // false) powerState=\(.status.powerState // "?") installRestarts=\(.status.installRestarts // 0)"'
    CD_CONDITIONS=$(echo "${CD_JSON}" | jq -r '.status.conditions // []')
    for t in ${CD_BAD_WHEN_TRUE}; do reportCondition "${CD_CONDITIONS}" "${t}" "True"; done
    for t in ${CD_BAD_WHEN_FALSE}; do reportCondition "${CD_CONDITIONS}" "${t}" "False"; done

    # Release/installer image problems are their own failure class
    if echo "${CD_CONDITIONS}" | jq -e '.[]? | select((.type == "InstallImagesNotResolved" or .type == "InstallerImageResolutionFailed") and .status == "True")' >/dev/null 2>&1; then
      VERDICT="Could not resolve the OCP release/installer image - check the ClusterImageSet"
      DOMAIN="A"
    fi

    # The classified failure reason lives on the ClusterProvision, not the CD.
    # Never build the provision name by hand - Hive hashes long names.
    PROVISION=$(echo "${CD_JSON}" | jq -r '.status.provisionRef.name // ""')
    if [[ -n "${PROVISION}" ]]; then
      section "ClusterProvision ${PROVISION}"
      PROV_JSON=$(oc get -n "${CLUSTERDEPLOYMENT}" clusterprovision.hive "${PROVISION}" -o json 2>/dev/null)
      if [[ -n "${PROV_JSON}" ]]; then
        PROV_STAGE=$(echo "${PROV_JSON}" | jq -r '.spec.stage // "?"')
        echo "* stage: ${PROV_STAGE}"
        PROV_REASON=$(echo "${PROV_JSON}" | jq -r '.status.conditions[]? | select(.type == "ClusterProvisionFailed" and .status == "True") | .reason // ""')
        echo "${PROV_JSON}" | jq -r '.status.conditions[]? | select(.type == "ClusterProvisionFailed" and .status == "True") | "  [!] \(.reason // "?") - \(.message // "" | .[0:600])"'
        echo "${PROV_JSON}" | jq -r '.status.conditions[]? | select(.type == "InstallPodStuck" and .status == "True") | "  [!] InstallPodStuck=\(.reason // "?") - \(.message // "")"'

        if [[ -n "${PROV_REASON}" ]]; then
          # Reasons come from Hive's install-log-regexes ConfigMap and sites can
          # add their own, so report the reason rather than interpreting it.
          VERDICT="Provisioning failed: ${PROV_REASON}"
          DOMAIN="A"
        fi

        # Only read the installer log when the provision actually failed - on a
        # successful install it is pages of noise that buries the real findings.
        if [[ "${PROV_STAGE}" == "failed" || -n "${PROV_REASON}" ]]; then
          # installLog is the full openshift-install console log, password-scrubbed
          # by Hive. Absent if the install pod never got far enough to write it.
          echo "* Last ${INSTALL_LOG_LINES} lines of the installer log:"
          INSTALL_LOG=$(echo "${PROV_JSON}" | jq -r '.spec.installLog // ""')
          if [[ -n "${INSTALL_LOG}" ]]; then
            echo "${INSTALL_LOG}" | tail -n "${INSTALL_LOG_LINES}" | sed 's/^/    /'
          else
            echo "    (no installLog on the ClusterProvision - falling back to the pod)"
            # Container is "installer"; "hive" is only an init container that copies binaries.
            oc logs -n "${CLUSTERDEPLOYMENT}" -l "hive.openshift.io/cluster-provision-name=${PROVISION}" \
              -c installer --tail="${INSTALL_LOG_LINES}" 2>/dev/null | sed 's/^/    /' \
              || echo "    (provision pod is gone too)"
          fi
        fi
      fi
    fi
  fi
fi

##############################################################################
# Domain A' - cluster exists, so check whether RHACM itself failed to install
##############################################################################
RESOLVED_KUBECONFIG=$(resolveClaimedKubeconfig)
if [[ -z "${RESOLVED_KUBECONFIG}" || ! -f "${RESOLVED_KUBECONFIG}" ]]; then
  section "RHACM install on the claimed cluster"
  echo "* No kubeconfig for ${CLUSTERCLAIM_NAME} - skipping domain A' checks"
  if command -v ck &>/dev/null; then
    echo "  'ck kubeconfig -r ${CLUSTERCLAIM_NAME}' returned nothing - is that claim name right?"
  else
    echo "  Set CLAIMED_KUBECONFIG, or install cluster-keeper so 'ck kubeconfig' can fetch one."
  fi
else
  section "RHACM install on the claimed cluster"
  echo "* Using kubeconfig: ${RESOLVED_KUBECONFIG}"
  export KUBECONFIG="${RESOLVED_KUBECONFIG}"
  if ! oc get nodes &>/dev/null; then
    echo "* Cluster is not reachable with this kubeconfig - skipping"
  else
    # Read MCH first: it decides whether anything else here is worth alarming about.
    MCH_PHASE=$(oc get multiclusterhub -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null)

    # Image problems show up here first: a CatalogSource that can't be pulled.
    CATALOG_STATE=$(oc get catalogsource acm-custom-registry -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)
    if [[ -z "${CATALOG_STATE}" ]]; then
      # Not an error on its own - the catalog source is only needed to install.
      echo "* CatalogSource acm-custom-registry: (not present)"
      if [[ "${MCH_PHASE}" != "Running" ]]; then
        echo "  [!] ACM is not Running and there is no catalog source to install it from."
        VERDICT="No ACM CatalogSource and ACM is not running - the catalog was never created"
        DOMAIN="A'"
      fi
    else
      echo "* CatalogSource acm-custom-registry: ${CATALOG_STATE}"
      if [[ "${CATALOG_STATE}" != "READY" ]]; then
        echo "  Image: $(oc get catalogsource acm-custom-registry -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null)"
        VERDICT="ACM CatalogSource is ${CATALOG_STATE} - the ACM catalog image could not be served"
        DOMAIN="A'"
      fi
    fi

    echo "* Pods stuck pulling images:"
    PULL_ERRORS=$(oc get pods -A -o json 2>/dev/null | jq -r '
      .items[]
      | . as $p
      | (.status.containerStatuses // []) + (.status.initContainerStatuses // [])
      | .[]
      | select(.state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")
      | "    \($p.metadata.namespace)/\($p.metadata.name): \(.state.waiting.reason) - \(.state.waiting.message // "" | .[0:200])"' | head -20)
    if [[ -n "${PULL_ERRORS}" ]]; then
      echo "${PULL_ERRORS}"
      VERDICT="Image pull failures on the cluster - bad tag or expired pull secret"
      DOMAIN="A'"
    else
      echo "    (none)"
    fi

    echo "* Failed CSVs / Subscriptions:"
    OLM_FAILURES=$(
      oc get csv -A -o json 2>/dev/null | jq -r '.items[]? | select(.status.phase == "Failed") | "    \(.metadata.namespace)/\(.metadata.name): \(.status.reason // "?") - \(.status.message // "" | .[0:200])"'
      oc get subscription -A -o json 2>/dev/null | jq -r '.items[]? | select((.status.conditions // [])[]? | select(.type == "ResolutionFailed" and .status == "True")) | "    \(.metadata.namespace)/\(.metadata.name): ResolutionFailed"'
    )
    if [[ -n "${OLM_FAILURES}" ]]; then
      echo "${OLM_FAILURES}" | head -20
      if [[ "${MCH_PHASE}" != "Running" ]]; then
        VERDICT="OLM could not install ACM - see the failed CSVs/Subscriptions above"
        DOMAIN="A'"
      fi
    else
      echo "    (none)"
    fi

    echo "* MultiClusterHub:"
    MCH_INFO=$(oc get multiclusterhub -A -o json 2>/dev/null \
      | jq -r '.items[]? | "    \(.metadata.namespace)/\(.metadata.name)  phase=\(.status.phase // "?")  version=\(.status.currentVersion // "?")"')
    if [[ -n "${MCH_INFO}" ]]; then
      echo "${MCH_INFO}"
      if [[ "${MCH_PHASE}" != "Running" ]]; then
        VERDICT="MultiClusterHub is ${MCH_PHASE:-unknown}, not Running"
        DOMAIN="A'"
      fi
    else
      echo "    (none - ACM never got installed)"
      VERDICT="No MultiClusterHub on the cluster - RHACM was never installed"
      DOMAIN="A'"
    fi
  fi
  unset KUBECONFIG
fi

##############################################################################
# A healthy deploy should say so plainly. "Unknown" is for when the evidence
# really was inconclusive, not for when there was simply nothing wrong.
if [[ "${DOMAIN}" == "?" && "${MCH_PHASE:-}" == "Running" ]]; then
  VERDICT="No problems found - cluster is up and MultiClusterHub is Running"
  DOMAIN="-"
fi

section "Verdict"
echo "* Domain:  ${DOMAIN}  (A = no cluster, A' = cluster up but RHACM failed, - = healthy)"
echo "* Verdict: ${VERDICT}"
