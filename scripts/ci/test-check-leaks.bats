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
docs.md:example ${ACCOUNT_ID}"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other.md:1:"* ]]
  [[ "$output" != *"docs.md"* ]]
  [[ "$output" != *".leak-allowlist"* ]]
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
