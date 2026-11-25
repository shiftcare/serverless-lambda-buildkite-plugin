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
PACKAGE_REGION="${PACKAGE_REGION:-}"

check SERVICE "$SERVICE" '^[a-z0-9][a-z0-9-]*$'
if [ -n "$PACKAGE_REGION" ]; then
  check PACKAGE_REGION "$PACKAGE_REGION" '^[a-z]{2}(-[a-z]+)+-[0-9]+$'
fi
check PACKAGE_STAGE "$PACKAGE_STAGE" '^[a-z0-9][a-z0-9-]*$'
check PACKAGE_QUEUE "$PACKAGE_QUEUE" '^[a-z0-9][a-z0-9_-]*$'
check PACKAGE_AWS_ACCOUNT_ID "$PACKAGE_AWS_ACCOUNT_ID" '^[0-9]{12}$'

# Buildkite does not pass the bootstrap step's env on to uploaded steps, so
# listed variables are copied into the package step's env explicitly.
passthrough=()
passthrough_list="${PACKAGE_ENV_PASSTHROUGH:-}"
IFS=$' \t\n' read -r -d '' -a passthrough <<<"${passthrough_list//,/ }" || true
for name in ${passthrough[@]+"${passthrough[@]}"}; do
  check "PACKAGE_ENV_PASSTHROUGH entry" "$name" '^[A-Z][A-Z0-9_]*$'
  case "$name" in
    AWS_* | AMAZON_* | BUILDKITE* | BK_* | PACKAGE_* | PIPELINE_* | LD_* | DYLD_* | \
      SERVICE | SECRETS_PROVIDER_MODE | PATH | HOME | SHELL | IFS | ENV | BASH_ENV | NODE_OPTIONS | \
      TMPDIR | TMP | TEMP | NPM_CONFIG_* | GLOBIGNORE | BASHOPTS | SHELLOPTS | CDPATH)
      fail "PACKAGE_ENV_PASSTHROUGH: ${name} is reserved"
      ;;
  esac
  [ -n "${!name+x}" ] || fail "PACKAGE_ENV_PASSTHROUGH: ${name} is not set"
  case "${!name}" in
    *$'\n'* | *$'\r'*) fail "PACKAGE_ENV_PASSTHROUGH: value of ${name} contains a line break" ;;
  esac
done

addTemplate serverless/package \
  "SERVICE=${SERVICE}" \
  "PACKAGE_STAGE=${PACKAGE_STAGE}" \
  "PACKAGE_QUEUE=${PACKAGE_QUEUE}" \
  "PACKAGE_AWS_ACCOUNT_ID=${PACKAGE_AWS_ACCOUNT_ID}"

if [ -n "$PACKAGE_REGION" ]; then
  PACKAGE_REGION="$PACKAGE_REGION" yq --inplace \
    '(.steps[] | select(.key == "package") | .env.PACKAGE_REGION) = strenv(PACKAGE_REGION)' \
    "$PIPELINE_FILE"
fi

for name in ${passthrough[@]+"${passthrough[@]}"}; do
  PASSTHROUGH_NAME="$name" PASSTHROUGH_VALUE="${!name}" yq --inplace \
    '(.steps[] | select(.key == "package") | .env[strenv(PASSTHROUGH_NAME)]) = strenv(PASSTHROUGH_VALUE)' \
    "$PIPELINE_FILE"
done

# Extension point: publish (follow-up PR)

# Extension point: deploy (follow-up PR)
