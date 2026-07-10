#!/usr/bin/env bash
# Trellis retro — the self-improvement pass (human-gated).
#   1. reconcile PR outcomes + compute the accepted-change rate (retro.py)
#   2. an agent turns escalations + edited/closed PRs into durable LESSONS on project
#      pages (auto — knowledge only), and PROPOSES gate/prompt changes for you to approve.
# It must NOT edit the gates/prompts itself — those stay human-approved.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
cd "$TRELLIS_DIR"

echo "== Trellis retro =="
python3 "$DIR/retro.py" || { echo "retro.py failed"; exit 1; }
report="$(ls -t retro/RETRO-*.md 2>/dev/null | head -1)"
[ -z "$report" ] && { echo "(no report / no data yet)"; exit 0; }

echo; echo "-> reflecting with $AGENT (writing lessons to project pages; proposing gate changes)..."
read -r -d '' PROMPT <<EOF || true
You are running a Trellis RETRO (self-improvement, human-gated). Working dir is the vault.

Read: $report  and  loop/metrics.jsonl.

For EACH escalation and EACH merged-with-edits or closed PR listed in the report:
1. Work out the likely root cause (for escalations) or what the human changed and WHY
   (for edited/closed PRs — use \`gh pr diff <url>\` and \`gh pr view <url> --comments\`).
2. Append ONE concise durable lesson (1-2 lines, a gotcha or decision) to the relevant
   projects/<repo>.md so future runs avoid the mistake. Merge into the page; don't dupe.
   This is ALLOWED — it is knowledge only.

Then, in $report under "## Proposed improvements (NOT applied — for human approval)",
PROPOSE (as a checklist) any changes to verify gates, trust tiers, LOOP_PROMPT.md, or
QA_PROMPT.md that would raise the accepted-change / merged-without-edits rate. Ground
each proposal in the evidence above.

HARD RULE: you may edit projects/*.md and $report ONLY. You must NOT edit LOOP_PROMPT.md,
QA_PROMPT.md, config.sh, loop.sh, backlog.md, or any verify gate — only propose those.
Keep everything tight and evidence-based. When done, print: RETRO_DONE
EOF

WORKDIR="$TRELLIS_DIR" run_agent <<<"$PROMPT" 2>&1 | tee "$TRELLIS_DIR/loop/runs/retro-$(date +%F).log" >/dev/null || true

git add -A 2>/dev/null && git -c user.name='Trellis' -c user.email='trellis@local' \
  commit -q -m "trellis retro: lessons + proposals ($(date +%F))" 2>/dev/null || true
echo
echo "Retro complete. Review the proposals (nothing to gates was auto-applied):"
echo "  $report"
