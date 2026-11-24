#!/usr/bin/env bash
# review-det: sourced-library
#
# Pipeline-building helpers, sourced by generate_pipeline.sh and the
# scripts/*/generate.sh files. Functions return non-zero on error (never exit)
# and expect the caller to export:
#   PIPELINE_BASEDIR  root of this repo (templates/ and scripts/ live there)
#   PIPELINE_WORKDIR  per-run scratch dir created by the entry point
#   PIPELINE_FILE     the pipeline YAML being built

# Artifact path prefix for the uploaded scripts. Templates download
# "<prefix>/**/*.sh" and run "<prefix>/scripts/...", so keep them in step.
PIPELINE_ARTIFACT_PREFIX="serverless-lambda-pipeline"

_helper_err() {
  echo "helper: $*" >&2
}

_require_env() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      _helper_err "${name} is not set"
      return 1
    fi
  done
}

_require_workdir() {
  _require_env PIPELINE_WORKDIR || return 1
  if [ ! -d "$PIPELINE_WORKDIR" ]; then
    _helper_err "PIPELINE_WORKDIR is not a directory: ${PIPELINE_WORKDIR}"
    return 1
  fi
}

# mergeYaml <target> <source> — deep-merge <source> into <target> in place;
# arrays (steps) are appended, so call order is step order.
mergeYaml() {
  local target="${1:-}"
  local source="${2:-}"
  if [ -z "$target" ] || [ -z "$source" ]; then
    _helper_err "usage: mergeYaml <target> <source>"
    return 1
  fi
  # shellcheck disable=SC2016  # $item is a yq variable, not shell
  yq eval-all --inplace '. as $item ireduce ({}; . *+ $item)' "$target" "$source" || return 1
}

# replaceValuesInTemplate <file> [KEY=VALUE ...] — replace each @@KEY@@ token
# inside the file's string scalars with VALUE, literally. The document is
# edited as parsed YAML, so a value can never add keys or steps. Fails if any
# @@TOKEN@@ is left afterwards.
replaceValuesInTemplate() {
  local file="${1:-}"
  local item key value
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    _helper_err "replaceValuesInTemplate: template file not found: ${file}"
    return 1
  fi
  shift

  local key_re='^[A-Z][A-Z0-9_]*$'
  local nl=$'\n'
  local cr=$'\r'
  for item in "$@"; do
    case "$item" in
      *=*) ;;
      *)
        _helper_err "substitution is not KEY=VALUE: ${item}"
        return 1
        ;;
    esac
    key="${item%%=*}"
    value="${item#*=}"
    if ! [[ "$key" =~ $key_re ]]; then
      _helper_err "invalid substitution key: ${key}"
      return 1
    fi
    case "$value" in
      *"$nl"* | *"$cr"*)
        _helper_err "value for ${key} contains a line break"
        return 1
        ;;
      *@@*)
        _helper_err "value for ${key} contains '@@'"
        return 1
        ;;
    esac
    TEMPLATE_PLACEHOLDER="@@${key}@@" TEMPLATE_VALUE="$value" \
      yq --inplace \
      '(.. | select(tag == "!!str")) |= (split(strenv(TEMPLATE_PLACEHOLDER)) | join(strenv(TEMPLATE_VALUE)))' \
      "$file" || return 1
  done

  if grep -Eq '@@[A-Z0-9_]+@@' "$file"; then
    _helper_err "unreplaced placeholder(s) in ${file}: $(grep -Eo '@@[A-Z0-9_]+@@' "$file" | sort -u | tr '\n' ' ')"
    return 1
  fi
}

# addTemplate <name> [KEY=VALUE ...] — append templates/<name>.yml, with
# substitutions applied, to PIPELINE_FILE.
addTemplate() {
  local name="${1:-}"
  local name_re='^[a-z0-9_-]+(/[a-z0-9_-]+)*$'
  if [ -z "$name" ]; then
    _helper_err "addTemplate: missing template name"
    return 1
  fi
  shift
  if ! [[ "$name" =~ $name_re ]]; then
    _helper_err "addTemplate: invalid template name: ${name}"
    return 1
  fi
  _require_env PIPELINE_BASEDIR PIPELINE_FILE || return 1
  _require_workdir || return 1

  local src="${PIPELINE_BASEDIR}/templates/${name}.yml"
  if [ ! -f "$src" ]; then
    _helper_err "addTemplate: template not found: ${src}"
    return 1
  fi

  local dir
  dir="$(mktemp -d "${PIPELINE_WORKDIR}/template.XXXXXX")" || return 1
  local copy="${dir}/template.yml"
  cp "$src" "$copy" || return 1
  replaceValuesInTemplate "$copy" "$@" || return 1
  mergeYaml "$PIPELINE_FILE" "$copy" || return 1
}

# generateArtefacts — upload scripts/**/*.sh as build artifacts so later steps
# run the same script version. Staged under PIPELINE_WORKDIR, never the
# checkout: a service checkout would otherwise get the scripts zipped into its
# Lambda package.
generateArtefacts() {
  _require_env PIPELINE_BASEDIR || return 1
  _require_workdir || return 1

  local stage="${PIPELINE_WORKDIR}/${PIPELINE_ARTIFACT_PREFIX}"
  mkdir -p "$stage" || return 1
  cp -R "${PIPELINE_BASEDIR}/scripts" "${stage}/" || return 1
  (
    cd "$PIPELINE_WORKDIR" &&
      buildkite-agent artifact upload "${PIPELINE_ARTIFACT_PREFIX}/**/*.sh"
  ) || return 1
}
