#!/usr/bin/env bash
# Raise the PR for an already-built, already-committed branch. Used by:
#   - the loop when AUTO_PR=1
#   - `trellis review` when you approve a held branch
# Pushes the base if it's local-only, pushes the branch (husky pre-push only
# blocks master/develop, so trellis/* is fine), then opens the PR.
#   raise_pr <repo_path> <branch> <base> <title> <prbody_file>  -> prints PR url
raise_pr() {
  local path="$1" branch="$2" base="$3" title="$4" prbody="$5" log="${6:-/dev/null}" url=""
  git -C "$path" remote get-url origin >/dev/null 2>&1 || { echo "  [warn] no origin remote; branch kept: $branch"; return 1; }
  # base must exist on origin to be a PR target
  git -C "$path" ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1 || \
    git -C "$path" push -q origin "$base:$base" 2>>"$log" || true
  if git -C "$path" push -q -u origin "$branch" 2>>"$log"; then
    url="$( cd "$path" && gh pr create --head "$branch" --base "$base" --title "$title" --body-file "$prbody" 2>>"$log" )"
    if [ -n "$url" ]; then echo "$url"; return 0
    else echo "  [warn] pushed $branch but gh pr create failed (see $log)"; return 2; fi
  else echo "  [warn] push failed for $branch (see $log)"; return 3; fi
}
