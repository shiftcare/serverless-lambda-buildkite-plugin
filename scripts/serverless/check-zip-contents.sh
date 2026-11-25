#!/usr/bin/env bash
# Usage: check-zip-contents.sh [--raw] <zip> <reference-list>
#
# Compares the file entries of <zip> with <reference-list> (one path per line).
# By default the reference is an annotated list: blank lines, '#' comments and
# carriage returns are ignored. With --raw it is an `unzip -Z1` listing, taken
# verbatim, so paths that start with '#' or are blank-looking still count.
# Directory entries and the CI stamp ci.build.info.txt are ignored on both
# sides. Prints a unified diff (- reference, + zip) on mismatch.
# Exit: 0 match, 1 mismatch, 2 usage or read error.
set -euo pipefail

usage() {
  echo "usage: check-zip-contents.sh [--raw] <zip> <reference-list>" >&2
  exit 2
}

raw=0
if [ "${1:-}" = --raw ]; then
  raw=1
  shift
fi
[ "$#" -eq 2 ] || usage
zip_file="$1"
reference="$2"
[ -f "$zip_file" ] || { echo "check-zip-contents: zip not found: ${zip_file}" >&2; exit 2; }
[ -f "$reference" ] || { echo "check-zip-contents: reference list not found: ${reference}" >&2; exit 2; }
command -v unzip >/dev/null 2>&1 || { echo "check-zip-contents: unzip not found" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

normalise() {
  awk '!/\/$/ && $0 != "ci.build.info.txt"' | LC_ALL=C sort -u
}

# unzip treats wildcard characters in the archive name as a pattern (so
# build[1].zip can open build1.zip) and a leading '-' as an option. List a
# copy under a fixed, plain name instead. Read it by redirection, so a file
# literally named '-' is not taken as stdin.
if ! cat <"$zip_file" >"${work}/archive.zip"; then
  echo "check-zip-contents: cannot read ${zip_file}" >&2
  exit 2
fi
if ! unzip -Z1 "${work}/archive.zip" >"${work}/raw"; then
  echo "check-zip-contents: cannot list ${zip_file}" >&2
  exit 2
fi
normalise <"${work}/raw" >"${work}/zip"
# A reference that passes -f can still be unreadable; that is a read error
# (2), not a mismatch (1).
# cat, not cp: the scratch copy must not inherit the reference's permissions.
if [ "$raw" -eq 1 ]; then
  reader=(cat --)
  filter=(cat)
else
  reader=(tr -d '\r')
  filter=(awk 'NF && !/^[[:space:]]*#/')
fi
if ! "${reader[@]}" <"$reference" >"${work}/reference-raw"; then
  echo "check-zip-contents: cannot read ${reference}" >&2
  exit 2
fi
"${filter[@]}" "${work}/reference-raw" | normalise >"${work}/reference"

status=0
diff -u -L reference -L zip "${work}/reference" "${work}/zip" || status=$?
case "$status" in
  0) echo "check-zip-contents: ${zip_file} matches ${reference}" ;;
  1) echo "check-zip-contents: ${zip_file} differs from ${reference}" >&2 ;;
  *) exit 2 ;;
esac
exit "$status"
