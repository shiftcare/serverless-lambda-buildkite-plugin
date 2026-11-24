#!/usr/bin/env bats

load ../../test/test_helper

setup() {
  # shellcheck source=SCRIPTDIR/helper.sh
  . "${REPO_ROOT}/scripts/common/helper.sh"
  setup_stubs
  stub_buildkite_agent

  export PIPELINE_BASEDIR="$REPO_ROOT"
  export PIPELINE_WORKDIR="${BATS_TEST_TMPDIR}/work"
  export PIPELINE_FILE="${PIPELINE_WORKDIR}/pipeline.yml"
  mkdir -p "$PIPELINE_WORKDIR"
  printf 'steps: []\n' >"$PIPELINE_FILE"

  TEMPLATE="${BATS_TEST_TMPDIR}/substitution.yml"
  cp "${RESOURCES}/substitution.yml" "$TEMPLATE"
}

paths_of() {
  yq -o=json -I0 '[.. | path | join(".")]' "$1"
}

# --- mergeYaml -------------------------------------------------------------

@test "mergeYaml appends steps in call order" {
  mergeYaml "$PIPELINE_FILE" "${RESOURCES}/nested-1.yml"
  mergeYaml "$PIPELINE_FILE" "${REPO_ROOT}/templates/common/wait.yml"
  mergeYaml "$PIPELINE_FILE" "${RESOURCES}/nested-2.yml"

  run yq -o=json -I0 '[.steps[] | (.label // .)]' "$PIPELINE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = '["first step","second step","wait","third step","fourth step"]' ]
}

@test "mergeYaml without arguments fails" {
  run mergeYaml "$PIPELINE_FILE"
  [ "$status" -eq 1 ]
}

# --- replaceValuesInTemplate ----------------------------------------------

@test "replaceValuesInTemplate substitutes every occurrence" {
  run replaceValuesInTemplate "$TEMPLATE" "VALUE=prod" "QUEUE=tiny"
  [ "$status" -eq 0 ]
  [ "$(yq '.steps[0].label' "$TEMPLATE")" = "Deploy prod" ]
  [ "$(yq '.steps[0].plain' "$TEMPLATE")" = "prefix prod suffix" ]
  [ "$(yq '.steps[0].agents.queue' "$TEMPLATE")" = "tiny" ]
  [ "$(yq '.steps[0].env.VALUE' "$TEMPLATE")" = "prod" ]
  [ "$(yq '.steps[0].command' "$TEMPLATE")" = 'echo "prod"' ]
}

@test "replaceValuesInTemplate keeps hostile values verbatim and the structure unchanged" {
  local before value
  before="$(paths_of "$TEMPLATE")"
  # shellcheck disable=SC1003,SC2016  # literal hostile values
  for value in 'foo: bar' '"' "'" '\' '&anchor' '*alias' '%TAG' '/' '$(id)' '${X}' \
    '- step' '{a}' '[b]' '-leading' '# comment' '|' '>' '!!int' '123' 'true' ''; do
    cp "${RESOURCES}/substitution.yml" "$TEMPLATE"
    run replaceValuesInTemplate "$TEMPLATE" "VALUE=${value}" "QUEUE=${value}"
    [ "$status" -eq 0 ] || { echo "failed for [${value}]: ${output}"; return 1; }

    [ "$(VAL="$value" yq '.steps[0].env.VALUE == strenv(VAL)' "$TEMPLATE")" = "true" ] ||
      { echo "env value changed for [${value}]"; return 1; }
    [ "$(VAL="$value" yq '.steps[0].agents.queue == strenv(VAL)' "$TEMPLATE")" = "true" ]
    [ "$(VAL="$value" yq '.steps[0].label == "Deploy " + strenv(VAL)' "$TEMPLATE")" = "true" ]
    [ "$(VAL="$value" yq '.steps[0].plain == "prefix " + strenv(VAL) + " suffix"' "$TEMPLATE")" = "true" ]
    [ "$(yq '.steps[0].env.VALUE | tag' "$TEMPLATE")" = '!!str' ]
    [ "$(paths_of "$TEMPLATE")" = "$before" ] ||
      { echo "structure changed for [${value}]"; return 1; }
  done
}

@test "replaceValuesInTemplate rejects a lowercase key" {
  run replaceValuesInTemplate "$TEMPLATE" "value=x" "QUEUE=tiny"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid substitution key"* ]]
}

@test "replaceValuesInTemplate rejects an argument without '='" {
  run replaceValuesInTemplate "$TEMPLATE" "VALUE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not KEY=VALUE"* ]]
}

@test "replaceValuesInTemplate rejects a value with a newline" {
  run replaceValuesInTemplate "$TEMPLATE" "VALUE=a
b" "QUEUE=tiny"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line break"* ]]
}

@test "replaceValuesInTemplate rejects a value with a carriage return" {
  run replaceValuesInTemplate "$TEMPLATE" "VALUE=a$(printf '\r')b" "QUEUE=tiny"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line break"* ]]
}

@test "replaceValuesInTemplate rejects a value carrying a placeholder" {
  run replaceValuesInTemplate "$TEMPLATE" "VALUE=@@QUEUE@@" "QUEUE=tiny"
  [ "$status" -eq 1 ]
}

@test "replaceValuesInTemplate fails on a leftover placeholder" {
  run replaceValuesInTemplate "$TEMPLATE" "VALUE=prod"
  [ "$status" -eq 1 ]
  [[ "$output" == *"@@QUEUE@@"* ]]
}

@test "replaceValuesInTemplate fails on a missing file" {
  run replaceValuesInTemplate "${BATS_TEST_TMPDIR}/nope.yml" "VALUE=x"
  [ "$status" -eq 1 ]
}

# --- addTemplate ------------------------------------------------------------

@test "addTemplate without a name fails" {
  run addTemplate
  [ "$status" -eq 1 ]
}

@test "addTemplate rejects path traversal" {
  run addTemplate "../test/resources/nested-1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid template name"* ]]
}

@test "addTemplate fails on an unknown template" {
  run addTemplate common/does-not-exist
  [ "$status" -eq 1 ]
  [[ "$output" == *"template not found"* ]]
}

@test "addTemplate fails when PIPELINE_WORKDIR is unset" {
  unset PIPELINE_WORKDIR
  run addTemplate common/wait
  [ "$status" -eq 1 ]
  [[ "$output" == *"PIPELINE_WORKDIR is not set"* ]]
}

@test "addTemplate adds a wait step" {
  run addTemplate common/wait
  [ "$status" -eq 0 ]
  [ "$(yq '.steps | length' "$PIPELINE_FILE")" = "1" ]
  [ "$(yq '.steps[0]' "$PIPELINE_FILE")" = "wait" ]
}

@test "addTemplate adds a block step with its label" {
  run addTemplate common/block "BLOCK_LABEL=:rocket: Release"
  [ "$status" -eq 0 ]
  [ "$(yq '.steps[0].block' "$PIPELINE_FILE")" = ":rocket: Release" ]
}

@test "addTemplate fails on block without its label and leaves the pipeline untouched" {
  run addTemplate common/block
  [ "$status" -eq 1 ]
  [ "$(yq '.steps | length' "$PIPELINE_FILE")" = "0" ]
}

@test "addTemplate keeps call order and leaves the template sources unchanged" {
  local before
  before="$(cat "${REPO_ROOT}/templates/common/block.yml")"
  addTemplate common/wait
  addTemplate common/block "BLOCK_LABEL=Go"
  addTemplate common/wait
  run yq -o=json -I0 '[.steps[] | (.block // .)]' "$PIPELINE_FILE"
  [ "$output" = '["wait","Go","wait"]' ]
  [ "$(cat "${REPO_ROOT}/templates/common/block.yml")" = "$before" ]
}

@test "addTemplate stages copies under PIPELINE_WORKDIR, not a fixed /tmp name" {
  addTemplate common/wait
  run find "$PIPELINE_WORKDIR" -name template.yml
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run grep -rn --include='*.sh' --exclude-dir=.git '/tmp/' "$REPO_ROOT"
  [ "$status" -eq 1 ]
}

# --- generateArtefacts -----------------------------------------------------

@test "generateArtefacts uploads the scripts from the workdir, not the cwd" {
  local cwd="${BATS_TEST_TMPDIR}/checkout"
  mkdir -p "$cwd"
  cd "$cwd"
  run generateArtefacts
  [ "$status" -eq 0 ]

  [ -f "${PIPELINE_WORKDIR}/serverless-lambda-pipeline/scripts/common/helper.sh" ]
  [ "$(printf '%s\tartifact upload serverless-lambda-pipeline/**/*.sh' "$PIPELINE_WORKDIR")" = "$(cat "${STUB_LOG}/buildkite-agent.log")" ]
  [ -z "$(ls -A "$cwd")" ]
}

@test "generateArtefacts propagates an upload failure" {
  export BUILDKITE_AGENT_STUB_EXIT=1
  run generateArtefacts
  [ "$status" -ne 0 ]
}

@test "generateArtefacts fails when PIPELINE_WORKDIR is missing" {
  export PIPELINE_WORKDIR="${BATS_TEST_TMPDIR}/missing"
  run generateArtefacts
  [ "$status" -eq 1 ]
}
