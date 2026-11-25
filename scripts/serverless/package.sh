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

# Serverless packages whatever sits under the service root, so neither this
# script's scratch dir nor the downloaded scripts may live there (a TMPDIR
# pointing into the checkout would put both in the zip).
root="$(pwd -P)"
[ "$root" != / ] || fail "refusing to package from /"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
for path in "$(cd "$work" && pwd -P)" "$script_dir"; do
  case "${path}/" in
    "${root}/"*) fail "${path} is inside the service checkout ${root}; Serverless would package it (keep TMPDIR and the downloaded scripts outside the checkout)" ;;
  esac
done

# Leave the AWS SDKs no credential source: no AWS_* env vars, no AMAZON_* ones
# (AWS SDK v2 still reads legacy AMAZON_ACCESS_KEY_ID and friends), no IMDS
# lookup (AWS_EC2_METADATA_DISABLED only stops the SDKs; it does not block
# IMDS), and no ~/.aws (Serverless runs with an empty HOME below).
while IFS= read -r name; do
  case "$name" in
    AWS_* | AMAZON_*) unset "$name" ;;
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
# AWS_REGION was stripped above and Serverless v2 ignores it anyway; without
# --region or provider.region, ${aws:region} resolves to us-east-1.
PACKAGE_REGION="${PACKAGE_REGION:-}"
region_args=()
if [ -n "$PACKAGE_REGION" ]; then
  region_re='^[a-z]{2}(-[a-z]+)+-[0-9]+$'
  [[ "$PACKAGE_REGION" =~ $region_re ]] || fail "PACKAGE_REGION must match ${region_re} (got '${PACKAGE_REGION}')"
  region_args=(--region "$PACKAGE_REGION")
fi

for tool in node npm unzip yq zip; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: ${tool}"
done

out="dist/${SERVICE}.zip"
# A previous run's output would otherwise be picked up by Serverless's default
# file selection and packaged into the new zip. Only this file is removed:
# dist/ itself may hold the service's own build output.
rm -f -- "$out"

# --include=dev: Serverless is a devDependency, and a passed-through
# NODE_ENV=production would otherwise make npm ci omit it.
npm ci --include=dev

# Dotenv files load into Serverless's own environment at package time and
# could hand it AWS credentials after the scrub above: the core loader
# (useDotenv: true) reads .env.<stage> or .env, and serverless-dotenv-plugin
# reads .env.<NODE_ENV, else --env, in later versions --stage, else
# "development"> or .env, loading every variable
# into the process whatever its `include` list says. Refuse every .env and
# .env.* in the service root, and the plugin options that move its file
# elsewhere. Checked after npm ci (a lifecycle script could create one) and
# before `sls --version`, the first Serverless run.
shopt -s nullglob
for dotenv in .env .env.*; do
  if [ -e "$dotenv" ] || [ -L "$dotenv" ]; then
    fail "${dotenv} exists in the service root; Serverless can load it at package time (remove it from the checkout)"
  fi
done
shopt -u nullglob
# The option check reads literal YAML, so anything that could hide those
# options from it is refused too: a custom or custom.dotenv that is not a
# plain map (e.g. ${file(...)}), any YAML anchor, alias or merge key, keys
# included (`...` visits keys; yq versions and Serverless's own YAML loader
# resolve these differently, so the check could see a different mapping from
# the plugin), or a non-YAML config. `kind` needs yq v4.40.1 or later.
for config in serverless.json serverless.js serverless.cjs serverless.mjs serverless.ts; do
  [ ! -e "$config" ] ||
    fail "${config} found; only serverless.yml is supported (its dotenv options cannot be checked)"
done
# shellcheck disable=SC2016  # yq expression, not shell
# Messages are set with `. = "..."`: a bare string literal after a pipe is
# emitted by yq even when the left side yields nothing.
dotenv_rules='[
  ([(., ...) | select((anchor != "") or (kind == "alias") or ((key | tag) == "!!merge") or (key == "<<"))] | select(length > 0) | . = "uses YAML anchors, aliases or merge keys"),
  (.custom | select((tag != "!!map") and (tag != "!!null")) | . = "custom is not a plain map"),
  (.custom | select(tag == "!!map") | .dotenv | select((tag != "!!map") and (tag != "!!null")) | . = "custom.dotenv is not a plain map"),
  (.custom.dotenv | select(tag == "!!map") | keys | .[] | select((. == "path") or (. == "basePath")) | . = "custom.dotenv sets " + .)
] | join("; ")'
for config in serverless.yml serverless.yaml; do
  [ -f "$config" ] || continue
  bad_dotenv="$(yq "$dotenv_rules" "$config")" ||
    fail "cannot read custom.dotenv from ${config}"
  [ -z "$bad_dotenv" ] ||
    fail "${config}: ${bad_dotenv}; package only checks the service root for dotenv files (remove it)"
done

# Only the lockfile-pinned, service-local Serverless: `npx --no-install` can
# fall back to a global install with a different version.
sls_bin="${PWD}/node_modules/.bin/serverless"
[ -x "$sls_bin" ] ||
  fail "serverless is not installed locally after npm ci (add it to devDependencies)"
sls() {
  HOME="$sls_home" "$sls_bin" "$@"
}

node_version="$(node --version)"
sls_output="$(sls --version)" ||
  fail "local serverless failed to report its version"
sls_version="$(printf '%s\n' "$sls_output" |
  sed -n -E 's/.*Framework Core: v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
if [ -z "$sls_version" ]; then
  sls_version="$(printf '%s\n' "$sls_output" |
    grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
fi
[ -n "$sls_version" ] || fail "cannot parse serverless version from: ${sls_output}"
[ "${sls_version%%.*}" = "2" ] || fail "serverless ${sls_version} found; only major version 2 is supported"
echo "node ${node_version}, serverless ${sls_version}"

sls package --stage "$PACKAGE_STAGE" ${region_args[@]+"${region_args[@]}"}

shopt -s nullglob
zips=(.serverless/*.zip)
shopt -u nullglob
case "${#zips[@]}" in
  1) zip_path="${zips[0]}" ;;
  0) fail "no .zip found in .serverless/" ;;
  *) fail "expected one .zip in .serverless/, found ${#zips[@]} (individually packaged functions are not supported): ${zips[*]}" ;;
esac

# Resolved config can carry secrets; none of it may ship in the code zip.
# Also refuse our own output path, in case a previous artifact still got in.
forbidden="(^|/)\\.serverless/|(^|/)\\.env(/|\$)|(^|/)\\.env\\.|cloudformation-template-.*\\.json\$|serverless-state\\.json\$|^dist/${SERVICE}\\.zip\$"
entries="$(unzip -Z1 "$zip_path")" || fail "cannot list ${zip_path}"
# grep exits 1 when nothing matches; anything above 1 means the scan itself
# failed, and the zip must not ship unscanned.
scan_rc=0
bad="$(printf '%s\n' "$entries" | grep -E "$forbidden")" || scan_rc=$?
[ "$scan_rc" -le 1 ] || fail "forbidden-entry scan of ${zip_path} failed (grep exit ${scan_rc})"
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
