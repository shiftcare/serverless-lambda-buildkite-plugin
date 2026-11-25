#!/usr/bin/env bash
# Builds the serverless pipeline for the calling service repo and uploads it
# to Buildkite. PIPELINE_DRY_RUN=1 prints the YAML and uploads nothing.
set -euo pipefail

PIPELINE_BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_BASEDIR

# shellcheck source=SCRIPTDIR/scripts/common/helper.sh
. "${PIPELINE_BASEDIR}/scripts/common/helper.sh"

service_re='^[a-z0-9][a-z0-9-]*$'
if ! [[ "${SERVICE:-}" =~ $service_re ]]; then
  echo "generate_pipeline: SERVICE must be set and match ${service_re} (got '${SERVICE:-}')" >&2
  exit 1
fi
export SERVICE

PIPELINE_WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$PIPELINE_WORKDIR"' EXIT
export PIPELINE_WORKDIR
export PIPELINE_FILE="${PIPELINE_WORKDIR}/pipeline.yml"
printf 'steps: []\n' >"$PIPELINE_FILE"

"${PIPELINE_BASEDIR}/scripts/serverless/generate.sh"

if [ "${PIPELINE_DRY_RUN:-}" = "1" ]; then
  cat "$PIPELINE_FILE"
  exit 0
fi

# Scripts are uploaded on every attempt, retries included: by default
# `buildkite-agent artifact download` searches only the latest attempt of a
# retried job, so later steps would not find an earlier attempt's scripts.
generateArtefacts

# A retried bootstrap job must not upload the pipeline again. If an earlier
# attempt already did, this build holds its steps (the package step has the
# fixed key "package"), and a second upload with the same key is rejected.
# Only a retry (BUILDKITE_RETRY_COUNT > 0) checks: a first attempt that meets
# an existing package step (a second bootstrap in one build) must still fail
# on the duplicate key. A failed lookup also falls through to the upload.
if [ "${BUILDKITE_RETRY_COUNT:-0}" != 0 ] &&
  state="$(buildkite-agent step get state --step package --build "${BUILDKITE_BUILD_ID:-}")"; then
  echo "generate_pipeline: retry ${BUILDKITE_RETRY_COUNT}: this build already has the package step (state: ${state}) from an earlier attempt; scripts re-uploaded, pipeline not uploaded again. Retry the package step itself to rerun it."
  exit 0
fi

# --no-interpolation: step commands are plain bash ($VAR, not $$VAR), and
# substituted values must reach the agent verbatim.
buildkite-agent pipeline upload --no-interpolation "$PIPELINE_FILE"
