#!/usr/bin/env bash
# Trellis loop config — the ONLY agent-specific file. Swap engines with no other
# change:  AGENT=claude ./loop.sh   |   AGENT=codex ./loop.sh
#
# Overridable from the environment, e.g.
#   DRY_RUN=0 MAX_ITERATIONS=3 QA=1 ./loop.sh

: "${AGENT:=claude}"                 # implementer engine: claude | codex
: "${QA:=1}"                         # 1 = run the adversarial reviewer gate before PR
: "${QA_AGENT:=$AGENT}"              # reviewer engine. BEST PRACTICE: use a DIFFERENT
                                     #   engine than AGENT (self-preference bias). e.g.
                                     #   AGENT=claude QA_AGENT=codex ./loop.sh
: "${TRELLIS_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${RUN_DIR:=$TRELLIS_DIR/loop/runs}"
: "${MAX_ITERATIONS:=10}"            # outer cap: tasks per invocation (cost guard)
: "${MAX_FIX_ATTEMPTS:=3}"           # implement→gate→QA tries per task before escalating
: "${MAX_DIFF_FILES:=40}"            # reject runaway diffs (file count)
: "${MAX_DIFF_LINES:=600}"           # reject runaway diffs (changed lines) — scope guard
: "${DRY_RUN:=1}"                    # 1 = preview only (no agent, no git). Set 0 to run.
: "${AUTO_PR:=0}"                    # 0 = HOLD for your QA (default): build+verify+review,
                                     #   commit the branch, then wait — you review with
                                     #   `trellis review` and approve to raise the PR.
                                     #   1 = raise the PR automatically (old behavior).
: "${REQUIRE_SPEC:=0}"               # 1 = a task must have a clarified specs/<id>.md (from
                                     #   ./plan.sh) before the loop will build it
: "${JIT_HISTORY:=1}"                # 1 = include the repo's raw conversation digest
                                     #   (sources/history/<repo>.md) in each task's prompt
: "${JIT_HARVEST:=1}"                # 1 = refresh that history (run harvest.py) at loop start
: "${ITER_SLEEP:=2}"

# --- CI / non-interactive hygiene (exported to every command the loop runs) -----
# prefer the newest Node 24 from nvm for builds (some repos pin a Node version via engines.node)
for _n in "$HOME"/.nvm/versions/node/v24*/bin; do [ -d "$_n" ] && PATH="$_n:$PATH"; done
export PATH
export CI=true                       # universal "I am headless" signal (npm/pnpm/husky…)
export HUSKY=0                       # don't install/run git hooks in automated runs
# export NPM_CONFIG_IGNORE_SCRIPTS=true   # uncomment if you don't rely on postinstall

# --- Claude / Codex flags ---------------------------------------------------
: "${CLAUDE_FLAGS:=--dangerously-skip-permissions}"   # full autonomy in a throwaway worktree
: "${CODEX_SANDBOX:=workspace-write}"

# Implementer: edits the worktree. Vault granted so it can compound learnings.
run_agent() {                       # stdin: prompt. cwd: $WORKDIR.
  case "$AGENT" in
    claude) ( cd "$WORKDIR" && claude -p $CLAUDE_FLAGS --add-dir "$TRELLIS_DIR" ) ;;
    codex)  ( cd "$WORKDIR" && codex exec --sandbox "$CODEX_SANDBOX" --skip-git-repo-check - ) ;;
    *) echo "Unknown AGENT: '$AGENT'" >&2; return 64 ;;
  esac
}

# Reviewer: emits a verdict from the diff (given inline). The loop does
# `git reset --hard` after, so any stray edits are discarded regardless. Codex runs
# in a read-only sandbox; claude runs headless (its edits are thrown away).
run_reviewer() {                    # stdin: prompt. cwd: $WORKDIR.
  case "$QA_AGENT" in
    claude) ( cd "$WORKDIR" && claude -p $CLAUDE_FLAGS ) ;;
    codex)  ( cd "$WORKDIR" && codex exec --sandbox read-only --skip-git-repo-check - ) ;;
    *) echo "Unknown QA_AGENT: '$QA_AGENT'" >&2; return 64 ;;
  esac
}

# Off-limits paths. Any changed file matching this => discard the whole iteration.
DENYLIST_RE='(^|/)\.env|\.pem$|secret|\.key$|/(auth|payment|payments|billing|migrations|db-backups)/|gen-lang-client-.*\.json|/\.github/workflows/'

# Test-file paths (for the anti-reward-hacking tamper check).
TESTFILE_RE='(^|/)(test|tests|__tests__|spec|e2e)/|\.(test|spec)\.[jt]sx?$|_test\.py$|test_.*\.py$|_spec\.rb$'
