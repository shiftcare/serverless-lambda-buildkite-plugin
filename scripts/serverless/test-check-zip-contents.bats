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

@test "matches a reference produced with unzip -Z1, with --raw" {
  unzip -Z1 "$ZIP" >"$REF"
  run "$CHECK" --raw "$ZIP" "$REF"
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

@test "--raw keeps listed paths that start with '#' or look blank" {
  local src="${BATS_TEST_TMPDIR}/hashsrc" zip="${BATS_TEST_TMPDIR}/hash.zip"
  mkdir -p "$src"
  echo a >"$src/#notes.txt"
  echo b >"$src/  #spaced"
  echo c >"$src/plain.js"
  (cd "$src" && zip -qr "$zip" .)
  unzip -Z1 "$zip" >"$REF"
  run "$CHECK" --raw "$zip" "$REF"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # Without --raw the '#' paths are comments, so the zip has extra files.
  run "$CHECK" "$zip" "$REF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"+#notes.txt"* ]]
}

@test "--raw still reports a real difference" {
  printf 'handler.js\nlib/missing.js\n' >"$REF"
  run "$CHECK" --raw "$ZIP" "$REF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"-lib/missing.js"* ]]
}

@test "--raw exits 2 on an unreadable reference" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  printf 'handler.js\n' >"$REF"
  chmod 000 "$REF"
  run "$CHECK" --raw "$ZIP" "$REF"
  chmod 600 "$REF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read"* ]]
}

@test "compares the exact zip named, even with wildcard characters in its name" {
  local d="${BATS_TEST_TMPDIR}/wild"
  mkdir -p "$d/a" "$d/b"
  echo a >"$d/a/only-in-bracket.js"
  echo b >"$d/b/only-in-plain.js"
  (cd "$d/a" && zip -qr "../build[1].zip" .)
  (cd "$d/b" && zip -qr "../build1.zip" .)
  printf 'only-in-bracket.js\n' >"$REF"
  run "$CHECK" --raw "$d/build[1].zip" "$REF"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'only-in-plain.js\n' >"$REF"
  run "$CHECK" --raw "$d/build[1].zip" "$REF"
  [ "$status" -eq 1 ]
}

@test "compares a zip named '-' rather than reading stdin" {
  printf 'handler.js\nlib/util.js\n' >"$REF"
  cp "$ZIP" "${BATS_TEST_TMPDIR}/-"
  cd "$BATS_TEST_TMPDIR" || return 1
  run "$CHECK" - "$REF" </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "exits 2, not 1, when the scratch directory cannot be created" {
  printf 'handler.js\nlib/util.js\n' >"$REF"
  setup_stubs
  stub mktemp 'exit 1'
  run "$CHECK" "$ZIP" "$REF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot create a scratch directory"* ]]
}

@test "exits 2, not 1, when normalisation fails" {
  printf 'handler.js\nlib/util.js\n' >"$REF"
  setup_stubs
  stub sort 'exit 1'
  run "$CHECK" "$ZIP" "$REF"
  [ "$status" -eq 2 ]
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
