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
# Findings are collected as they are gathered and printed as one table at the
# end. Progress goes to stderr, so stdout is only ever the report.
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

# Pool to assume when there is no claim to read one off. The weekly CronJob used
# to alternate between cs-aws-50 and cs-aws-422 by ISO week parity; it now only
# claims from cs-aws-50. Diagnosing a run from back then? Pass CLUSTERPOOL_NAME,
# because the parity of today is not the parity of the week that failed.
DEFAULT_CLUSTERPOOL_NAME="cs-aws-50"

# Headline verdict, refined as evidence is gathered
VERDICT="No conclusive evidence found"
DOMAIN="?"

# Set when the cluster we are logged into turns out not to be the ClusterPool
# host, which makes every domain A finding meaningless rather than bad.
NOT_POOL_HOST=0

# Condition polarity per Hive's apis/hive/v1. Most ClusterDeployment conditions
# are negative polarity (True means something is wrong); these two are not.
CD_BAD_WHEN_TRUE="ProvisionFailed ProvisionStopped DNSNotReady InstallImagesNotResolved InstallerImageResolutionFailed InstallLaunchError AuthenticationFailure"
CD_BAD_WHEN_FALSE="Provisioned RequirementsMet"

# Colour only when stdout is a terminal, so a redirected report stays plain text.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'
  BOLD=$'\033[1m'; RESET=$'\033[0m'
  BADGE_OK=$'\033[7;32m'; BADGE_BAD=$'\033[7;31m'; BADGE_MEH=$'\033[7;33m'
else
  RED=""; GREEN=""; YELLOW=""; DIM=""; BOLD=""; RESET=""
  BADGE_OK=""; BADGE_BAD=""; BADGE_MEH=""
fi

# Report is assembled here rather than echoed inline: findings only make sense
# next to each other, and a half-printed table is worse than none.
ROWS=()      # one line per check:  name <US> status <US> detail
NOTES=()     # condition messages and listings, too long for the table
LOGBLOCK=""  # installer log tail, printed last
SEP=$'\x1f'  # unit separator - safe inside Hive messages, unlike '|'

# $1 check name, $2 status (ok|FAIL|warn|skip), $3 one-line detail
function addRow {
  ROWS+=("$1${SEP}$2${SEP}$3")
}

# Indent to match the table, unless the note already carries its own (the
# multi-line listings are pre-indented so their inner lines line up).
function addNote {
  if [[ "$1" == " "* ]]; then
    NOTES+=("$1")
  else
    NOTES+=("  $1")
  fi
}

# Collapse to one line and clip, so a 4KB Hive message can't wreck the table.
function short {
  local text=${1//$'\n'/ }
  text=$(echo "${text}" | tr -s ' ' | sed 's/^ *//; s/ *$//')
  if (( ${#text} > 56 )); then
    echo "${text:0:53}..."
  else
    echo "${text}"
  fi
}

# Progress on stderr, overwritten in place - it is scaffolding, not output.
function progress {
  [[ -t 2 ]] || return 0
  printf "\r\033[K${DIM}  ... %s${RESET}" "$*" >&2
}

function progressDone {
  [[ -t 2 ]] || return 0
  printf "\r\033[K" >&2
}

# Emit "Type=Reason<US>message" for every condition of a bad status.
# $1 JSON conditions array, $2 space-separated types, $3 status meaning "bad"
function badConditions {
  echo "$1" | jq -r --arg types "$2" --arg bad "$3" --arg sep "${SEP}" '
    ($types | split(" ")) as $wanted
    | .[]?
    | select(.status == $bad and ((.type as $t | $wanted | index($t)) != null))
    | "\(.type)=\(.reason // "?")\($sep)\(.message // "" | gsub("\\s+"; " ") | .[0:300])"'
}

# Record every bad condition as a note and accumulate "Type=Reason" into
# COND_SUMMARY for the table row. Results come back through a global rather
# than stdout on purpose: in $(...) the whole function runs in a subshell and
# every addNote is thrown away with it.
# $1 resource label, $2 conditions JSON, $3 types, $4 bad status
COND_SUMMARY=""
function noteConditions {
  local summary message
  while IFS="${SEP}" read -r summary message; do
    [[ -z "${summary}" ]] && continue
    if [[ -z "${COND_SUMMARY}" ]]; then
      COND_SUMMARY="${summary}"
    else
      COND_SUMMARY+=", ${summary}"
    fi
    addNote "  ${RED}[!]${RESET} $1  ${BOLD}${summary}${RESET}"
    [[ -n "${message}" ]] && addNote "      ${message}"
  done < <(badConditions "$2" "$3" "$4")
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

##############################################################################
# ClusterClaim
##############################################################################
progress "reading ClusterClaim ${CLUSTERCLAIM_NAME}"
HUB=$(oc whoami --show-server 2>/dev/null || echo "unknown")
CLAIM_JSON=$(oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterclaim.hive "${CLUSTERCLAIM_NAME}" -o json 2>/dev/null)

if [[ -z "${CLAIM_JSON}" ]]; then
  # Easy mistake: passing the pool name instead of the claim name. rhacmstackem
  # names claims "rhacmstackem-<pool>" by default, but the CronJob may override it.
  if oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterpool.hive "${CLUSTERCLAIM_NAME}" &>/dev/null; then
    addRow "ClusterClaim" "warn" "${CLUSTERCLAIM_NAME} is a ClusterPool, not a claim"
    CLUSTERPOOL_NAME="${CLUSTERCLAIM_NAME}"
    CLAIMS_ON_POOL=$(oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterclaim.hive -o json 2>/dev/null \
      | jq -r --arg p "${CLUSTERPOOL_NAME}" '.items[]? | select(.spec.clusterPoolName == $p)
        | "      \(.metadata.name)  created=\(.metadata.creationTimestamp)  cluster=\(.spec.namespace // "(none)")"')
    addNote "${YELLOW}[?]${RESET} Claims against pool ${CLUSTERPOOL_NAME}, re-run with one of these as CLUSTERCLAIM_NAME:"
    addNote "${CLAIMS_ON_POOL:-"      (none)"}"
    VERDICT="${CLUSTERCLAIM_NAME} is a pool name - re-run with an actual claim name"
  elif [[ "$(oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterpool.hive -o name 2>/dev/null | wc -l | tr -d ' ')" == "0" ]]; then
    # No claims and no pools at all: this is almost certainly not the ClusterPool
    # host. Reporting domain A as failed here would be reporting on a cluster that
    # was never supposed to hold these resources - so check nothing and say why.
    NOT_POOL_HOST=1
    addRow "ClusterClaim" "skip" "not the ClusterPool host - domain A not checked"
    addNote "${YELLOW}[?]${RESET} ${HUB#https://} has no ClusterClaims and no ClusterPools in ${CLUSTERPOOL_TARGET_NAMESPACE}."
    addNote "      Domain A lives on the ClusterPool host (collective). Log in there and re-run:"
    addNote "      oc login --server=https://api.collective.dev02.red-chesterfield.com:6443"
    VERDICT="Not logged into the ClusterPool host - domain A was not checked"
  else
    addRow "ClusterClaim" "FAIL" "no claim named ${CLUSTERCLAIM_NAME}"
    EXISTING_CLAIMS=$(oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterclaim.hive -o json 2>/dev/null \
      | jq -r '.items[]? | "      \(.metadata.name)  pool=\(.spec.clusterPoolName // "?")  created=\(.metadata.creationTimestamp)"')
    addNote "${RED}[!]${RESET} Claims that do exist in ${CLUSTERPOOL_TARGET_NAMESPACE}:"
    addNote "${EXISTING_CLAIMS:-"      (none)"}"
    addNote "      If the name is right, the deploy failed before creating a claim - check the job logs."
    VERDICT="No ClusterClaim named ${CLUSTERCLAIM_NAME} - verify the name before concluding the deploy failed"
  fi
else
  CLAIM_CONDITIONS=$(echo "${CLAIM_JSON}" | jq -r '.status.conditions // []')
  CLUSTERDEPLOYMENT=$(echo "${CLAIM_JSON}" | jq -r '.spec.namespace // ""')
  CLAIM_CREATED=$(echo "${CLAIM_JSON}" | jq -r '.metadata.creationTimestamp')

  if [[ -z "${CLUSTERPOOL_NAME}" ]]; then
    CLUSTERPOOL_NAME=$(echo "${CLAIM_JSON}" | jq -r '.spec.clusterPoolName // ""')
  fi

  # ClusterClaim has exactly two conditions: Pending (True is bad) and
  # ClusterRunning (False is bad).
  PENDING_REASON=$(echo "${CLAIM_CONDITIONS}" | jq -r '.[]? | select(.type == "Pending" and .status == "True") | .reason // ""')
  COND_SUMMARY=""
  noteConditions "ClusterClaim" "${CLAIM_CONDITIONS}" "Pending" "True"
  noteConditions "ClusterClaim" "${CLAIM_CONDITIONS}" "ClusterRunning" "False"

  if [[ -n "${COND_SUMMARY}" ]]; then
    addRow "ClusterClaim" "FAIL" "$(short "${COND_SUMMARY}")"
  else
    addRow "ClusterClaim" "ok" "created ${CLAIM_CREATED}"
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
# With no claim to read the pool from, fall back to the pool the CronJob uses.
if (( ! NOT_POOL_HOST )) && [[ -z "${CLUSTERPOOL_NAME}" && -z "${CLUSTERDEPLOYMENT:-}" ]]; then
  CLUSTERPOOL_NAME="${DEFAULT_CLUSTERPOOL_NAME}"
  addNote "${DIM}[i]${RESET} Pool unknown - assuming ${CLUSTERPOOL_NAME}. Diagnosing a run from when pools alternated by week? Pass CLUSTERPOOL_NAME."
fi

if (( ! NOT_POOL_HOST )) && [[ -n "${CLUSTERPOOL_NAME}" && -z "${CLUSTERDEPLOYMENT:-}" ]]; then
  progress "reading ClusterPool ${CLUSTERPOOL_NAME}"
  POOL_JSON=$(oc get -n "${CLUSTERPOOL_TARGET_NAMESPACE}" clusterpool.hive "${CLUSTERPOOL_NAME}" -o json 2>/dev/null)
  if [[ -z "${POOL_JSON}" ]]; then
    addRow "ClusterPool" "FAIL" "${CLUSTERPOOL_NAME} not found"
    VERDICT="ClusterPool ${CLUSTERPOOL_NAME} does not exist"
  else
    POOL_SIZES=$(echo "${POOL_JSON}" | jq -r '"ready=\(.status.ready // 0) standby=\(.status.standby // 0) size=\(.spec.size) runningCount=\(.spec.runningCount // 0)"')
    POOL_CONDITIONS=$(echo "${POOL_JSON}" | jq -r '.status.conditions // []')
    COND_SUMMARY=""
    noteConditions "ClusterPool" "${POOL_CONDITIONS}" "MissingDependencies" "True"
    noteConditions "ClusterPool" "${POOL_CONDITIONS}" "CapacityAvailable InventoryValid" "False"

    # rhacmstackem scales the pool down after a deploy (CLUSTERPOOL_POST_DEPLOY_SIZE),
    # so spec.size=0 is normal *between* deploys - but fatal if a claim is waiting.
    POOL_STATUS="ok"
    if [[ -n "${COND_SUMMARY}" ]]; then
      POOL_STATUS="FAIL"
    elif [[ "$(echo "${POOL_JSON}" | jq -r '.spec.size')" == "0" ]]; then
      if [[ "${PENDING_REASON:-}" == "NoClusters" ]]; then
        POOL_STATUS="FAIL"
        VERDICT="ClusterPool ${CLUSTERPOOL_NAME} is scaled to 0 and was never scaled back up"
        addNote "  ${RED}[!]${RESET} Pool ${CLUSTERPOOL_NAME} is scaled to 0, so the claim had nothing to take."
      else
        POOL_STATUS="warn"
        addNote "  ${DIM}[i]${RESET} Pool ${CLUSTERPOOL_NAME} is scaled to 0 - expected between deploys, a problem only if a claim is Pending."
      fi
    fi
    addRow "ClusterPool" "${POOL_STATUS}" "${CLUSTERPOOL_NAME}  ${POOL_SIZES}"

    # A pool that can't fill itself is usually failing to provision its own
    # clusters, which Hive then deprovisions and retries - so catch one in flight.
    # Built from JSON rather than custom-columns: with pipefail, a non-zero exit
    # from oc on an empty result made the fallback fire alongside a header row.
    POOL_CDS=$(oc get clusterdeployment.hive -A -l "hive.openshift.io/clusterpool-name=${CLUSTERPOOL_NAME}" -o json 2>/dev/null \
      | jq -r '.items[]? | "      \(.metadata.namespace)/\(.metadata.name)  installed=\(.spec.installed // false)  provisioned=\([.status.conditions[]? | select(.type == "Provisioned") | .reason] | first // "?")  restarts=\(.status.installRestarts // 0)"')
    if [[ -n "${POOL_CDS}" ]]; then
      addNote "${DIM}[i]${RESET} ClusterDeployments owned by ${CLUSTERPOOL_NAME}:"
      addNote "${POOL_CDS}"
    fi
  fi
fi

##############################################################################
# ClusterDeployment + ClusterProvision - the real provisioning failure
##############################################################################
if [[ -n "${CLUSTERDEPLOYMENT:-}" ]]; then
  progress "reading ClusterDeployment ${CLUSTERDEPLOYMENT}"
  CD_JSON=$(oc get -n "${CLUSTERDEPLOYMENT}" clusterdeployment.hive "${CLUSTERDEPLOYMENT}" -o json 2>/dev/null)
  if [[ -z "${CD_JSON}" ]]; then
    addRow "ClusterDeployment" "warn" "${CLUSTERDEPLOYMENT} not found (cleaned up?)"
  else
    CD_SUMMARY=$(echo "${CD_JSON}" | jq -r '"\(if .spec.installed then "installed" else "NOT installed" end), powerState=\(.status.powerState // "?"), restarts=\(.status.installRestarts // 0)"')
    CD_CONDITIONS=$(echo "${CD_JSON}" | jq -r '.status.conditions // []')
    COND_SUMMARY=""
    noteConditions "ClusterDeployment" "${CD_CONDITIONS}" "${CD_BAD_WHEN_TRUE}" "True"
    noteConditions "ClusterDeployment" "${CD_CONDITIONS}" "${CD_BAD_WHEN_FALSE}" "False"

    if [[ -n "${COND_SUMMARY}" ]]; then
      addRow "ClusterDeployment" "FAIL" "$(short "${COND_SUMMARY}")"
    else
      addRow "ClusterDeployment" "ok" "${CD_SUMMARY}"
    fi

    # Release/installer image problems are their own failure class
    if echo "${CD_CONDITIONS}" | jq -e '.[]? | select((.type == "InstallImagesNotResolved" or .type == "InstallerImageResolutionFailed") and .status == "True")' >/dev/null 2>&1; then
      VERDICT="Could not resolve the OCP release/installer image - check the ClusterImageSet"
      DOMAIN="A"
    fi

    # The classified failure reason lives on the ClusterProvision, not the CD.
    # Never build the provision name by hand - Hive hashes long names.
    PROVISION=$(echo "${CD_JSON}" | jq -r '.status.provisionRef.name // ""')
    if [[ -n "${PROVISION}" ]]; then
      progress "reading ClusterProvision ${PROVISION}"
      PROV_JSON=$(oc get -n "${CLUSTERDEPLOYMENT}" clusterprovision.hive "${PROVISION}" -o json 2>/dev/null)
      if [[ -n "${PROV_JSON}" ]]; then
        PROV_STAGE=$(echo "${PROV_JSON}" | jq -r '.spec.stage // "?"')
        PROV_CONDITIONS=$(echo "${PROV_JSON}" | jq -r '.status.conditions // []')
        PROV_REASON=$(echo "${PROV_JSON}" | jq -r '.status.conditions[]? | select(.type == "ClusterProvisionFailed" and .status == "True") | .reason // ""')
        COND_SUMMARY=""
        noteConditions "ClusterProvision" "${PROV_CONDITIONS}" "ClusterProvisionFailed InstallPodStuck" "True"

        if [[ -n "${COND_SUMMARY}" || "${PROV_STAGE}" == "failed" ]]; then
          addRow "ClusterProvision" "FAIL" "stage=${PROV_STAGE}  $(short "${COND_SUMMARY}")"
        else
          addRow "ClusterProvision" "ok" "stage=${PROV_STAGE}"
        fi

        if [[ -n "${PROV_REASON}" ]]; then
          # Reasons come from Hive's install-log-regexes ConfigMap and sites can
          # add their own, so report the reason rather than interpreting it.
          VERDICT="Provisioning failed: ${PROV_REASON}"
          DOMAIN="A"
        fi

        # Only read the installer log when the provision actually failed - on a
        # successful install it is pages of noise that buries the real findings.
        if [[ "${PROV_STAGE}" == "failed" || -n "${PROV_REASON}" ]]; then
          progress "reading installer log"
          # installLog is the full openshift-install console log, password-scrubbed
          # by Hive. Absent if the install pod never got far enough to write it.
          INSTALL_LOG=$(echo "${PROV_JSON}" | jq -r '.spec.installLog // ""')
          if [[ -z "${INSTALL_LOG}" ]]; then
            # Container is "installer"; "hive" is only an init container that copies binaries.
            INSTALL_LOG=$(oc logs -n "${CLUSTERDEPLOYMENT}" -l "hive.openshift.io/cluster-provision-name=${PROVISION}" \
              -c installer --tail="${INSTALL_LOG_LINES}" 2>/dev/null)
          fi
          if [[ -n "${INSTALL_LOG}" ]]; then
            LOGBLOCK=$(echo "${INSTALL_LOG}" | tail -n "${INSTALL_LOG_LINES}" | sed 's/^/      /')
          else
            LOGBLOCK="      (no installLog on the ClusterProvision, and the provision pod is gone)"
          fi
        fi
      fi
    fi
  fi
fi

##############################################################################
# Domain A' - cluster exists, so check whether RHACM itself failed to install
##############################################################################
progress "looking for a kubeconfig"
RESOLVED_KUBECONFIG=$(resolveClaimedKubeconfig)

if [[ -z "${RESOLVED_KUBECONFIG}" || ! -f "${RESOLVED_KUBECONFIG}" ]]; then
  addRow "Claimed cluster" "skip" "no kubeconfig - domain A' not checked"
  if command -v ck &>/dev/null; then
    addNote "${DIM}[i]${RESET} 'ck kubeconfig -r ${CLUSTERCLAIM_NAME}' returned nothing - is that claim name right?"
  else
    addNote "${DIM}[i]${RESET} Set CLAIMED_KUBECONFIG, or install cluster-keeper so 'ck kubeconfig' can fetch one."
  fi
else
  export KUBECONFIG="${RESOLVED_KUBECONFIG}"
  progress "connecting to the claimed cluster"
  if ! oc get nodes &>/dev/null; then
    addRow "Claimed cluster" "FAIL" "not reachable with ${RESOLVED_KUBECONFIG##*/}"
  else
    # Read MCH first: it decides whether anything else here is worth alarming about.
    progress "reading MultiClusterHub"
    MCH_PHASE=$(oc get multiclusterhub -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null)

    # Image problems show up here first: a CatalogSource that can't be pulled.
    progress "reading CatalogSource"
    CATALOG_STATE=$(oc get catalogsource acm-custom-registry -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)
    if [[ -z "${CATALOG_STATE}" ]]; then
      # Not an error on its own - the catalog source is only needed to install.
      if [[ "${MCH_PHASE}" == "Running" ]]; then
        addRow "CatalogSource" "skip" "not present (ACM already installed)"
      else
        addRow "CatalogSource" "FAIL" "not present, and ACM is not Running"
        VERDICT="No ACM CatalogSource and ACM is not running - the catalog was never created"
        DOMAIN="A'"
      fi
    elif [[ "${CATALOG_STATE}" == "READY" ]]; then
      addRow "CatalogSource" "ok" "acm-custom-registry READY"
    else
      addRow "CatalogSource" "FAIL" "acm-custom-registry ${CATALOG_STATE}"
      addNote "${RED}[!]${RESET} Catalog image: $(oc get catalogsource acm-custom-registry -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null)"
      VERDICT="ACM CatalogSource is ${CATALOG_STATE} - the ACM catalog image could not be served"
      DOMAIN="A'"
    fi

    progress "scanning pods for image pull failures"
    PULL_ERRORS=$(oc get pods -A -o json 2>/dev/null | jq -r '
      .items[]
      | . as $p
      | (.status.containerStatuses // []) + (.status.initContainerStatuses // [])
      | .[]
      | select(.state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")
      | "      \($p.metadata.namespace)/\($p.metadata.name): \(.state.waiting.reason) - \(.state.waiting.message // "" | .[0:200])"' | head -20)
    if [[ -n "${PULL_ERRORS}" ]]; then
      addRow "Image pulls" "FAIL" "$(echo "${PULL_ERRORS}" | wc -l | tr -d ' ') pod(s) stuck pulling"
      addNote "${RED}[!]${RESET} Pods stuck pulling images:"
      addNote "${PULL_ERRORS}"
      VERDICT="Image pull failures on the cluster - bad tag or expired pull secret"
      DOMAIN="A'"
    else
      addRow "Image pulls" "ok" "none stuck"
    fi

    progress "reading CSVs and Subscriptions"
    OLM_FAILURES=$(
      oc get csv -A -o json 2>/dev/null | jq -r '.items[]? | select(.status.phase == "Failed") | "      \(.metadata.namespace)/\(.metadata.name): \(.status.reason // "?") - \(.status.message // "" | .[0:200])"'
      oc get subscription -A -o json 2>/dev/null | jq -r '.items[]? | select((.status.conditions // [])[]? | select(.type == "ResolutionFailed" and .status == "True")) | "      \(.metadata.namespace)/\(.metadata.name): ResolutionFailed"'
    )
    if [[ -n "${OLM_FAILURES}" ]]; then
      addRow "OLM" "FAIL" "$(echo "${OLM_FAILURES}" | wc -l | tr -d ' ') failed CSV/Subscription(s)"
      addNote "${RED}[!]${RESET} Failed CSVs / Subscriptions:"
      addNote "$(echo "${OLM_FAILURES}" | head -20)"
      if [[ "${MCH_PHASE}" != "Running" ]]; then
        VERDICT="OLM could not install ACM - see the failed CSVs/Subscriptions above"
        DOMAIN="A'"
      fi
    else
      addRow "OLM" "ok" "no failed CSVs or Subscriptions"
    fi

    MCH_INFO=$(oc get multiclusterhub -A -o json 2>/dev/null \
      | jq -r '.items[]? | "\(.metadata.namespace)/\(.metadata.name)  \(.status.phase // "?")  \(.status.currentVersion // "?")"' | head -1)
    if [[ -z "${MCH_INFO}" ]]; then
      addRow "MultiClusterHub" "FAIL" "not found - RHACM was never installed"
      VERDICT="No MultiClusterHub on the cluster - RHACM was never installed"
      DOMAIN="A'"
    elif [[ "${MCH_PHASE}" == "Running" ]]; then
      addRow "MultiClusterHub" "ok" "${MCH_INFO}"
    else
      addRow "MultiClusterHub" "FAIL" "${MCH_INFO}"
      VERDICT="MultiClusterHub is ${MCH_PHASE:-unknown}, not Running"
      DOMAIN="A'"
    fi
  fi
  unset KUBECONFIG
fi

##############################################################################
# Report
##############################################################################
# A healthy deploy should say so plainly. "Unknown" is for when the evidence
# really was inconclusive, not for when there was simply nothing wrong.
if [[ "${DOMAIN}" == "?" && "${MCH_PHASE:-}" == "Running" ]]; then
  if (( NOT_POOL_HOST )); then
    # The hub is demonstrably fine, but nothing was checked on the pool side, so
    # this is not the same statement as a clean bill of health.
    VERDICT="MultiClusterHub is Running, but domain A was not checked - log into collective"
  else
    VERDICT="Cluster is up and MultiClusterHub is Running"
    DOMAIN="-"
  fi
fi

case "${DOMAIN}" in
  "-") BADGE="${BADGE_OK} HEALTHY ${RESET}" ;;
  "A") BADGE="${BADGE_BAD} DOMAIN A ${RESET}" ;;
  "A'") BADGE="${BADGE_BAD} DOMAIN A' ${RESET}" ;;
  *)   BADGE="${BADGE_MEH} UNKNOWN ${RESET}" ;;
esac

RULE="  ────────────────────────  ──────  ──────────────────────────────────────"
progressDone

printf "\n  %sACM WEEKLY CLUSTER%s   %s   %s\n" "${BOLD}" "${RESET}" "${CLUSTERCLAIM_NAME}" "$(date '+%Y-%m-%d %H:%M %Z')"
printf "  %s%s%s\n\n" "${DIM}" "${HUB#https://}  |  ns ${CLUSTERPOOL_TARGET_NAMESPACE}  |  pool ${CLUSTERPOOL_NAME:-?}" "${RESET}"
printf "%s\n" "${RULE}"

for row in "${ROWS[@]}"; do
  IFS="${SEP}" read -r name status detail <<< "${row}"
  case "${status}" in
    ok)   colour="${GREEN}" ;;
    FAIL) colour="${RED}" ;;
    warn) colour="${YELLOW}" ;;
    *)    colour="${DIM}" ;;
  esac
  printf "  %-24s  ${colour}%-6s${RESET}  %s\n" "${name}" "${status}" "${detail}"
done

printf "%s\n" "${RULE}"
printf "  %s  %s\n" "${BADGE}" "${VERDICT}"

if (( ${#NOTES[@]} > 0 )); then
  printf "\n  %sDETAILS%s\n" "${BOLD}" "${RESET}"
  printf "%s\n" "${NOTES[@]}"
fi

if [[ -n "${LOGBLOCK}" ]]; then
  printf "\n  %sINSTALLER LOG%s %s(last %s lines)%s\n" "${BOLD}" "${RESET}" "${DIM}" "${INSTALL_LOG_LINES}" "${RESET}"
  printf "%s\n" "${LOGBLOCK}"
fi

echo ""

# The verdict as an exit code, so a caller can act on it without grepping the
# table - wording changes, these do not. Only 0 means the deploy is worth
# handing on to a domain B hub-health check; 3 means we could not tell.
case "${DOMAIN}" in
  "-")  exit 0 ;;
  "A")  exit 1 ;;
  "A'") exit 2 ;;
  *)    exit 3 ;;
esac
