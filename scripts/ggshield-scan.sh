#!/usr/bin/env bash
# Publication secret scan with ggshield (GitGuardian's CLI), required before anything here is made public
# (README.md#secret-scanning). It scans everything the public can fetch, with the .gitguardian.yaml of the
# scanned branch:
#   - history: an anonymous `git clone --mirror` (every branch, tag and refs/pull/*), plus each pull-request
#     head a force push replaced that GitHub still serves by its SHA. The website is the repository's
#     content, so the history covers it;
#   - GitHub text: issues and pull requests with their comments, reviews and review comments, release
#     notes and commit comments; and the wiki, when it is enabled (an enabled wiki that cannot be cloned
#     fails the scan).
# Reports with matched values stay in the output directory (keep it private); the summary holds none.
# Exit 0 only when every scan is complete and finds 0 incidents. It refuses a ggshield version other
# than the one scripts/ggshield-requirements.lock pins, because its checks read that version's messages.
#
# usage: scripts/ggshield-scan.sh <new private output directory> [branch, default main]
# needs: git, gh (authenticated), python3, ggshield (or GGSHIELD=<path>) with a GitGuardian API key
set -euo pipefail
out="${1:?usage: scripts/ggshield-scan.sh <new private output directory> [branch]}"
branch="${2:-main}"
repo=colvenna/colvenna.github.io
gg="${GGSHIELD:-ggshield}"
mkdir -m 700 "$out"
export GIT_TERMINAL_PROMPT=0 # anonymous: never prompt, use no stored credential
anon=(git -c credential.helper=)
want="$(sed -n 's/^ggshield==\([^ ]*\) .*/\1/p' "$(dirname "$0")/ggshield-requirements.lock")"
have="$("$gg" --version 2>/dev/null | sed -n 's/^ggshield, version //p' || true)"
if [[ "$have" != "$want" ]]; then # the completeness checks read this version's messages
  echo "the scan needs ggshield $want, installed from scripts/ggshield-requirements.lock (found: ${have:-none})" >&2
  exit 2
fi
python="$(dirname "$(readlink -f "$(command -v "$gg")")")/python3" # ggshield's own environment
# ggshield 1.56.1 always applies its default exclusions (vendor/, node_modules/, .venv/, *.mdx, *.sops, ...)
# and says nothing about them; --ignore-default-excludes has no effect. excluded prints each NUL-separated
# path on stdin that they match, with ggshield's own matcher.
excluded() {
  "$python" -c '
import sys
from ggshield.cmd.secret.scan.secret_scan_common_options import IGNORED_DEFAULT_WILDCARDS
from ggshield.core.filter import init_exclusion_regexes
from ggshield.utils.files import is_path_excluded
regexes = init_exclusion_regexes(set(IGNORED_DEFAULT_WILDCARDS))
for path in sorted({path.strip("\n") for path in sys.stdin.read().split("\0")} - {""}):
    if is_path_excluded(path, regexes):
        print(path)'
}
# Its path scans match the exclusions against the absolute path: refuse an output directory under one.
if [[ -n "$(printf '%s\0' "$(readlink -f "$out")/probe/file.txt" | excluded)" ]]; then
  echo "$out is under a path ggshield's default exclusions skip (such as vendor/ or .venv/)" >&2; exit 2
fi
quota() { "$gg" quota 2>/dev/null | head -1 || echo unavailable; }
quota_before="$(quota)"

"${anon[@]}" clone --quiet --mirror "https://github.com/$repo.git" "$out/mirror.git"
git -C "$out/mirror.git" remote set-url --push origin no-push://read-only
# shellcheck disable=SC2016 # GraphQL variables, not shell ones
gh api graphql --paginate -F owner="${repo%/*}" -F name="${repo#*/}" -f query='
  query($owner: String!, $name: String!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequests(first: 50, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { timelineItems(first: 100, itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT]) {
          nodes { ... on HeadRefForcePushedEvent { beforeCommit { oid } } } } } } } }' \
  --jq '.data.repository.pullRequests.nodes[].timelineItems.nodes[].beforeCommit.oid // empty' \
  | sort -u > "$out/force-pushed-heads.txt"
fetched=0 reachable=0 missing=0
while read -r sha; do
  if git -C "$out/mirror.git" cat-file -e "$sha^{commit}" 2>/dev/null; then reachable=$((reachable + 1))
  elif "${anon[@]}" -C "$out/mirror.git" fetch --quiet origin "$sha:refs/force-pushed/$sha" 2>/dev/null; then
    fetched=$((fetched + 1))
  else missing=$((missing + 1)); fi
done < "$out/force-pushed-heads.txt"

head_sha="$(git -C "$out/mirror.git" rev-parse --verify --quiet "refs/heads/$branch")" \
  || { echo "the repository has no branch $branch" >&2; exit 2; }
git -C "$out/mirror.git" show "$head_sha:.gitguardian.yaml" > "$out/gitguardian.yaml" 2>/dev/null \
  || { echo "$branch has no .gitguardian.yaml: the scan uses the repository's own configuration" >&2; exit 2; }

# GitHub text, one file per document: {name, text} objects, one a line.
mkdir "$out/github-text"
{
  gh api --paginate "repos/$repo/issues?state=all&per_page=100" --jq '.[] | {name: "\(if .pull_request
    then "pull" else "issue" end)-\(.number).md", text: "\(.title)\n\n\(.body // "")"}'
  gh api --paginate "repos/$repo/issues/comments?per_page=100" --jq '.[] | {name: "comment-\(.id).md", text: (.body // "")}'
  gh api --paginate "repos/$repo/pulls/comments?per_page=100" \
    --jq '.[] | {name: "review-comment-\(.id).md", text: "\(.diff_hunk // "")\n\n\(.body // "")"}'
  gh api --paginate "repos/$repo/releases?per_page=100" \
    --jq '.[] | {name: "release-\(.tag_name).md", text: "\(.name // "")\n\n\(.body // "")"}'
  gh api --paginate "repos/$repo/comments?per_page=100" --jq '.[] | {name: "commit-comment-\(.id).md", text: (.body // "")}'
  pulls="$(gh api --paginate "repos/$repo/pulls?state=all&per_page=100" --jq '.[].number')" # fails the script
  for number in $pulls; do
    gh api --paginate "repos/$repo/pulls/$number/reviews?per_page=100" \
      --jq ".[] | select(.body != \"\") | {name: \"pull-$number-review-\(.id).md\", text: .body}"
  done
} > "$out/github-text.jsonl"
documents="$(python3 -c 'import json, pathlib, sys
lines = open(sys.argv[1]).read().splitlines()
for line in lines:
    document = json.loads(line)
    pathlib.Path(sys.argv[2], document["name"]).write_text(document["text"])
print(len(lines))' "$out/github-text.jsonl" "$out/github-text")"

status=0
"$gg" --config-path "$out/gitguardian.yaml" secret scan repo "$out/mirror.git" --json \
  > "$out/history.json" 2> "$out/history.stderr" || status=$?
scopes=("history:$status")
has_wiki="$(gh api "repos/$repo" --jq .has_wiki)" # fails the script, rather than skipping the wiki
if [[ "$has_wiki" == true ]]; then
  "${anon[@]}" clone --quiet --mirror "https://github.com/$repo.wiki.git" "$out/wiki.git" 2>/dev/null || {
    echo "the wiki is enabled but has no clone to scan: disable it, or add a page and scan again" >&2; exit 2; }
  wiki_status=0
  "$gg" --config-path "$out/gitguardian.yaml" secret scan repo "$out/wiki.git" --json \
    > "$out/wiki.json" 2> "$out/wiki.stderr" || wiki_status=$?
  scopes+=("wiki:$wiki_status")
fi
text_status=0
"$gg" --config-path "$out/gitguardian.yaml" secret scan path --recursive --yes "$out/github-text" --json \
  > "$out/github-text.json" 2> "$out/github-text.stderr" || text_status=$?

# The paths of each history that ggshield's default exclusions skip, unquoted (core.quotePath=false), so
# that a non-ASCII path is matched as ggshield sees it; the summary fails on any.
for scope in "${scopes[@]%%:*}"; do
  clone="$out/mirror.git"; [[ "$scope" == wiki ]] && clone="$out/wiki.git"
  git -C "$clone" -c core.quotePath=false log -z --all --format= --name-only | excluded > "$out/$scope.unscanned"
done
refs="$(git -C "$out/mirror.git" for-each-ref --format='%(refname)')"
{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repository: $repo; configuration: .gitguardian.yaml of $branch $head_sha"
  echo "ggshield: $("$gg" --version)"
  echo "quota before: $quota_before"
  echo "refs: $(grep -c '^refs/heads/' <<< "$refs") branches, $(grep -c '^refs/tags/' <<< "$refs") tags," \
    "$(grep -c '^refs/pull/' <<< "$refs") refs/pull; $(git -C "$out/mirror.git" rev-list --all --count) commits;" \
    "force-pushed heads: $fetched fetched, $reachable still reachable, $missing not served"
  echo "GitHub text: $documents documents"
  echo "quota after: $(quota)"
  # A scan is clean when ggshield exits 0, reports no incident and no error, says nothing failed, and
  # skips nothing but binary files (which it cannot decode). Findings are located, never shown.
  python3 - "$out" "${scopes[@]}" "github-text:$text_status" <<'PY'
import json, sys
from pathlib import Path
out, clean = Path(sys.argv[1]), True
def errors(report):
    return bool(report.get("errors")) or any(errors(inner) for inner in report.get("scans") or [])
for argument in sys.argv[2:]:
    scope, returncode = argument.rsplit(":", 1)
    try:
        report = json.loads((out / f"{scope}.json").read_text())
    except json.JSONDecodeError:
        report = {}
    stderr = (out / f"{scope}.stderr").read_text()
    if returncode not in ("0", "1") or "total_incidents" not in report:
        print(f"{scope}: ggshield exited {returncode}")
        clean = False
        continue
    if errors(report) or "Scanning failed" in stderr:
        print(f"{scope}: incomplete, ggshield reported a failed scan (see its report)")
        clean = False
    print(f"{scope}: {report['total_incidents']} incidents")
    clean = clean and returncode == "0" and report["total_incidents"] == 0
    for line in stderr.splitlines():
        if line.startswith("Skipped ") and not line.endswith(": can't detect encoding"):
            print(f"  - not scanned: {line[len('Skipped '):].split('/')[-1]}")
            clean = False
    unscanned = out / f"{scope}.unscanned"
    for path in unscanned.read_text().split() if unscanned.exists() else []:
        print(f"  - not scanned: {path} (ggshield's default exclusions)")
        clean = False
    for commit in report.get("scans") or [report]:
        where = f"commit {commit['id'][:12]}, " if "scans" in report else ""
        for entity in commit.get("entities_with_incidents") or []:
            for found in entity["incidents"]:
                line = found["occurrences"][0]["line_start"] if found["occurrences"] else "?"
                print(f"  - {found['type']}, {where}{Path(entity['filename']).name}:{line}, "
                      f"ignore_sha {found['ignore_sha']}")
print("VERDICT: CLEAN" if clean else "VERDICT: FINDINGS")
sys.exit(0 if clean else 1)
PY
} | tee "$out/summary.txt"
grep -qx "VERDICT: CLEAN" "$out/summary.txt"
