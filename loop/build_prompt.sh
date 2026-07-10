#!/usr/bin/env bash
# Assemble one iteration's prompt: the tool-neutral instructions + this task's
# details + the project's wiki page (context). Reads T_* env vars set by loop.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRELLIS_DIR="$(cd "$DIR/.." && pwd)"

sed "s#<vault>#$TRELLIS_DIR#g" "$DIR/LOOP_PROMPT.md"

cat <<EOF

---
## THIS TASK
- id: ${T_ID:-?}
- repo: ${T_REPO:-?}   (trust tier: ${T_TRUST:-unknown})
- working directory (you are here): ${T_WORKTREE:-$PWD}
- branch: ${T_BRANCH:-?}
- verify command (must pass before EXIT_SIGNAL: true): ${T_VERIFY:-"(none set — be conservative)"}
- title: ${T_TITLE:-?}
- acceptance criteria: ${T_ACCEPT:-"(none given — infer minimally and note assumptions)"}
- notes: ${T_NOTES:-none}
- PR_BODY_FILE (write your PR description here): ${T_PRBODY_FILE:-/dev/null}
EOF

# Clarified spec (from PLAN mode), if one exists — this is authoritative.
if [[ -n "${T_ID:-}" && -f "$TRELLIS_DIR/specs/$T_ID.md" ]]; then
  echo; echo "## SPEC (clarified with the human in PLAN mode — follow this exactly)"
  cat "$TRELLIS_DIR/specs/$T_ID.md"
fi

cat <<EOF

## PROJECT PAGE — context from the Trellis vault
EOF

if [[ -f "$TRELLIS_DIR/projects/${T_REPO:-}.md" ]]; then
  cat "$TRELLIS_DIR/projects/${T_REPO}.md"
else
  echo "(no projects/${T_REPO:-?}.md found — work from the repo itself and create the page if useful)"
fi

# JIT context (B): include this repo's raw conversation digest as extra background.
# The project page above is the curated version; this is the fuller recent history.
if [[ "${JIT_HISTORY:-0}" == "1" && -n "${T_REPO:-}" && -f "$TRELLIS_DIR/sources/history/${T_REPO}.md" ]]; then
  echo
  echo "## RECENT CONVERSATION HISTORY for ${T_REPO} (raw digest of past Claude sessions)"
  echo "<!-- Extra background only. The project page above is authoritative; use this to"
  echo "     understand prior intent/decisions. Distilled intents, may be noisy. -->"
  sed -n '1,140p' "$TRELLIS_DIR/sources/history/${T_REPO}.md"
fi

# Fixer mode: a previous attempt failed the gate or the reviewer. Feed it back.
if [[ -n "${T_FEEDBACK:-}" ]]; then
cat <<EOF

---
## ⚠ PREVIOUS ATTEMPT FAILED — FIX THIS (you are iterating on existing changes)
The working tree already contains the previous attempt. Address this feedback at the
root cause; do not start over, do not suppress errors, do not touch tests to pass.

$T_FEEDBACK
EOF
fi
