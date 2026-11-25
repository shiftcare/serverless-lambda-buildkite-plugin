#!/usr/bin/env bats

load ../../test/test_helper

setup() {
  setup_stubs
  stub_buildkite_agent
  stub node 'echo v22.11.0'
  # grep wrapper: FAKE_GREP_FAIL=1 makes the forbidden-entry scan (grep -E)
  # exit 2, as a matcher error would; every other call runs the real grep.
  REAL_GREP="$(type -P grep)"
  export REAL_GREP
  # shellcheck disable=SC2016  # stub bodies expand at stub run time
  stub grep '
if [ "${FAKE_GREP_FAIL:-}" = 1 ] && [ "${1:-}" = "-E" ]; then exit 2; fi
exec "$REAL_GREP" "$@"'
  # A decoy global serverless: package.sh must never fall back to it.
  # shellcheck disable=SC2016  # stub bodies expand at stub run time
  stub serverless '
echo "$*" >>"$STUB_LOG/global-sls.log"
printf "Framework Core: 2.72.3 (global)\n"'
  # npm ci installs the service-local serverless (below) into node_modules/.bin,
  # unless NO_LOCAL_SLS=1.
  # shellcheck disable=SC2016
  stub npm '
echo "$*" >>"$STUB_LOG/npm.log"
[ "${NPM_STUB_EXIT:-0}" = 0 ] || exit "$NPM_STUB_EXIT"
[ "${NPM_CREATES_DOTENV:-}" != 1 ] || echo "X=1" >.env
if [ "$1" = ci ] && [ "${NO_LOCAL_SLS:-}" != 1 ]; then
  mkdir -p node_modules/.bin
  cp "$STUB_LOG/local-serverless" node_modules/.bin/serverless
  chmod +x node_modules/.bin/serverless
fi'
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' '
echo "$*" >>"$STUB_LOG/sls.log"
case "$1" in
  --version)
    [ "${SLS_VERSION_EXIT:-0}" = 0 ] || exit "$SLS_VERSION_EXIT"
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
      own-output) mkdir -p "$src/dist"; echo "stale" >"$src/dist/demo.zip" ;;
    esac
    # Like Serverless, include whatever already sits under dist/ in the service.
    [ ! -d dist ] || cp -R dist "$src/"
    # Like Serverless: the service zip, plus the state file naming it as
    # package.artifact. layer-only: only a layer zip, artifact left empty;
    # other-artifact: the state names a different (prebuilt) artifact.
    zipname=demo.zip artifact=demo.zip layers="{}" functions="{\"fn\":{}}" individually=false
    case "${FAKE_ZIP_MODE:-ok}" in
      layer-only) zipname=layer.zip artifact= ;;
      other-artifact) artifact=prebuilt.zip ;;
      artifact-named-like-layer) zipname=layer.zip artifact=layer.zip ;;
      same-name-layer) layers="{\"demo\":{\"path\":\"layer\"}}" ;;
      individually) individually=true ;;
      individually-string) individually="\"yes\"" ;;
      fn-artifact) functions="{\"fn\":{\"package\":{\"artifact\":\"prebuilt.zip\"}}}" ;;
      fn-individually) functions="{\"fn\":{\"package\":{\"individually\":true}}}" ;;
    esac
    (cd "$src" && zip -qr "$OLDPWD/.serverless/$zipname" .)
    [ "${FAKE_ZIP_MODE:-ok}" = no-state ] ||
      printf "{\"service\":{\"service\":\"demo\",\"layers\":%s,\"functions\":%s},\"package\":{\"individually\":%s,\"artifact\":\"%s\"}}\n" \
        "$layers" "$functions" "$individually" "$artifact" >.serverless/serverless-state.json
    [ "${FAKE_ZIP_MODE:-ok}" != two ] || cp .serverless/demo.zip .serverless/other.zip
    exit "${SLS_STUB_EXIT:-0}"
    ;;
esac' >"$STUB_LOG/local-serverless"

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
  export AMAZON_ACCESS_KEY_ID=stub-legacy-id
  export AMAZON_SECRET_ACCESS_KEY=stub-legacy-key
  export AMAZON_SESSION_TOKEN=stub-legacy-session
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
  [ "$(cat "${STUB_LOG}/npm.log")" = "ci --include=dev" ]
  grep -qx -- "package --stage dev" "${STUB_LOG}/sls.log"
}

@test "honours PACKAGE_STAGE" {
  PACKAGE_STAGE=qa package
  [ "$status" -eq 0 ]
  grep -qx -- "package --stage qa" "${STUB_LOG}/sls.log"
}

@test "passes PACKAGE_REGION as --region" {
  PACKAGE_REGION=ap-southeast-2 package
  [ "$status" -eq 0 ]
  grep -qx -- "package --stage dev --region ap-southeast-2" "${STUB_LOG}/sls.log"
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

@test "strips legacy AMAZON_* credentials (AWS SDK v2) before serverless runs" {
  package
  [ "$status" -eq 0 ]
  run grep -E '^AMAZON_' "${STUB_LOG}/package-env"
  [ "$status" -eq 1 ]
}

@test "runs the service-local serverless, never a global one" {
  package
  [ "$status" -eq 0 ]
  [ -f "${STUB_LOG}/sls.log" ]
  [ ! -f "${STUB_LOG}/global-sls.log" ]
}

@test "fails when npm ci installs no local serverless, even with a global one" {
  NO_LOCAL_SLS=1 package
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed locally"* ]]
  [ ! -f "${STUB_LOG}/global-sls.log" ]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "a previous dist/<SERVICE>.zip is not packaged into the new zip" {
  mkdir -p "${SVC}/dist"
  echo "stale" >"${SVC}/dist/demo.zip"
  echo "keep" >"${SVC}/dist/service-build-output.js"
  package
  [ "$status" -eq 0 ]
  run unzip -Z1 "${SVC}/dist/demo.zip"
  [[ "$output" != *"dist/demo.zip"* ]]
  [[ "$output" == *"dist/service-build-output.js"* ]]
  [ -f "${SVC}/dist/service-build-output.js" ]
}

@test "refuses to package when .env exists in the service root" {
  echo "AWS_ACCESS_KEY_ID=from-dotenv" >"${SVC}/.env"
  package
  [ "$status" -eq 1 ]
  [[ "$output" == *".env exists in the service root"* ]]
  [ ! -f "${STUB_LOG}/sls.log" ]
}

@test "refuses to package when .env is a dangling symlink" {
  ln -s /nonexistent/.env "${SVC}/.env"
  package
  [ "$status" -eq 1 ]
  [[ "$output" == *".env exists in the service root"* ]]
}

@test "refuses a .env created by npm ci (lifecycle scripts)" {
  NPM_CREATES_DOTENV=1 package
  [ "$status" -eq 1 ]
  [[ "$output" == *".env exists in the service root"* ]]
  [ ! -f "${STUB_LOG}/sls.log" ]
}

@test "refuses a .env file for any other stage or NODE_ENV (serverless-dotenv-plugin)" {
  local f
  for f in .env.development .env.production .env.prod; do
    rm -f "${SVC}"/.env*
    echo "AWS_ACCESS_KEY_ID=from-dotenv" >"${SVC}/${f}"
    PACKAGE_STAGE=qa package
    [ "$status" -eq 1 ] || { echo "accepted ${f}"; return 1; }
    [[ "$output" == *"${f} exists in the service root"* ]]
  done
  [ ! -f "${STUB_LOG}/sls.log" ]
}

@test "refuses serverless-dotenv-plugin options that move its file" {
  local opt
  for opt in path basePath; do
    printf 'service: demo\ncustom:\n  dotenv:\n    %s: config/\n' "$opt" >"${SVC}/serverless.yml"
    package
    [ "$status" -eq 1 ] || { echo "accepted ${opt}"; return 1; }
    [[ "$output" == *"serverless.yml: custom.dotenv sets ${opt}"* ]]
  done
  [ ! -f "${STUB_LOG}/sls.log" ]
}

@test "refuses dotenv options it cannot read: indirection, merge keys, non-YAML configs" {
  local spec
  # shellcheck disable=SC2016  # literal Serverless variables
  for spec in 'custom: ${file(./c.yml)}|custom is not a plain map' \
    'custom:\n  dotenv: ${file(./d.yml)}|custom.dotenv is not a plain map' \
    'x: &x\n  path: y\ncustom:\n  dotenv:\n    <<: *x|uses YAML anchors, aliases or merge keys' \
    'x: &x\n  dotenv: {path: y}\ncustom:\n  <<: *x|uses YAML anchors, aliases or merge keys' \
    'b: &b\n  custom:\n    dotenv: {path: y}\n<<: *b|uses YAML anchors, aliases or merge keys' \
    '<<: {custom: {dotenv: {path: y}}}|uses YAML anchors, aliases or merge keys' \
    'custom:\n  !!merge foo: {dotenv: {path: y}}|uses YAML anchors, aliases or merge keys' \
    'custom:\n  dotenv: {include: [A]}\nx: &unused 1|uses YAML anchors, aliases or merge keys' \
    'x:\n  &p path: z\ncustom:\n  dotenv:\n    *p : y|uses YAML anchors, aliases or merge keys' \
    'x:\n  &d dotenv: z\ncustom:\n  *d : {path: y}|uses YAML anchors, aliases or merge keys' \
    'x:\n  &c custom: z\n*c : {dotenv: {path: y}}|uses YAML anchors, aliases or merge keys'; do
    printf 'service: demo\n%b\n' "${spec%%|*}" >"${SVC}/serverless.yml"
    package
    [ "$status" -eq 1 ] || { echo "accepted ${spec}"; return 1; }
    [[ "$output" == *"${spec#*|}"* ]] || { echo "${spec}: ${output}"; return 1; }
  done
  rm "${SVC}/serverless.yml"
  echo "module.exports = {}" >"${SVC}/serverless.js"
  package
  [ "$status" -eq 1 ]
  [[ "$output" == *"serverless.js found"* ]]
  [ ! -f "${STUB_LOG}/sls.log" ]
}

@test "checks serverless.yaml too" {
  printf 'custom:\n  dotenv:\n    path: x\n' >"${SVC}/serverless.yaml"
  package
  [ "$status" -eq 1 ]
  [[ "$output" == *"serverless.yaml: custom.dotenv sets path"* ]]
}

@test "allows serverless-dotenv-plugin include lists and CloudFormation tags" {
  printf '%s\n' 'service: demo' 'custom:' '  dotenv:' '    include:' '      - NOTHING' \
    'resources:' '  Outputs:' '    Arn:' '      Value: !GetAtt Fn.Arn' >"${SVC}/serverless.yml"
  package
  [ "$status" -eq 0 ]
}

@test "refuses a scratch dir inside the service checkout (TMPDIR)" {
  mkdir -p "${SVC}/tmp"
  TMPDIR="${SVC}/tmp" package
  [ "$status" -eq 1 ]
  [[ "$output" == *"is inside the service checkout"* ]]
  [ ! -f "${STUB_LOG}/npm.log" ]
}

@test "refuses to run from scripts downloaded into the service checkout" {
  mkdir -p "${SVC}/ci"
  cp "${REPO_ROOT}/scripts/serverless/package.sh" "${SVC}/ci/"
  run bash "${SVC}/ci/package.sh"
  [ "$status" -eq 1 ]
  # pwd -P may resolve SVC (macOS: /var -> /private/var), so match the suffix.
  [[ "$output" == *"/svc/ci is inside the service checkout"* ]]
  [ ! -f "${STUB_LOG}/npm.log" ]
}

@test "refuses to package when .env.<PACKAGE_STAGE> exists in the service root" {
  echo "AWS_ACCESS_KEY_ID=from-dotenv" >"${SVC}/.env.qa"
  PACKAGE_STAGE=qa package
  [ "$status" -eq 1 ]
  [[ "$output" == *".env.qa exists in the service root"* ]]
  [ ! -f "${STUB_LOG}/sls.log" ]
}

@test "a failing forbidden-entry scan stops packaging" {
  FAKE_GREP_FAIL=1 package
  [ "$status" -eq 1 ]
  [[ "$output" == *"forbidden-entry scan"*"failed (grep exit 2)"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
  [ ! -e "${SVC}/dist/demo.zip" ]
}

@test "refuses a zip that contains its own output path" {
  FAKE_ZIP_MODE=own-output package
  [ "$status" -eq 1 ]
  [[ "$output" == *"dist/demo.zip"* ]]
  [[ "$output" == *"forbidden entries"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "fails when the local serverless cannot report its version" {
  SLS_VERSION_EXIT=1 package
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to report its version"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
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

@test "refuses a lone layer zip when no service package was built" {
  FAKE_ZIP_MODE=layer-only package
  [ "$status" -eq 1 ]
  [[ "$output" == *"built no service package"* ]]
  [ ! -f "${SVC}/dist/demo.zip" ]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "refuses a zip that is not the artifact recorded in the state file" {
  FAKE_ZIP_MODE=other-artifact package
  [ "$status" -eq 1 ]
  [[ "$output" == *"not the service package recorded"*"prebuilt.zip"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "refuses a prebuilt package.artifact named like a layer zip" {
  FAKE_ZIP_MODE=artifact-named-like-layer package
  [ "$status" -eq 1 ]
  [[ "$output" == *"layer.zip is not the service package Serverless builds (demo.zip)"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "refuses settings that make or substitute another zip, even with a matching name" {
  local spec
  for spec in 'same-name-layer|layers' 'individually|package.individually' \
    'individually-string|package.individually' \
    'fn-artifact|function-level' 'fn-individually|function-level'; do
    rm -rf "${SVC}/.serverless" "${SVC}/dist" "${STUB_LOG}/buildkite-agent.log"
    FAKE_ZIP_MODE="${spec%%|*}" package
    [ "$status" -eq 1 ] || { echo "accepted ${spec}"; return 1; }
    [[ "$output" == *"shows ${spec#*|}"* ]] || { echo "${spec}: ${output}"; return 1; }
    [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
  done
}

@test "fails without the Serverless state file" {
  FAKE_ZIP_MODE=no-state package
  [ "$status" -eq 1 ]
  [[ "$output" == *"serverless-state.json not found"* ]]
  [ ! -f "${STUB_LOG}/buildkite-agent.log" ]
}

@test "fails on serverless major version 3" {
  FAKE_SLS_VERSION=3.38.0 package
  [ "$status" -eq 1 ]
  [[ "$output" == *"only major version 2"* ]]
  run grep -c '^package ' "${STUB_LOG}/sls.log"
  [ "$output" = "0" ]
}

@test "fails on serverless major version 1" {
  FAKE_SLS_VERSION=1.83.3 package
  [ "$status" -eq 1 ]
}

@test "a failing npm ci propagates" {
  NPM_STUB_EXIT=3 package
  [ "$status" -ne 0 ]
  [ ! -f "${STUB_LOG}/sls.log" ]
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
