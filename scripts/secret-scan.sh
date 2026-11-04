#!/usr/bin/env bash
# Publication secret scan with ggshield (GitGuardian's CLI), required before anything here is made public
# (README.md#secret-scanning). It scans what the public can fetch: an anonymous `git clone --mirror`
# (every branch, tag and refs/pull/*), plus each pull-request head a force push replaced that GitHub
# still serves by its SHA, with the .gitguardian.yaml of the scanned branch. The website is the
# repository's content, so the history covers it. The report with matched values stays in the output
# directory (keep it private); the summary holds none. Exit 0 only when ggshield finds 0 incidents.
#
# usage: scripts/secret-scan.sh <new private output directory> [branch, default main]
# needs: git, gh (authenticated, for the force-push events), python3, ggshield (or GGSHIELD=<path>)
set -euo pipefail
out="${1:?usage: scripts/secret-scan.sh <new private output directory> [branch]}"
branch="${2:-main}"
repo=colvenna/colvenna.github.io
gg="${GGSHIELD:-ggshield}"
mkdir -m 700 "$out"
export GIT_TERMINAL_PROMPT=0 # anonymous: never prompt, use no stored credential
anon=(git -c credential.helper=)

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

head_sha="$(git -C "$out/mirror.git" rev-parse "refs/heads/$branch")"
git -C "$out/mirror.git" show "refs/heads/$branch:.gitguardian.yaml" > "$out/gitguardian.yaml" \
  || { echo "$branch has no .gitguardian.yaml: the scan uses the repository's own configuration" >&2; exit 2; }
status=0
"$gg" --config-path "$out/gitguardian.yaml" secret scan repo "$out/mirror.git" --json \
  > "$out/history.json" 2> "$out/history.stderr" || status=$?
incidents="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("total_incidents", "?"))' \
  "$out/history.json" 2>/dev/null || echo "?")"
refs="$(git -C "$out/mirror.git" for-each-ref --format='%(refname)')"
{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repository: $repo; configuration: .gitguardian.yaml of $branch $head_sha"
  echo "ggshield: $("$gg" --version)"
  echo "refs: $(grep -c '^refs/heads/' <<< "$refs") branches, $(grep -c '^refs/tags/' <<< "$refs") tags," \
    "$(grep -c '^refs/pull/' <<< "$refs") refs/pull; force-pushed heads: $fetched fetched," \
    "$reachable still reachable, $missing not served;" \
    "$(git -C "$out/mirror.git" rev-list --all --count) commits"
  echo "history: $incidents incidents (ggshield exit $status)"
  if [[ "$status" == 0 && "$incidents" == 0 ]]; then echo "VERDICT: CLEAN"; else echo "VERDICT: FINDINGS"; fi
} | tee "$out/summary.txt"
[[ "$status" == 0 && "$incidents" == 0 ]]
