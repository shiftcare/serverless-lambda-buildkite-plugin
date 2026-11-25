#!/usr/bin/env bats

load ../../test/test_helper

setup() {
  CHECK="${REPO_ROOT}/scripts/serverless/check-zip-contents.sh"
  local src="${BATS_TEST_TMPDIR}/src"
  mkdir -p "$src/lib"
  echo a >"$src/handler.js"
  echo b >"$src/lib/util.js"
  echo stamp >"$src/ci.build.info.txt"
  ZIP="${BATS_TEST_TMPDIR}/svc.zip"
  (cd "$src" && zip -qr "$ZIP" .)
  REF="${BATS_TEST_TMPDIR}/ref.txt"
}

@test "matches a reference list in any order, ignoring dirs, stamp, blanks and comments" {
  printf '# from the previous build\nlib/util.js\n\nlib/\nhandler.js\n' >"$REF"
  run "$CHECK" "$ZIP" "$REF"
  [ "$status" -eq 0 ]
}

@test "matches a reference produced with unzip -Z1 from another zip" {
  unzip -Z1 "$ZIP" >"$REF"
  run "$CHECK" "$ZIP" "$REF"
  [ "$status" -eq 0 ]
}

@test "prints a unified diff and exits 1 on difference" {
  printf 'handler.js\nlib/missing.js\n' >"$REF"
  run "$CHECK" "$ZIP" "$REF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--- reference"* ]]
  [[ "$output" == *"+++ zip"* ]]
  [[ "$output" == *"-lib/missing.js"* ]]
  [[ "$output" == *"+lib/util.js"* ]]
}

@test "accepts a relative zip path that starts with a dash" {
  printf 'handler.js\nlib/util.js\n' >"$REF"
  cp "$ZIP" "${BATS_TEST_TMPDIR}/-svc.zip"
  cd "$BATS_TEST_TMPDIR" || return 1
  run "$CHECK" -svc.zip "$REF"
  [ "$status" -eq 0 ]
}

@test "exits 2 on wrong argument count" {
  run "$CHECK" "$ZIP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "exits 2 on a missing zip" {
  printf 'handler.js\n' >"$REF"
  run "$CHECK" "${BATS_TEST_TMPDIR}/nope.zip" "$REF"
  [ "$status" -eq 2 ]
}

@test "exits 2 on a missing reference" {
  run "$CHECK" "$ZIP" "${BATS_TEST_TMPDIR}/nope.txt"
  [ "$status" -eq 2 ]
}

@test "exits 2, not 1, on a reference that exists but cannot be read" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  printf 'handler.js\nlib/util.js\n' >"$REF"
  chmod 000 "$REF"
  run "$CHECK" "$ZIP" "$REF"
  chmod 600 "$REF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read"* ]]
}

@test "exits 2 on a file that is not a zip" {
  printf 'handler.js\n' >"$REF"
  run "$CHECK" "$REF" "$REF"
  [ "$status" -eq 2 ]
}
