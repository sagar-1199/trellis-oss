#!/usr/bin/env bash
# Assemble the reviewer prompt: QA instructions + task + acceptance + project page
# + the actual diff + verify output. Reads T_* env vars and $T_DIFF_FILE / $T_VERIFY_LOG.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRELLIS_DIR="$(cd "$DIR/.." && pwd)"

cat "$DIR/QA_PROMPT.md"

cat <<EOF

---
## TASK UNDER REVIEW
- repo: ${T_REPO:-?}   (trust tier: ${T_TRUST:-unknown})
- title: ${T_TITLE:-?}
- acceptance criteria: ${T_ACCEPT:-"(none given)"}

## PROJECT PAGE (context)
EOF
[ -f "$TRELLIS_DIR/projects/${T_REPO:-}.md" ] && sed -n '1,80p' "$TRELLIS_DIR/projects/${T_REPO}.md" || echo "(no project page)"

cat <<EOF

## VERIFY OUTPUT (the gate the change already passed)
\`\`\`
$(tail -40 "${T_VERIFY_LOG:-/dev/null}" 2>/dev/null)
\`\`\`

## THE DIFF (branch vs base)
\`\`\`diff
$(cat "${T_DIFF_FILE:-/dev/null}" 2>/dev/null)
\`\`\`
EOF
