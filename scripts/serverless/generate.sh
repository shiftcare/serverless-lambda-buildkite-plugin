#!/usr/bin/env bash
# Adds the serverless steps to PIPELINE_FILE. Run by generate_pipeline.sh,
# which exports PIPELINE_BASEDIR, PIPELINE_WORKDIR, PIPELINE_FILE and SERVICE.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../common/helper.sh
. "${here}/../common/helper.sh"

fail() {
  echo "generate: $*" >&2
  exit 1
}

check() {
  local name="$1" value="$2" re="$3"
  [[ "$value" =~ $re ]] || fail "invalid ${name}: '${value}' (must match ${re})"
}

SERVICE="${SERVICE:-}"
PACKAGE_STAGE="${PACKAGE_STAGE:-dev}"
PACKAGE_QUEUE="${PACKAGE_QUEUE:-tiny}"
PACKAGE_AWS_ACCOUNT_ID="${PACKAGE_AWS_ACCOUNT_ID:-000000000000}"

check SERVICE "$SERVICE" '^[a-z0-9][a-z0-9-]*$'
check PACKAGE_STAGE "$PACKAGE_STAGE" '^[a-z0-9][a-z0-9-]*$'
check PACKAGE_QUEUE "$PACKAGE_QUEUE" '^[a-z0-9][a-z0-9_-]*$'
check PACKAGE_AWS_ACCOUNT_ID "$PACKAGE_AWS_ACCOUNT_ID" '^[0-9]{12}$'

addTemplate serverless/package \
  "SERVICE=${SERVICE}" \
  "PACKAGE_STAGE=${PACKAGE_STAGE}" \
  "PACKAGE_QUEUE=${PACKAGE_QUEUE}" \
  "PACKAGE_AWS_ACCOUNT_ID=${PACKAGE_AWS_ACCOUNT_ID}"

# Extension point: publish (follow-up PR)

# Extension point: deploy (follow-up PR)
