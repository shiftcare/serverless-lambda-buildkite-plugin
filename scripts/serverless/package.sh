#!/usr/bin/env bash
# Packages the service in the current directory with Serverless v2 and uploads
# exactly one artifact: dist/<SERVICE>.zip. Serverless runs with no AWS
# credential source; see README for what this does not cover.
set -euo pipefail

fail() {
  echo "package: $*" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# Leave the AWS SDKs no credential source: no AWS_* env vars, no IMDS lookup
# (AWS_EC2_METADATA_DISABLED only stops the SDKs; it does not block IMDS), and
# no ~/.aws (Serverless runs with an empty HOME below).
while IFS= read -r name; do
  case "$name" in
    AWS_*) unset "$name" ;;
  esac
done < <(compgen -e)
export AWS_EC2_METADATA_DISABLED=true
sls_home="${work}/home"
mkdir -p "$sls_home"
# Services resolve these instead of calling AWS (see README, "Service contract").
export AWS_ACCOUNT_ID="${PACKAGE_AWS_ACCOUNT_ID:-000000000000}"
export SECRETS_PROVIDER_MODE=placeholder

SERVICE="${SERVICE:-}"
PACKAGE_STAGE="${PACKAGE_STAGE:-dev}"
name_re='^[a-z0-9][a-z0-9-]*$'
[[ "$SERVICE" =~ $name_re ]] || fail "SERVICE must match ${name_re} (got '${SERVICE}')"
[[ "$PACKAGE_STAGE" =~ $name_re ]] || fail "PACKAGE_STAGE must match ${name_re} (got '${PACKAGE_STAGE}')"

for tool in node npm npx unzip zip; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: ${tool}"
done

npm ci

sls() {
  HOME="$sls_home" npx --no-install serverless "$@"
}

node_version="$(node --version)"
sls_output="$(sls --version)" ||
  fail "serverless is not installed locally (add it to devDependencies)"
sls_version="$(printf '%s\n' "$sls_output" |
  sed -n -E 's/.*Framework Core: v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
if [ -z "$sls_version" ]; then
  sls_version="$(printf '%s\n' "$sls_output" |
    grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
fi
[ -n "$sls_version" ] || fail "cannot parse serverless version from: ${sls_output}"
[ "${sls_version%%.*}" = "2" ] || fail "serverless ${sls_version} found; only major version 2 is supported"
echo "node ${node_version}, serverless ${sls_version}"

sls package --stage "$PACKAGE_STAGE"

shopt -s nullglob
zips=(.serverless/*.zip)
shopt -u nullglob
case "${#zips[@]}" in
  1) zip_path="${zips[0]}" ;;
  0) fail "no .zip found in .serverless/" ;;
  *) fail "expected one .zip in .serverless/, found ${#zips[@]} (individually packaged functions are not supported): ${zips[*]}" ;;
esac

# Resolved config can carry secrets; none of it may ship in the code zip.
forbidden='(^|/)\.serverless/|(^|/)\.env$|(^|/)\.env\.|cloudformation-template-.*\.json$|serverless-state\.json$'
entries="$(unzip -Z1 "$zip_path")" || fail "cannot list ${zip_path}"
bad="$(printf '%s\n' "$entries" | grep -E "$forbidden" || true)"
if [ -n "$bad" ]; then
  printf '%s\n' "$bad" >&2
  fail "${zip_path} contains forbidden entries (listed above)"
fi

stamp="${work}/ci.build.info.txt"
{
  echo "service=${SERVICE}"
  echo "build_number=${BUILDKITE_BUILD_NUMBER:-unknown}"
  echo "commit=${BUILDKITE_COMMIT:-unknown}"
  echo "branch=${BUILDKITE_BRANCH:-unknown}"
  echo "node_version=${node_version}"
  echo "serverless_version=${sls_version}"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$stamp"

out="dist/${SERVICE}.zip"
mkdir -p dist
cp "$zip_path" "$out"
zip -q -j "$out" "$stamp"

if [ "${PACKAGE_SKIP_UPLOAD:-}" = "1" ]; then
  echo "Packaged ${out} (upload skipped)"
  exit 0
fi
command -v buildkite-agent >/dev/null 2>&1 ||
  fail "buildkite-agent not found (set PACKAGE_SKIP_UPLOAD=1 for local runs)"
buildkite-agent artifact upload "$out"
