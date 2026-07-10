#!/usr/bin/env bash
# Trellis autonomous loop v2 — agent-agnostic dispatcher with QA.
# bash 3.2 compatible (macOS default): no mapfile, no fancy unicode, no empty-array deref.
#
# Per task: fresh worktree -> install deps -> implement (fresh agent) -> guardrails ->
# verify gate -> test-tamper check -> adversarial reviewer -> (fix-retry) -> branch+PR.
# Safe by default: DRY_RUN=1 previews without touching anything.
#
#   ./loop.sh                          # preview next task (no changes)
#   DRY_RUN=0 ./loop.sh                # run for real
#   DRY_RUN=0 AGENT=claude QA_AGENT=codex ./loop.sh   # cross-engine review (recommended)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
cd "$TRELLIS_DIR"
mkdir -p "$RUN_DIR"
export JIT_HISTORY   # build_prompt.sh reads this to include the repo's history digest

# JIT context: refresh conversation history before a real run so tasks get fresh context.
if [ "$JIT_HARVEST" = 1 ] && [ "$DRY_RUN" = 0 ] && command -v python3 >/dev/null 2>&1 && [ -f "$DIR/harvest.py" ]; then
  echo "Refreshing conversation history (harvest)..."
  python3 "$DIR/harvest.py" >/dev/null 2>&1 || echo "  (harvest skipped/failed — using existing digests)"
fi

# ---- helpers --------------------------------------------------------------
metrics_file="$TRELLIS_DIR/loop/metrics.jsonl"
json_str(){ printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
record_metric(){ # $1 outcome  $2 attempts  $3 pr_url  $4 reason
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","repo":"%s","id":"%s","title":%s,"trust":"%s","outcome":"%s","attempts":%s,"pr_url":"%s","reason":%s}\n' \
    "$ts" "$repo" "$id" "$(json_str "$title")" "$trust" "$1" "${2:-0}" "${3:-}" "$(json_str "${4:-}")" >> "$metrics_file"
}
bud(){ mkdir -p "$HOME/.trellis" 2>/dev/null; printf '%s\n' "$*" > "$HOME/.trellis/status" 2>/dev/null; }  # feeds the Dock buddy
frontmatter() { awk -v k="$1" '/^---[[:space:]]*$/{n++; next} n==1 && $0 ~ "^"k":"{sub("^"k":[[:space:]]*",""); gsub(/^"|"$/,""); print; exit}' "$2"; }

parse_backlog() {   # -> pri \t repo \t title \t verify \t accept \t notes \t setup
  local f="$TRELLIS_DIR/backlog.md" line
  local pri repo title verify accept notes setup started=0 incmt=0 infence=0
  flush(){ [ "$started" = 1 ] && [ -n "$repo" ] && printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$pri" "$repo" "$title" "$verify" "$accept" "$notes" "$setup"; }
  while IFS= read -r line; do
    case "$line" in '```'*) [ "$infence" = 1 ] && infence=0 || infence=1; continue;; esac
    [ "$infence" = 1 ] && continue
    case "$line" in *'<!--'*) incmt=1;; esac
    if [ "$incmt" = 1 ]; then case "$line" in *'-->'*) incmt=0;; esac; continue; fi
    if [[ $line =~ ^-\ \[\ \]\  ]]; then
      flush; pri=999 repo="" title="" verify="" accept="" notes="" setup="" started=1
      [[ $line =~ \(priority::\ *([0-9]+)\) ]] && pri="${BASH_REMATCH[1]}"
      [[ $line =~ \(repo::\ *([^\)]+)\) ]] && repo="$(echo "${BASH_REMATCH[1]}" | tr -d ' ')"
      title="$(printf '%s' "${line#- \[ \] }" | sed -E 's/\([a-z]+:: *[^)]*\)//g; s/^ *//; s/ *$//')"
    elif [[ $line =~ ^-\ \[.\]\  ]]; then
      flush; started=0   # [x] done or [!] blocked -> skip
    elif [[ $started == 1 && $line =~ ^[[:space:]]+-\ ([a-z]+)::\ ?(.*)$ ]]; then
      case "${BASH_REMATCH[1]}" in
        verify) verify="${BASH_REMATCH[2]}";; accept) accept="${BASH_REMATCH[2]}";;
        notes) notes="${BASH_REMATCH[2]}";; setup) setup="${BASH_REMATCH[2]}";;
      esac
    fi
  done < "$f"; flush
}

set_box() {  # $1 repo  $2 title  $3 newbox (x or !)
  local f="$TRELLIS_DIR/backlog.md" tmp; tmp="$(mktemp)"
  awk -v repo="$1" -v title="$2" -v b="$3" '
    /^- \[ \] / && index($0,"(repo:: "repo")")>0 && index($0,title)>0 && d==0 { sub(/^- \[ \]/,"- ["b"]"); d=1 }
    { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}
slugify() { echo "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed -E 's/-+/-/g; s/^-|-$//g' | cut -c1-40; }

prep_worktree() {  # $1 worktree  $2 source-repo  — copy env + install deps
  local wt="$1" src="$2" e
  for e in .env .env.local .env.development.local; do [ -f "$src/$e" ] && cp "$src/$e" "$wt/$e" 2>/dev/null; done
  if [ -n "${T_SETUP:-}" ]; then ( cd "$wt" && eval "$T_SETUP" ); return $?; fi
  if   [ -f "$wt/pnpm-lock.yaml" ];    then ( cd "$wt" && pnpm install --frozen-lockfile --config.confirmModulesPurge=false )
  elif [ -f "$wt/package-lock.json" ]; then ( cd "$wt" && npm ci )
  elif [ -f "$wt/yarn.lock" ];         then ( cd "$wt" && yarn install --immutable )
  elif [ -f "$wt/package.json" ];      then ( cd "$wt" && npm install --no-audit --no-fund )
  else return 0; fi
}

# ---- main -----------------------------------------------------------------
echo "Trellis loop v2 | AGENT=$AGENT | QA=$QA (reviewer=$QA_AGENT) | DRY_RUN=$DRY_RUN | max tasks=$MAX_ITERATIONS"
iter=0
while [ "$iter" -lt "$MAX_ITERATIONS" ]; do
  task="$(parse_backlog | sort -t"$(printf '\t')" -k1,1n | head -1)"
  [ -z "$task" ] && { echo "Backlog empty - nothing pending. Done."; break; }
  IFS=$'\x1f' read -r pri repo title verify accept notes T_SETUP <<<"$task"   # \x1f: non-whitespace, empty fields survive
  iter=$((iter+1))
  echo; echo "=== task $iter/$MAX_ITERATIONS :: [$repo] $title (priority $pri) ==="; bud "$repo: $title"

  page="$TRELLIS_DIR/projects/$repo.md"
  [ -f "$page" ] || { echo "  [skip] no projects/$repo.md"; set_box "$repo" "$title" "!"; continue; }
  path="$(frontmatter path "$page")"; trust="$(frontmatter trust "$page")"
  [ -z "$verify" ] && verify="$(frontmatter verify "$page")"
  [ -z "${T_SETUP:-}" ] && T_SETUP="$(frontmatter setup "$page")"
  id="$(slugify "$repo-$title")"; branch="trellis/$id"

  if [ "$REQUIRE_SPEC" = 1 ] && [ ! -f "$TRELLIS_DIR/specs/$id.md" ]; then
    echo "  [needs-clarify] top task '$title' has no spec yet."
    echo "$id" > "$RUN_DIR/.needs_plan"   # signal to the 'trellis run' wrapper
    exit 10
  fi

  [ -n "$path" ] && [ -d "$path" ] || { echo "  [skip] path missing: '$path'"; set_box "$repo" "$title" "!"; continue; }
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || { echo "  [skip] not a git repo"; set_box "$repo" "$title" "!"; continue; }
  [ -z "$verify" ] && { echo "  [skip] no verify gate for $repo (deepen the project page first)"; set_box "$repo" "$title" "!"; continue; }
  has_remote=1; git -C "$path" remote get-url origin >/dev/null 2>&1 || has_remote=0
  base="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || echo main)"

  export T_ID="$id" T_REPO="$repo" T_TRUST="$trust" T_BRANCH="$branch" T_VERIFY="$verify" T_TITLE="$title" T_ACCEPT="$accept" T_NOTES="$notes"

  if [ "$DRY_RUN" = 1 ]; then
    echo "  [DRY_RUN] path=$path trust=$trust base=$base remote=$has_remote setup='${T_SETUP:-auto}'"
    echo "  [DRY_RUN] verify: $verify"
    echo "  [DRY_RUN] flow: worktree -> install -> implement -> gate -> tamper-check -> reviewer($QA_AGENT) -> PR"
    echo "  [DRY_RUN] no changes made. Set DRY_RUN=0 to run. Stopping after preview."; break
  fi

  # --- isolate (branch from the LATEST remote base so the PR is clean, no conflicts) ---
  base_ref="$base"
  if [ "$has_remote" = 1 ]; then
    if git -C "$path" fetch --quiet origin "$base" 2>>"$RUN_DIR/prep-$id.log" \
       && git -C "$path" rev-parse --verify -q "origin/$base" >/dev/null 2>&1; then
      base_ref="origin/$base"; bud "$repo: syncing base ($base)"
      echo "  -> synced base '$base' from origin; branching from origin/$base (conflict-free PR)"
    else
      echo "  [warn] couldn't fetch origin/$base; branching from local '$base' (PR may show extra diff)"
    fi
  fi
  wt="$RUN_DIR/wt-$id"; git -C "$path" worktree remove --force "$wt" 2>/dev/null; rm -rf "$wt"; git -C "$path" worktree prune
  git -C "$path" worktree add -B "$branch" "$wt" "$base_ref" >/dev/null 2>&1 || { echo "  [skip] worktree add failed"; continue; }
  export T_WORKTREE="$wt"
  export T_PRBODY_FILE="$RUN_DIR/prbody-$id.md"; rm -f "$T_PRBODY_FILE"
  echo "  -> preparing worktree (install deps, copy env)..."
  if ! prep_worktree "$wt" "$path" >"$RUN_DIR/prep-$id.log" 2>&1; then
    echo "  [warn] dependency install failed (see prep-$id.log); gate may not run"
  fi

  # --- attempt loop ---
  feedback=""; last_hash=""; outcome="give-up"; attempt=0
  while [ "$attempt" -lt "$MAX_FIX_ATTEMPTS" ]; do
    attempt=$((attempt+1))
    echo "  --- attempt $attempt/$MAX_FIX_ATTEMPTS ---"
    export T_FEEDBACK="$feedback"
    "$DIR/build_prompt.sh" > "$RUN_DIR/prompt-$id.md"
    echo "    running ${AGENT}..."; bud "$repo: building (try $attempt)"
    WORKDIR="$wt" run_agent < "$RUN_DIR/prompt-$id.md" > "$RUN_DIR/out-$id-$attempt.log" 2>&1 || true

    # guardrail: off-limits paths + diff size (no arrays — bash 3.2 safe)
    changed_list="$(git -C "$wt" status --porcelain | cut -c4-)"
    nfiles="$(printf '%s\n' "$changed_list" | grep -c . || true)"
    bad="$(printf '%s\n' "$changed_list" | grep -Ei "$DENYLIST_RE" || true)"
    if [ -n "$bad" ]; then echo "    [x] off-limits path touched - abort:"; printf '%s\n' "$bad" | sed 's/^/        /'; outcome="denylist"; break; fi
    nlines="$(git -C "$wt" diff --numstat 2>/dev/null | awk '$3 !~ /(package-lock\.json|pnpm-lock\.yaml|yarn\.lock)$/ {a+=$1+0; d+=$2+0} END{print a+d}')"
    if [ "${nfiles:-0}" -gt "$MAX_DIFF_FILES" ] || [ "${nlines:-0}" -gt "$MAX_DIFF_LINES" ]; then
      echo "    [x] diff too large (${nfiles:-0} files / ${nlines:-0} lines) - abort"; outcome="too-big"; break; fi
    if [ "${nfiles:-0}" -eq 0 ]; then feedback="You made no changes. Implement the task."; continue; fi

    # stuck detection
    h="$(git -C "$wt" diff | shasum | awk '{print $1}')"
    if [ "$h" = "$last_hash" ]; then echo "    [x] no change since last attempt (stuck) - escalate"; outcome="stuck"; break; fi
    last_hash="$h"

    # test-tamper check (anti reward-hacking)
    tamper="$(git -C "$wt" diff --name-status | awk '$1 ~ /^[MD]/ {print $2}' | grep -Ei "$TESTFILE_RE" || true)"
    if [ -n "$tamper" ]; then
      echo "    [x] existing tests modified/deleted - reject:"; printf '%s\n' "$tamper" | sed 's/^/        /'
      feedback="You modified/deleted existing test files: $(printf '%s' "$tamper" | tr '\n' ' '). Do NOT change existing tests to pass. Revert them and fix the real code (or set EXIT_SIGNAL false if impossible)."; continue; fi

    # verify gate
    echo "    verify: $verify"; bud "$repo: running checks"
    if ! ( cd "$wt" && eval "$verify" ) >"$RUN_DIR/verify-$id.log" 2>&1; then
      echo "    [x] verify failed (see verify-$id.log)"
      feedback="The verify command failed: \`$verify\`. Output (tail):
$(tail -25 "$RUN_DIR/verify-$id.log")
Fix the root cause; do not suppress the error or weaken the check."; continue; fi
    echo "    [ok] verify passed"

    # QA reviewer (fail-closed)
    if [ "$QA" = 1 ]; then
      git -C "$wt" add -A; git -C "$wt" commit -q -m "wip($repo): $id attempt $attempt" || true
      git -C "$wt" diff "$base"..HEAD > "$RUN_DIR/diff-$id.txt" 2>/dev/null
      export T_DIFF_FILE="$RUN_DIR/diff-$id.txt" T_VERIFY_LOG="$RUN_DIR/verify-$id.log"
      echo "    reviewing with ${QA_AGENT}..."; bud "$repo: reviewing"
      "$DIR/build_qa_prompt.sh" > "$RUN_DIR/qa-prompt-$id.md"
      WORKDIR="$wt" run_reviewer < "$RUN_DIR/qa-prompt-$id.md" > "$RUN_DIR/qa-out-$id-$attempt.log" 2>&1 || true
      git -C "$wt" reset --hard -q HEAD   # discard any stray reviewer edits
      verdict="$(grep -Eo 'QA_VERDICT: *(PASS|FAIL)' "$RUN_DIR/qa-out-$id-$attempt.log" | grep -Eo 'PASS|FAIL' | head -1)"
      if [ "$verdict" = PASS ]; then echo "    [ok] reviewer: PASS"; outcome="pass"; break; fi
      echo "    [x] reviewer: ${verdict:-UNPARSEABLE=fail}"
      feedback="An adversarial reviewer REJECTED your change. Blocking findings:
$(sed -n '/QA_BLOCKING:/,/QA_STYLE:/p' "$RUN_DIR/qa-out-$id-$attempt.log" | grep -E '^- ' || echo '- (see review)')
Address every blocking finding. Keep the diff tight and in-scope."
      git -C "$wt" reset -q "$base"   # uncommit wip, keep changes for the fixer
      continue
    else
      outcome="pass"; break
    fi
  done

  # --- act on outcome ---
  if [ "$outcome" = pass ]; then
    pr_url=""
    git -C "$wt" add -A; git -C "$wt" commit -q -m "trellis($repo): $title" || true
    # Assemble an experienced-dev PR body: the agent's write-up + auto diffstat + footer.
    mkdir -p "$TRELLIS_DIR/loop/pending"
    prfinal="$TRELLIS_DIR/loop/pending/$id-body.md"
    {
      if [ -s "$T_PRBODY_FILE" ]; then cat "$T_PRBODY_FILE"
      else echo "## Summary"; echo "$title"; echo; echo "## Acceptance"; echo "$accept"; fi
      echo; echo "## Files changed"; echo '```'
      git -C "$wt" diff "$base"..HEAD --stat; echo '```'
      echo; echo "## Verification"; echo "- \`$verify\` — passed"
      [ "$QA" = 1 ] && echo "- Adversarial reviewer — passed"
      echo; echo "---"
      echo "🤖 Generated by Trellis (autonomous loop) on \`$branch\` — verify + adversarial review passed; human merge required."
    } > "$prfinal"
    if [ "$AUTO_PR" = 1 ] && [ "$has_remote" = 1 ]; then
      # AUTO_PR=1: raise the PR straight away (old behavior)
      source "$DIR/raise_pr.sh"
      pr_url="$(raise_pr "$path" "$branch" "$base" "$title" "$prfinal" "$RUN_DIR/push-$id.log" | tail -1)"
      case "$pr_url" in https://*) bud "$repo: PR opened"; echo "  [OK] PR opened: $pr_url";; *) echo "$pr_url"; pr_url="";; esac
    elif [ "$has_remote" = 1 ]; then
      # DEFAULT: HOLD for your QA — commit is on branch '$branch', nothing pushed yet.
      cat > "$TRELLIS_DIR/loop/pending/$id.env" <<EOF
REPO="$repo"
RPATH="$path"
BRANCH="$branch"
BASE="$base"
TITLE="$title"
BODY="$prfinal"
VERIFY="$verify"
TS="$(date -u +%FT%TZ 2>/dev/null || date +%FT%TZ)"
EOF
      set_box "$repo" "$title" "?"; bud "$repo: awaiting your review"
      echo "  [review] built + verified + reviewed on branch '$branch' — awaiting your QA."
      echo "           test it:   trellis test $repo"
      echo "           approve:   trellis review   (opens the PR once you pass it)"
    else echo "  [OK] no remote - commit left on local branch $branch (PR body: $prfinal)"; fi
    [ -n "$pr_url" ] && set_box "$repo" "$title" "x"
    git -C "$TRELLIS_DIR" add -A 2>/dev/null && git -C "$TRELLIS_DIR" commit -q -m "trellis: learnings from $repo/$id" 2>/dev/null || true
    record_metric "pass" "$attempt" "${pr_url:-}" "$([ -z "$pr_url" ] && echo 'pending-review')"
    echo "  [done] $title"
  else
    echo "  [escalate] task NOT completed ($outcome) after $attempt attempt(s) - leaving for human."
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      git -C "$wt" add -A 2>/dev/null
      git -C "$wt" -c user.name='Trellis' -c user.email='trellis@local' \
        commit -q -m "WIP (escalated): $title" 2>/dev/null || true
      echo "    work-in-progress committed to $branch (nothing lost)"
    fi
    { echo "Task: $title"; echo "Repo: $repo  Branch: $branch  Outcome: $outcome"; echo; echo "Last feedback:"; echo "$feedback"; } > "$RUN_DIR/ESCALATED-$id.md"
    echo "    notes: $RUN_DIR/ESCALATED-$id.md ; branch kept: $branch"
    set_box "$repo" "$title" "!"
    record_metric "escalated" "$attempt" "" "$outcome: $(printf '%s' "$feedback" | tr '\n' ' ' | cut -c1-400)"
  fi
  git -C "$path" worktree remove --force "$wt" 2>/dev/null; git -C "$path" worktree prune
  sleep "$ITER_SLEEP"
done
echo; bud "idle"; echo "Loop finished after $iter task(s)."
