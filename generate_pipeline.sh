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

# A retried bootstrap job must not upload again. If an earlier attempt already
# uploaded the pipeline, this build holds its steps (the package step has the
# fixed key "package"), and a second upload with the same key is rejected.
# Scripts are uploaded before the pipeline, so they are in place too. Any
# lookup failure (no such step, or an API error) falls through to the upload,
# which still fails loudly on a real duplicate.
build_args=()
[ -z "${BUILDKITE_BUILD_ID:-}" ] || build_args=(--build "$BUILDKITE_BUILD_ID")
if state="$(buildkite-agent step get state --step package ${build_args[@]+"${build_args[@]}"} 2>/dev/null)"; then
  echo "generate_pipeline: this build already has the package step (state: ${state}) from an earlier attempt; not uploading again. Retry the package step itself to rerun it."
  exit 0
fi

generateArtefacts
# --no-interpolation: step commands are plain bash ($VAR, not $$VAR), and
# substituted values must reach the agent verbatim.
buildkite-agent pipeline upload --no-interpolation "$PIPELINE_FILE"
