# Shared bats helpers. Load with `load <relative path>/test_helper`.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # used by the test files that load this helper
RESOURCES="${REPO_ROOT}/test/resources"

# Prepend an empty stub bin dir to PATH and create the stub log dir.
setup_stubs() {
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  STUB_LOG="${BATS_TEST_TMPDIR}/stub-log"
  mkdir -p "$STUB_BIN" "$STUB_LOG"
  export STUB_LOG
  PATH="${STUB_BIN}:${PATH}"
  export PATH
}

# stub <command> <body> — create an executable stub running <body> in bash.
stub() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" >"${STUB_BIN}/$1"
  chmod +x "${STUB_BIN}/$1"
}

# buildkite-agent stub: logs "cwd<TAB>argv" per call; on `pipeline upload` and
# `artifact upload` copies the named file into $STUB_LOG/captured/;
# BUILDKITE_AGENT_STUB_EXIT forces a failure exit status.
stub_buildkite_agent() {
  # shellcheck disable=SC2016  # body is evaluated by the stub, not here
  stub buildkite-agent '
printf "%s\t%s\n" "$PWD" "$*" >>"$STUB_LOG/buildkite-agent.log"
mkdir -p "$STUB_LOG/captured"
case "$1 $2" in
  "pipeline upload") cp "${!#}" "$STUB_LOG/captured/pipeline.yml" ;;
  "artifact upload") [ -f "$3" ] && cp "$3" "$STUB_LOG/captured/" ;;
esac
exit "${BUILDKITE_AGENT_STUB_EXIT:-0}"'
}
