#!/usr/bin/env bash
# pre-commit hook: `ggshield-hook.sh pre-commit` scans the staged changes, `ggshield-hook.sh pre-push` the
# commits about to be pushed (in a public repository a push publishes them). Either runs the ggshield on
# PATH only at the version scripts/ggshield-requirements.lock pins (README.md#secret-scanning).
set -euo pipefail
mode="${1:-}"
[[ "$mode" == pre-commit || "$mode" == pre-push ]] || { echo "usage: ggshield-hook.sh {pre-commit,pre-push}" >&2; exit 2; }
shift
want="$(sed -n 's/^ggshield==\([^ ]*\) .*/\1/p' "$(dirname "$0")/ggshield-requirements.lock")"
have="$(ggshield --version 2>/dev/null | sed -n 's/^ggshield, version //p' || true)"
if [[ "$have" != "$want" ]]; then
  echo "the ggshield hook needs ggshield $want on PATH, installed from scripts/ggshield-requirements.lock" \
    "(found: ${have:-none}); see README.md#secret-scanning" >&2
  exit 1
fi
exec ggshield secret scan "$mode" "$@"
