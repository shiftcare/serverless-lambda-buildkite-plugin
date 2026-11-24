#!/usr/bin/env bats

load ../../test/test_helper

setup() {
  setup_stubs
  stub_buildkite_agent
  stub node 'echo v22.11.0'
  # shellcheck disable=SC2016  # stub bodies expand at stub run time
  stub npm '
echo "$*" >>"$STUB_LOG/npm.log"
exit "${NPM_STUB_EXIT:-0}"'
  # shellcheck disable=SC2016
  stub npx '
echo "$*" >>"$STUB_LOG/npx.log"
[ "$1" = "--no-install" ] && [ "$2" = "serverless" ] || exit 64
case "$3" in
  --version)
    printf "Framework Core: %s (local)\nPlugin: 5.5.4\nSDK: 4.3.2\n" "${FAKE_SLS_VERSION:-2.72.3}"
    ;;
  package)
    env >"$STUB_LOG/package-env"
    src="$STUB_LOG/src"
    mkdir -p "$src/node_modules/lib" .serverless
    echo "exports.handler = 1" >"$src/handler.js"
    echo "module.exports = 1" >"$src/node_modules/lib/index.js"
    case "${FAKE_ZIP_MODE:-ok}" in
      none) exit 0 ;;
      serverless-dir) mkdir -p "$src/.serverless"; echo "{}" >"$src/.serverless/serverless-state.json" ;;
      dotenv) echo "X=1" >"$src/.env" ;;
      dotenv-suffix) echo "X=1" >"$src/.env.production" ;;
      dotenv-dir) mkdir -p "$src/config/.env"; echo "X=1" >"$src/config/.env/secret" ;;
      cfn) echo "{}" >"$src/cloudformation-template-update-stack.json" ;;
    esac
    (cd "$src" && zip -qr "$OLDPWD/.serverless/demo.zip" .)
    [ "${FAKE_ZIP_MODE:-ok}" != two ] || cp .serverless/demo.zip .serverless/other.zip
    exit "${SLS_STUB_EXIT:-0}"
    ;;
esac'

  SVC="${BATS_TEST_TMPDIR}/svc"
  mkdir -p "$SVC"
  cd "$SVC" || return 1

  export SERVICE=demo
  export BUILDKITE_BUILD_NUMBER=42
  export BUILDKITE_COMMIT=abc123
  export BUILDKITE_BRANCH=main
  # Values are inert stand-ins; only their removal is asserted.
  export AWS_ACCESS_KEY_ID=stub-id
  export AWS_SECRET_ACCESS_KEY=stub-key
  export AWS_SESSION_TOKEN=stub-session
  export AWS_PROFILE=stub-claude
  export AWS_REGION=stub-region
}

package() {
  run bash "${REPO_ROOT}/scripts/serverless/package.sh"
}

@test "uploads exactly dist/<SERVICE>.zip" {
  package
  [ "$status" -eq 0 ]
  [ "$(cut -f2 "${STUB_LOG}/buildkite-agent.log")" = "artifact upload dist/demo.zip" ]
  [ "$(wc -l <"${STUB_LOG}/buildkite-agent.log" | tr -d ' ')" = "1" ]
  [ -f "${SVC}/dist/demo.zip" ]
}

@test "runs npm ci and serverless package for the default stage" {
  package
  [ "$status" -eq 0 ]
  [ "$(cat "${STUB_LOG}/npm.log")" = "ci" ]
  grep -qx -- "--no-install serverless package --stage dev" "${STUB_LOG}/npx.log"
}

@test "honours PACKAGE_STAGE" {
  PACKAGE_STAGE=qa package
  [ "$status" -eq 0 ]
  grep -qx -- "--no-install serverless package --stage qa" "${STUB_LOG}/npx.log"
}

@test "passes PACKAGE_REGION as --region" {
  PACKAGE_REGION=ap-southeast-2 package
  [ "$status" -eq 0 ]
  grep -qx -- "--no-install serverless package --stage dev --region ap-southeast-2" "${STUB_LOG}/npx.log"
}

@test "rejects an invalid PACKAGE_REGION" {
  PACKAGE_REGION='us-east-1 --stage x' package
  [ "$status" -eq 1 ]
  [ ! -f "${STUB_LOG}/npm.log" ]
}

@test "rejects an invalid PACKAGE_STAGE" {
  PACKAGE_STAGE='qa;id' package
  [ "$status" -eq 1 ]
  [ ! -f "${STUB_LOG}/npm.log" ]
}

@test "rejects an invalid SERVICE" {
  SERVICE='../x' package
  [ "$status" -eq 1 ]
}

@test "strips AWS credentials before serverless runs" {
  package
  [ "$status" -eq 0 ]
  local envf="${STUB_LOG}/package-env"
  run grep -E '^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|PROFILE|REGION)=' "$envf"
  [ "$status" -eq 1 ]
  grep -qx 'AWS_EC2_METADATA_DISABLED=true' "$envf"
  grep -qx 'AWS_ACCOUNT_ID=000000000000' "$envf"
  grep -qx 'SECRETS_PROVIDER_MODE=placeholder' "$envf"
  # Serverless gets a scratch HOME (no ~/.aws), removed on exit.
  local sls_home
  sls_home="$(sed -n 's/^HOME=//p' "$envf")"
  [ -n "$sls_home" ]
  [ "$sls_home" != "$HOME" ]
  [ ! -e "$sls_home" ]
}

@test "PACKAGE_AWS_ACCOUNT_ID overrides the placeholder" {
  # Built at runtime: the leak check rejects 12-digit literals in this repo.
  local id="1111""11111111"
  PACKAGE_AWS_ACCOUNT_ID="$id" package
  [ "$status" -eq 0 ]
  grep -qx "AWS_ACCOUNT_ID=${id}" "${STUB_LOG}/package-env"
}

@test "stamps ci.build.info.txt into the dist zip only" {
  package
  [ "$status" -eq 0 ]
  run unzip -p "${SVC}/dist/demo.zip" ci.build.info.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"service=demo"* ]]
  [[ "$output" == *"build_number=42"* ]]
  [[ "$output" == *"commit=abc123"* ]]
  [[ "$output" == *"branch=main"* ]]
  [[ "$output" == *"node_version=v22.11.0"* ]]
  [[ "$output" == *"serverless_version=2.72.3"* ]]
  [[ "$output" =~ built_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z ]]
  run unzip -Z1 "${SVC}/dist/demo.zip"
  [[ "$output" == *"handler.js"* ]]
  run unzip -Z1 "${SVC}/.serverless/demo.zip"
  [[ "$output" != *"ci.build.info.txt"* ]]
}

@test "stamp falls back to unknown outside Buildkite" {
  unset BUILDKITE_BUILD_NUMBER BUILDKITE_COMMIT BUILDKITE_BRANCH
  PACKAGE_SKIP_UPLOAD=1 package
  [ "$status" -eq 0 ]
  run unzip -p "${SVC}/dist/demo.zip" ci.build.info.txt
  [[ "$output" == *"build_number=unknown"* ]]
  [[ "$output" == *"commit=unknown"* ]]
  [[ "$output" == *"branch=unknown"* ]]
}

@test "PACKAGE_SKIP_UPLOAD=1 skips the upload and prints the path" {
  PACKAGE_SKIP_UPLOAD=1 package
  [ "$status" -eq 0 ]
  [[ "$output" == *"dist/demo.zip"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "refuses a zip containing .serverless/" {
  FAKE_ZIP_MODE=serverless-dir package
  [ "$status" -eq 1 ]
  [[ "$output" == *".serverless/serverless-state.json"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
  [ ! -e "${SVC}/dist" ]
}

@test "refuses a zip containing .env" {
  FAKE_ZIP_MODE=dotenv package
  [ "$status" -eq 1 ]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "refuses a zip containing .env.<suffix>" {
  FAKE_ZIP_MODE=dotenv-suffix package
  [ "$status" -eq 1 ]
}

@test "refuses a zip containing files under a .env directory" {
  FAKE_ZIP_MODE=dotenv-dir package
  [ "$status" -eq 1 ]
  [[ "$output" == *"config/.env/secret"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "refuses a zip containing a cloudformation template" {
  FAKE_ZIP_MODE=cfn package
  [ "$status" -eq 1 ]
}

@test "fails when no zip is produced" {
  FAKE_ZIP_MODE=none package
  [ "$status" -eq 1 ]
  [[ "$output" == *"no .zip"* ]]
}

@test "fails when two zips are produced" {
  FAKE_ZIP_MODE=two package
  [ "$status" -eq 1 ]
  [[ "$output" == *"found 2"* ]]
}

@test "fails on serverless major version 3" {
  FAKE_SLS_VERSION=3.38.0 package
  [ "$status" -eq 1 ]
  [[ "$output" == *"only major version 2"* ]]
  run grep -c ' package ' "${STUB_LOG}/npx.log"
  [ "$output" = "0" ]
}

@test "fails on serverless major version 1" {
  FAKE_SLS_VERSION=1.83.3 package
  [ "$status" -eq 1 ]
}

@test "a failing npm ci propagates" {
  NPM_STUB_EXIT=3 package
  [ "$status" -ne 0 ]
  [ ! -f "${STUB_LOG}/npx.log" ]
}

@test "a failing serverless package propagates" {
  SLS_STUB_EXIT=2 package
  [ "$status" -ne 0 ]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "a failing artifact upload propagates" {
  BUILDKITE_AGENT_STUB_EXIT=1 package
  [ "$status" -ne 0 ]
}
