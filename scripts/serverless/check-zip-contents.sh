#!/usr/bin/env bash
# Usage: check-zip-contents.sh <zip> <reference-list>
#
# Compares the file entries of <zip> with <reference-list> (one path per line;
# blank lines and '#' comments ignored). Directory entries and the CI stamp
# ci.build.info.txt are ignored on both sides. Prints a unified diff
# (- reference, + zip) on mismatch.
# Exit: 0 match, 1 mismatch, 2 usage or read error.
set -euo pipefail

usage() {
  echo "usage: check-zip-contents.sh <zip> <reference-list>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
zip_file="$1"
reference="$2"
[ -f "$zip_file" ] || { echo "check-zip-contents: zip not found: ${zip_file}" >&2; exit 2; }
[ -f "$reference" ] || { echo "check-zip-contents: reference list not found: ${reference}" >&2; exit 2; }
command -v unzip >/dev/null 2>&1 || { echo "check-zip-contents: unzip not found" >&2; exit 2; }
# unzip would read a dash-leading relative path as an option.
case "$zip_file" in
  -*) zip_file="./${zip_file}" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

normalise() {
  awk '!/\/$/ && $0 != "ci.build.info.txt"' | LC_ALL=C sort -u
}

if ! unzip -Z1 "$zip_file" >"${work}/raw"; then
  echo "check-zip-contents: cannot list ${zip_file}" >&2
  exit 2
fi
normalise <"${work}/raw" >"${work}/zip"
tr -d '\r' <"$reference" | awk 'NF && !/^[[:space:]]*#/' | normalise >"${work}/reference"

status=0
diff -u -L reference -L zip "${work}/reference" "${work}/zip" || status=$?
case "$status" in
  0) echo "check-zip-contents: ${zip_file} matches ${reference}" ;;
  1) echo "check-zip-contents: ${zip_file} differs from ${reference}" >&2 ;;
  *) exit 2 ;;
esac
exit "$status"
