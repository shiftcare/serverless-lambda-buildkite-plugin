#!/usr/bin/env bash
# Usage: check-leaks.sh [repo-dir]
#
# Fails if a tracked file contains an AWS account-ID-shaped number (exactly 12
# digits; the placeholder 000000000000 is allowed), an ARN, or an access key
# ID. To accept a reviewed false positive, add "<path>:<fixed string>" to
# <repo>/.leak-allowlist: hits in <path> on lines containing <fixed string>
# are ignored. Prints path:line and the kind of hit, never the matched text.
# Exit: 0 clean, 1 hits found, 2 usage or git error.
set -euo pipefail

[ "$#" -le 1 ] || { echo "usage: check-leaks.sh [repo-dir]" >&2; exit 2; }
root="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null)" ||
  { echo "check-leaks: not a git work tree: ${1:-.}" >&2; exit 2; }

# Patterns are split so this file does not match itself.
arn_re='arn'':aws'
key_re='(AKIA|ASIA)[A-Z0-9]{16}'
id_re='[0-9]{12}'

rc=0
hits="$(git -C "$root" grep -n -I -E -e "$id_re" -e "$arn_re" -e "$key_re" \
  -- . ':(exclude).leak-allowlist')" || rc=$?
if [ "$rc" -gt 1 ]; then
  echo "check-leaks: git grep failed (exit ${rc})" >&2
  exit 2
fi
[ -n "$hits" ] || { echo "check-leaks: clean"; exit 0; }

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

    for (k = 1; k <= n; k++) if (apath[k] == path && index(content, astr[k])) next
    print path ":" lnum ":" kinds
    found = 1
  }
  END { exit found }
' || { echo "check-leaks: possible account IDs, ARNs or access keys found (see above)" >&2; exit 1; }
echo "check-leaks: clean"
