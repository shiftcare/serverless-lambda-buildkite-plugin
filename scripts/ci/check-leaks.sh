#!/usr/bin/env bash
# Usage: check-leaks.sh [repo-dir]
#
# Fails if a tracked file contains an AWS account-ID-shaped number (exactly 12
# digits; the placeholder 000000000000 is allowed), an ARN, or an access key
# ID. To accept a reviewed false positive, add "<path>:<fixed string>" to
# <repo>/.leak-allowlist: hits in <path> on lines containing <fixed string>
# are ignored. The allowlist itself is scanned and never exempt, so <fixed
# string> must be surrounding context, not the flagged value. Tracked paths
# containing ':' and tracked symlinks fail. Prints path:line and the kind of hit, never the
# matched text.
# A binary file (as git classifies it) that matches any pattern fails by path
# alone and cannot be allowlisted. That match is stricter than the text one:
# the 000000000000 placeholder and longer digit runs also fail.
# Exit: 0 clean, 1 hits found, 2 usage or git error.
set -euo pipefail

[ "$#" -le 1 ] || { echo "usage: check-leaks.sh [repo-dir]" >&2; exit 2; }
root="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null)" ||
  { echo "check-leaks: not a git work tree: ${1:-.}" >&2; exit 2; }

# Patterns are split so this file does not match itself.
arn_re='arn'':aws'
key_re='(AKIA|ASIA)[A-Z0-9]{16}'
id_re='[0-9]{12}'

scan() {
  local out rc=0
  # LC_ALL=C: under a UTF-8 locale (macOS), git grep skips matches on lines
  # holding invalid UTF-8, which binaries and Latin-1 text contain.
  out="$(LC_ALL=C git -C "$root" grep "$@" -E -e "$id_re" -e "$arn_re" -e "$key_re" \
    -- .)" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "check-leaks: git grep failed (exit ${rc})" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# Text files are checked line by line below. Binary files (which `-I` skips)
# cannot be, so any binary file that matches a pattern fails by path and
# cannot be allowlisted.
hits="$(scan -n -I)"
matching="$(scan -l)"
text_matching="$(scan -l -I)"
# Sort into variables first: a failure inside a process substitution would not
# reach this script, and an empty sorted list would hide binary matches.
sort_or_fail() {
  printf '%s\n' "$1" | LC_ALL=C sort ||
    { echo "check-leaks: sort failed" >&2; exit 2; }
}
matching_sorted="$(sort_or_fail "$matching")" || exit 2
text_sorted="$(sort_or_fail "$text_matching")" || exit 2
binary="$(LC_ALL=C comm -23 <(printf '%s\n' "$matching_sorted") <(printf '%s\n' "$text_sorted") |
  sed '/^$/d')" || { echo "check-leaks: comm failed" >&2; exit 2; }

failed=0
# Hits are parsed as "path:line:content", so a path containing ':' would be
# split in the wrong place and could match another file's allowlist entry.
# Filtered by name, not pathspec: GIT_*_PATHSPECS variables change glob matching.
colon_paths="$(git -C "$root" ls-files -z | tr '\0' '\n' | LC_ALL=C awk 'index($0, ":")')" ||
  { echo "check-leaks: git ls-files failed" >&2; exit 2; }
if [ -n "$colon_paths" ]; then
  while IFS= read -r f; do
    printf "%s: path contains ':' (cannot be matched to the allowlist unambiguously; rename it)\n" "$f"
  done <<<"$colon_paths"
  failed=1
fi
# git grep skips symlinks, but the commit stores each link's target text, which
# is public too. Refuse tracked symlinks (mode 120000) rather than scan them.
symlinks="$(git -C "$root" ls-files -s -z | tr '\0' '\n' |
  LC_ALL=C awk '$1 == "120000" { sub(/^[^\t]*\t/, ""); print }')" ||
  { echo "check-leaks: git ls-files failed" >&2; exit 2; }
if [ -n "$symlinks" ]; then
  while IFS= read -r f; do
    printf '%s: tracked symlink (its target text is not scanned; replace it with a file)\n' "$f"
  done <<<"$symlinks"
  failed=1
fi
if [ -n "$binary" ]; then
  while IFS= read -r f; do
    printf '%s: binary file matches (binary files are not checked line by line or allowlisted)\n' "$f"
  done <<<"$binary"
  failed=1
fi
report_failure() {
  echo "check-leaks: possible account IDs, ARNs or access keys found (see above)" >&2
  exit 1
}
if [ -z "$hits" ]; then
  [ "$failed" -eq 0 ] || report_failure
  echo "check-leaks: clean"
  exit 0
fi

allowlist="${root}/.leak-allowlist"
[ -f "$allowlist" ] || allowlist=/dev/null

# Classify each "path:line:content" hit; awk keeps this portable (no regex
# interval support needed).
printf '%s\n' "$hits" | awk -v allow="$allowlist" '
  BEGIN {
    n = 0
    while ((getline l < allow) > 0) {
      if (l ~ /^[[:space:]]*(#|$)/) continue
      i = index(l, ":")
      # Skip entries with no path or an empty string: index(x, "") is 1, so
      # an empty string would suppress every hit in that path.
      if (i < 2 || i == length(l)) continue
      n++; apath[n] = substr(l, 1, i - 1); astr[n] = substr(l, i + 1)
    }
    found = 0
  }
  {
    p = index($0, ":"); path = substr($0, 1, p - 1); rest = substr($0, p + 1)
    q = index(rest, ":"); lnum = substr(rest, 1, q - 1); content = substr(rest, q + 1)

    kinds = ""
    s = content
    while (match(s, /[0-9]+/)) {
      tok = substr(s, RSTART, RLENGTH)
      if (length(tok) == 12 && tok != "000000000000") { kinds = kinds " account-id"; break }
      s = substr(s, RSTART + RLENGTH)
    }
    if (index(content, "arn" ":aws")) kinds = kinds " arn"
    s = content
    while (match(s, /(AKIA|ASIA)[A-Z0-9]+/)) {
      if (RLENGTH >= 20) { kinds = kinds " access-key-id"; break }
      s = substr(s, RSTART + RLENGTH)
    }
    if (kinds == "") next

    # The allowlist is public too: hits in it are never suppressed, so its
    # entries must use context strings, not the flagged values.
    if (path != ".leak-allowlist")
      for (k = 1; k <= n; k++) if (apath[k] == path && index(content, astr[k])) next
    print path ":" lnum ":" kinds
    found = 1
  }
  END { exit found }
' || report_failure
[ "$failed" -eq 0 ] || report_failure
echo "check-leaks: clean"
