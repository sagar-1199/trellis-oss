#!/usr/bin/env bash
# Trellis test — check out a task's PR branch and run the app locally so you can
# click through the change before merging. Uses an isolated worktree so your real
# checkout (and any uncommitted work) is never touched.
#
#   trellis test [repo-keyword] [branch]
#     no args        -> the most recently built repo + its branch (from metrics)
#     repo-keyword   -> that project; its trellis/* branch if there's exactly one
#     repo + branch  -> exact branch to run
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
cd "$TRELLIS_DIR"
frontmatter(){ awk -v k="$1" '/^---[[:space:]]*$/{n++;next} n==1&&$0~"^"k":"{sub("^"k":[[:space:]]*","");gsub(/^"|"$/,"");print;exit}' "$2"; }

kw="${1:-}"; want_branch="${2:-}"

# --- resolve repo ---
if [ -z "$kw" ]; then
  slug="$(python3 - <<'PY'
import json,os
p="loop/metrics.jsonl"
last=None
for ln in open(p):
    try: r=json.loads(ln)
    except: continue
    if r.get("outcome")=="pass": last=r
print(last["repo"] if last else "")
PY
)"
  [ -z "$slug" ] && { echo "No recently-built repo found. Try: trellis test <project>"; exit 1; }
else
  all="$(cd projects && ls *.md 2>/dev/null | sed 's/\.md$//')"
  matches="$(printf '%s\n' "$all" | grep -i "$kw")"                 # kw inside a slug
  if [ -z "$matches" ]; then                                        # slug inside kw (branch pasted)
    matches="$(printf '%s\n' "$all" | while read -r a; do case "$kw" in *"$a"*) echo "$a";; esac; done)"
  fi
  n="$(printf '%s\n' "$matches" | grep -c .)"
  if [ "$n" -gt 1 ]; then          # if a branch was pasted, prefer the longest matching slug
    matches="$(printf '%s\n' "$matches" | awk '{print length, $0}' | sort -rn | head -1 | cut -d" " -f2-)"
    n=1
  fi
  [ "$n" = 0 ] && { echo "No project matches '$kw'. Try just the project name, e.g. my-app"; exit 1; }
  slug="$matches"
  # if the keyword looked like a full branch, use it directly
  case "$kw" in trellis/*) want_branch="${want_branch:-$kw}";; esac
fi
page="projects/$slug.md"; path="$(frontmatter path "$page")"
[ -d "$path" ] || { echo "Repo path not found for $slug ($path)"; exit 1; }

# --- resolve branch ---
if [ -z "$want_branch" ]; then
  branches="$(git -C "$path" for-each-ref --format='%(refname:short)' 'refs/heads/trellis/*')"
  bn="$(printf '%s\n' "$branches" | grep -c .)"
  if   [ "$bn" = 0 ]; then echo "No trellis/* branch in $slug to test yet. Build one with: trellis run"; exit 1
  elif [ "$bn" = 1 ]; then want_branch="$branches"
  else
    echo "This project has $bn built branches — pick one:"
    i=0; while IFS= read -r b; do i=$((i+1)); printf "  %d) %s\n" "$i" "$b"; done <<EOF
$branches
EOF
    printf "Number: "; read -r bpick
    want_branch="$(printf '%s\n' "$branches" | sed -n "${bpick}p")"
    [ -z "$want_branch" ] && { echo "(nothing picked)"; exit 1; }
  fi
fi
echo "Testing:  $slug  @  $want_branch"

# --- isolated preview worktree ---
wt="$TRELLIS_DIR/loop/runs/preview-$slug"
git -C "$path" worktree remove --force "$wt" 2>/dev/null; git -C "$path" worktree prune
git -C "$path" worktree add --force "$wt" "$want_branch" >/dev/null 2>&1 \
  || { echo "Could not create preview worktree for $want_branch"; exit 1; }
for e in .env .env.local .env.development .env.development.local; do
  [ -f "$path/$e" ] && cp "$path/$e" "$wt/$e" 2>/dev/null; done

RUN="$(frontmatter run "$page")"          # optional explicit run recipe on the page
DEV="${RUN:-}"
echo
echo "Preview checkout:  $wt"
echo "Your real checkout at '$path' is untouched."
echo
cat <<EOF
Next steps to see it running:
  cd "$wt"
EOF
# Node projects: install + hand over the dev command
if [ -f "$wt/package.json" ]; then
  echo "  nvm use 24 2>/dev/null; pnpm install       # deps (first time ~2-3 min)"
  [ -f "$wt/Gemfile" ] && echo "  bundle install && bin/rails db:migrate     # backend deps + DB"
  if [ -n "$DEV" ]; then echo "  $DEV"
  else echo "  NODE_OPTIONS=--max-old-space-size=4096 npm run dev   # bigger heap or vite OOMs; open the URL it prints"; fi
fi
echo
printf "Start it now for you? [y/N] "; read -r go
if [ "$go" = y ] || [ "$go" = Y ]; then
  cd "$wt"
  command -v nvm >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  echo ">> installing deps..."; pnpm install || npm install
  [ -f Gemfile ] && { echo ">> bundle + migrate..."; bundle install >/dev/null 2>&1; bin/rails db:migrate 2>/dev/null || true; }
  echo ">> starting the app (Ctrl-C to stop)..."
  export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}"   # vite build OOMs at Node's 2GB default
  eval "${DEV:-npm run dev}"
else
  echo "When you're done: trellis test-clean $slug   (removes the preview checkout)"
fi
