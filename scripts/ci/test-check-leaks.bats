#!/usr/bin/env bats

load ../../test/test_helper

# Hostile values are assembled at runtime so this repo never contains them.
ACCOUNT_ID="1234""56789012"
ARN="arn"":aws:iam::role/x"
ACCESS_KEY="AK""IA""ABCDEFGHIJKLMNOP"
SESSION_KEY="AS""IA""ABCDEFGHIJKLMNOP"

setup() {
  CHECK="${REPO_ROOT}/scripts/ci/check-leaks.sh"
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  printf 'clean file\n' >"${REPO}/README.md"
  track README.md
}

track() {
  git -C "$REPO" add -- "$@"
}

put() {
  printf '%s\n' "$2" >"${REPO}/$1"
  track "$1"
}

@test "a clean repo passes" {
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "flags a 12-digit account ID without printing it" {
  put config.txt "account = ${ACCOUNT_ID}"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config.txt:1: account-id"* ]]
  [[ "$output" != *"$ACCOUNT_ID"* ]]
}

@test "flags an account ID at line start and end" {
  put a.txt "${ACCOUNT_ID}"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
}

@test "allows the all-zeros placeholder" {
  put a.txt "id: 000000000000 and 000000000000"
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "flags an account ID next to the placeholder" {
  put a.txt "000000000000,${ACCOUNT_ID}"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
}

@test "ignores longer and shorter digit runs" {
  put a.txt "${ACCOUNT_ID}9 and 12345678901"
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "flags an ARN" {
  put a.yml "role: ${ARN}"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.yml:1: arn"* ]]
}

@test "flags an access key ID" {
  put a.sh "key=${ACCESS_KEY}"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"access-key-id"* ]]
}

@test "flags a temporary access key ID" {
  put a.sh "key=${SESSION_KEY}"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
}

@test "ignores untracked files" {
  printf '%s\n' "$ACCOUNT_ID" >"${REPO}/untracked.txt"
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "scans subdirectories" {
  mkdir -p "${REPO}/a/b"
  put a/b/c.txt "$ARN"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a/b/c.txt:1:"* ]]
}

@test "allowlist suppresses a matching path and string only" {
  put docs.md "example ${ACCOUNT_ID}"
  put other.md "example ${ACCOUNT_ID}"
  put .leak-allowlist "# reviewed
docs.md:example "
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other.md:1:"* ]]
  [[ "$output" != *"docs.md"* ]]
  [[ "$output" != *".leak-allowlist"* ]]
}

@test "scans the allowlist itself, and its entries cannot exempt it" {
  put docs.md "example ${ACCOUNT_ID}"
  put .leak-allowlist "docs.md:example ${ACCOUNT_ID}
.leak-allowlist:docs.md"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *".leak-allowlist:1: account-id"* ]]
  [[ "$output" != *"docs.md:1:"* ]]
  [[ "$output" != *"$ACCOUNT_ID"* ]]
}

@test "fails on a tracked path containing a colon, even when allowlisted" {
  put 'a:1:b.txt' "example ${ACCOUNT_ID}"
  put a "x"
  put .leak-allowlist "a:example"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a:1:b.txt: path contains ':'"* ]]
}

@test "finds colon paths in subdirectories whatever the pathspec settings" {
  mkdir -p "${REPO}/sub/deep"
  put 'sub/deep/x:y.txt' "nothing here"
  local var
  for var in GIT_GLOB_PATHSPECS GIT_LITERAL_PATHSPECS GIT_NOGLOB_PATHSPECS; do
    run env "${var}=1" "$CHECK" "$REPO"
    [ "$status" -eq 1 ] || { echo "${var}: ${output}"; return 1; }
    [[ "$output" == *"sub/deep/x:y.txt: path contains ':'"* ]]
  done
}

@test "a colon path with no hit still fails" {
  put 'a:b.txt' "nothing here"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a:b.txt: path contains ':'"* ]]
}

@test "allowlist entry with an empty string suppresses nothing" {
  put docs.md "example ${ACCOUNT_ID}"
  put .leak-allowlist "docs.md:"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs.md:1:"* ]]
}

@test "flags a binary file that matches, by path only, despite the allowlist" {
  printf 'x\000y %s\n' "$ACCOUNT_ID" >"${REPO}/blob.bin"
  track blob.bin
  put .leak-allowlist "blob.bin:y"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"blob.bin: binary file matches"* ]]
  [[ "$output" != *"$ACCOUNT_ID"* ]]
}

@test "flags a PNG-like binary with invalid UTF-8 bytes, whatever the locale" {
  printf '\211PNG\000 ts=%s\n' "$ACCOUNT_ID" >"${REPO}/a.png"
  track a.png
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.png: binary file matches"* ]]
}

@test "exits 2 when git grep fails" {
  setup_stubs
  REAL_GIT="$(type -P git)"
  export REAL_GIT
  # shellcheck disable=SC2016  # stub body expands at stub run time
  stub git '
for a in "$@"; do [ "$a" != grep ] || exit 128; done
exec "$REAL_GIT" "$@"'
  run "$CHECK" "$REPO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"git grep failed (exit 128)"* ]]
}

@test "a binary file without a match passes" {
  printf 'x\000y\n' >"${REPO}/blob.bin"
  track blob.bin
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "runs from a subdirectory of the repo" {
  mkdir -p "${REPO}/sub"
  put a.txt "$ACCOUNT_ID"
  run "$CHECK" "${REPO}/sub"
  [ "$status" -eq 1 ]
}

@test "exits 2 outside a git work tree" {
  mkdir -p "${BATS_TEST_TMPDIR}/plain"
  run "$CHECK" "${BATS_TEST_TMPDIR}/plain"
  [ "$status" -eq 2 ]
}

@test "this repository is clean" {
  run "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
