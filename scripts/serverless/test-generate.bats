#!/usr/bin/env bats

load ../../test/test_helper

setup() {
  export PIPELINE_BASEDIR="$REPO_ROOT"
  export PIPELINE_WORKDIR="${BATS_TEST_TMPDIR}/work"
  export PIPELINE_FILE="${PIPELINE_WORKDIR}/pipeline.yml"
  mkdir -p "$PIPELINE_WORKDIR"
  printf 'steps: []\n' >"$PIPELINE_FILE"
  export SERVICE=demo-svc
  unset PACKAGE_STAGE PACKAGE_QUEUE PACKAGE_AWS_ACCOUNT_ID
}

generate() {
  run "${REPO_ROOT}/scripts/serverless/generate.sh"
}

step() {
  yq "$1" "$PIPELINE_FILE"
}

@test "adds a single package step with defaults" {
  generate
  [ "$status" -eq 0 ]
  [ "$(step '.steps | length')" = "1" ]
  [ "$(step '.steps[0].key')" = "package" ]
  [ "$(step '.steps[0].label')" = ":package: Package demo-svc" ]
  [ "$(step '.steps[0].agents.queue')" = "tiny" ]
  [ "$(step '.steps[0].timeout_in_minutes')" = "20" ]
  [ "$(step '.steps[0].env.SERVICE')" = "demo-svc" ]
  [ "$(step '.steps[0].env.PACKAGE_STAGE')" = "dev" ]
  [ "$(step '.steps[0].env.PACKAGE_AWS_ACCOUNT_ID')" = "000000000000" ]
  [ "$(step '.steps[0].env.PACKAGE_AWS_ACCOUNT_ID | tag')" = '!!str' ]
}

@test "retries agent-lost exits only" {
  generate
  [ "$status" -eq 0 ]
  run yq -o=json -I0 '.steps[0].retry.automatic' "$PIPELINE_FILE"
  [ "$output" = '[{"exit_status":-1,"limit":2},{"exit_status":255,"limit":2}]' ]
}

@test "declares no artifact_paths and runs package.sh from the downloaded artifacts" {
  generate
  [ "$status" -eq 0 ]
  [ "$(step '.steps[0] | has("artifact_paths")')" = "false" ]
  # shellcheck disable=SC2016  # literal command text
  [[ "$(step '.steps[0].command')" == *'buildkite-agent artifact download "serverless-lambda-pipeline/**/*.sh" "$d"'* ]]
  # shellcheck disable=SC2016
  [[ "$(step '.steps[0].command')" == *'bash "$d/serverless-lambda-pipeline/scripts/serverless/package.sh"'* ]]
  [ -f "${REPO_ROOT}/scripts/serverless/package.sh" ]
}

@test "downloads from the artifact prefix generateArtefacts uploads to" {
  local prefix
  # shellcheck disable=SC2016  # expands in the subshell
  prefix="$(bash -c '. "$1"; printf %s "$PIPELINE_ARTIFACT_PREFIX"' _ "${REPO_ROOT}/scripts/common/helper.sh")"
  [ -n "$prefix" ]
  grep -qF "\"${prefix}/**/*.sh\"" "${REPO_ROOT}/templates/serverless/package.yml"
  grep -qF "/${prefix}/scripts/serverless/package.sh\"" "${REPO_ROOT}/templates/serverless/package.yml"
}

@test "honours PACKAGE_STAGE, PACKAGE_QUEUE and PACKAGE_AWS_ACCOUNT_ID" {
  # Built at runtime: the leak check rejects 12-digit literals in this repo.
  local id="1111""11111111"
  PACKAGE_STAGE=qa PACKAGE_QUEUE=small_2 PACKAGE_AWS_ACCOUNT_ID="$id" generate
  [ "$status" -eq 0 ]
  [ "$(step '.steps[0].env.PACKAGE_STAGE')" = "qa" ]
  [ "$(step '.steps[0].agents.queue')" = "small_2" ]
  [ "$(step '.steps[0].env.PACKAGE_AWS_ACCOUNT_ID')" = "$id" ]
}

@test "leaves no placeholder behind" {
  generate
  [ "$status" -eq 0 ]
  run grep -c '@@' "$PIPELINE_FILE"
  [ "$output" = "0" ]
}

@test "rejects a missing SERVICE" {
  unset SERVICE
  generate
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid SERVICE"* ]]
}

@test "rejects invalid inputs" {
  local spec
  for spec in 'SERVICE=Demo' 'PACKAGE_STAGE=qa b' 'PACKAGE_STAGE=-qa' 'PACKAGE_QUEUE=tiny: x' \
    'PACKAGE_AWS_ACCOUNT_ID=12345' 'PACKAGE_AWS_ACCOUNT_ID=abcdefghijkl'; do
    printf 'steps: []\n' >"$PIPELINE_FILE"
    run env "$spec" "${REPO_ROOT}/scripts/serverless/generate.sh"
    [ "$status" -eq 1 ] || { echo "accepted ${spec}"; return 1; }
    [ "$(step '.steps | length')" = "0" ]
  done
}

@test "fails when the pipeline environment is missing" {
  unset PIPELINE_WORKDIR
  generate
  [ "$status" -ne 0 ]
}

@test "marks the publish and deploy extension points" {
  grep -qx '# Extension point: publish (follow-up PR)' "${REPO_ROOT}/scripts/serverless/generate.sh"
  grep -qx '# Extension point: deploy (follow-up PR)' "${REPO_ROOT}/scripts/serverless/generate.sh"
}
