#! /bin/bash

# Re-run the managed cluster import. Run from the ClusterPool host (collective),
# which is where the CronJob lives.
#
# Pairs with diagnose.sh exit code 4:
#
#   ./diagnose.sh; [ $? -eq 4 ] && ./retry-import.sh

set -euo pipefail

NAMESPACE=${CLUSTERPOOL_TARGET_NAMESPACE:-"console-squad"}
CRONJOB=${IMPORT_CRONJOB:-"import-weekly-managed"}

# Minutes in the name so a second attempt an hour later does not collide with
# the first - failed Jobs stick around to be read.
JOB="retry-${CRONJOB}-$(date +%m%d-%H%M)"

oc create job -n "${NAMESPACE}" --from="cronjob/${CRONJOB}" "${JOB}"

echo "oc logs -n ${NAMESPACE} -f job/${JOB}"
