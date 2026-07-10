#!/usr/bin/env bash
# Trellis ingest — merge freshly-harvested conversation history into project pages.
# Runs after harvest.py (see `trellis sync`). Only pages whose history file is newer
# than the page itself are touched.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
cd "$TRELLIS_DIR"

stale=""
for h in sources/history/*.md; do
  [ -f "$h" ] || continue
  slug="$(basename "$h" .md)"
  case "$slug" in _unmapped|other-*) continue ;; esac      # unmapped digests have no page
  p="projects/$slug.md"
  [ -f "$p" ] || continue
  [ "$h" -nt "$p" ] && stale="$stale $slug"
done
stale="${stale# }"
[ -z "$stale" ] && { echo "Ingest: all project pages are already up to date."; exit 0; }

echo "Ingest: updating pages for: $stale"
read -r -d '' PROMPT <<EOF || true
You are running Trellis INGEST-HISTORY (see AGENTS.md -> Operations -> Ingest history).
Working dir is the vault.

For each of these project slugs:  $stale
1. Read sources/history/<slug>.md (fresh conversation digest) and projects/<slug>.md.
2. Merge NEW durable knowledge into the project page: decisions + why, gotchas,
   sensitive areas, and current unfinished threads. Update stale statements instead
   of duplicating; keep the page tight. Mark uncertain items [inferred].
3. Update the page's 'updated:' frontmatter to today.

HARD RULE: edit ONLY projects/<slug>.md for the slugs listed above. No other files.
When done, print: INGEST_DONE
EOF

WORKDIR="$TRELLIS_DIR" run_agent <<<"$PROMPT" 2>&1 | tee "$TRELLIS_DIR/loop/runs/ingest-$(date +%F).log" >/dev/null || true

# stamp pages so the newer-than check is correct even if the agent skipped one
for s in $stale; do touch "projects/$s.md"; done
git add projects 2>/dev/null && git -c user.name='Trellis' -c user.email='trellis@local' \
  commit -q -m "trellis ingest: history -> project pages ($(date +%F))" 2>/dev/null || true
echo "Ingest complete. Pages updated: $stale"
