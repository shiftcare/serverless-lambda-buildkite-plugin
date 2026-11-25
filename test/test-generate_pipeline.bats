#!/usr/bin/env bats

load test_helper

setup() {
  setup_stubs
  stub_buildkite_agent
  export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "$TMPDIR"
  CWD="${BATS_TEST_TMPDIR}/checkout"
  mkdir -p "$CWD"
  cd "$CWD" || return 1
  export SERVICE=demo-svc
  unset PIPELINE_DRY_RUN
}

generate_pipeline() {
  run "${REPO_ROOT}/generate_pipeline.sh"
}

@test "dry run prints a valid pipeline and calls no buildkite-agent" {
  PIPELINE_DRY_RUN=1 generate_pipeline
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | yq '.steps[0].key')" = "package" ]
  [ "$(printf '%s\n' "$output" | yq '.steps[0].agents.queue')" = "tiny" ]
  [ "$(printf '%s\n' "$output" | yq '.steps[0].env.SERVICE')" = "demo-svc" ]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "checks for an earlier upload, then uploads the scripts and the pipeline without interpolation" {
  BUILDKITE_BUILD_ID=build-123 generate_pipeline
  [ "$status" -eq 0 ]
  [ "$(wc -l <"${STUB_LOG}/buildkite-agent.log" | tr -d ' ')" = "3" ]
  run cut -f2 "${STUB_LOG}/buildkite-agent.log"
  [ "${lines[0]}" = "step get state --step package --build build-123" ]
  [ "${lines[1]}" = "artifact upload serverless-lambda-pipeline/**/*.sh" ]
  [[ "${lines[2]}" == "pipeline upload --no-interpolation ${TMPDIR}/"*"/pipeline.yml" ]]
  [ "$(yq '.steps[0].key' "${STUB_LOG}/captured/pipeline.yml")" = "package" ]
}

@test "a retried bootstrap uploads nothing when the package step already exists" {
  local state
  for state in waiting running passed failed; do
    rm -f "${STUB_LOG}/buildkite-agent.log"
    STUB_STEP_STATE="$state" generate_pipeline
    [ "$status" -eq 0 ] || { echo "${state}: ${output}"; return 1; }
    [[ "$output" == *"already has the package step (state: ${state})"* ]]
    run grep -c 'upload' "${STUB_LOG}/buildkite-agent.log"
    [ "$output" = "0" ]
  done
}

@test "works in a mktemp dir under TMPDIR and removes it on exit" {
  generate_pipeline
  [ "$status" -eq 0 ]
  local workdir
  workdir="$(grep -m 1 'artifact upload' "${STUB_LOG}/buildkite-agent.log" | cut -f1)"
  [[ "$workdir" == "${TMPDIR}/"* ]]
  [ ! -e "$workdir" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "writes nothing into the calling checkout" {
  generate_pipeline
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$CWD")" ]
}

@test "requires SERVICE" {
  unset SERVICE
  generate_pipeline
  [ "$status" -eq 1 ]
  [[ "$output" == *"SERVICE must be set"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "rejects an invalid SERVICE" {
  SERVICE='demo; id' generate_pipeline
  [ "$status" -eq 1 ]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "a generator failure uploads nothing" {
  PACKAGE_QUEUE='bad queue' generate_pipeline
  [ "$status" -eq 1 ]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "a buildkite-agent failure propagates" {
  BUILDKITE_AGENT_STUB_EXIT=1 generate_pipeline
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "is committed executable" {
  [ -x "${REPO_ROOT}/generate_pipeline.sh" ]
  [ -x "${REPO_ROOT}/scripts/serverless/generate.sh" ]
}
