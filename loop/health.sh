#!/usr/bin/env bash
# Deterministic vault health checks (no agent, no tokens). Run often, run first.
#   ./health.sh            # report
# Checks: broken [[wikilinks]], orphan pages, project pages missing a verify gate.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRELLIS_DIR="$(cd "$DIR/.." && pwd)"
cd "$TRELLIS_DIR"

frontmatter() { # $1 key  $2 file
  awk -v k="$1" '/^---[[:space:]]*$/{n++; next} n==1 && $0 ~ "^"k":"{sub("^"k":[[:space:]]*",""); gsub(/^"|"$/,""); print; exit}' "$2"
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
issues=0

# Known page titles (projects + concepts)
: > "$tmp/titles"
for f in projects/*.md concepts/*.md index.md GUIDE.md hot.md; do [ -f "$f" ] && frontmatter title "$f" >> "$tmp/titles"; done
sort -u "$tmp/titles" -o "$tmp/titles"

# All wikilink targets referenced anywhere (strip alias after |)
grep -rhoE '\[\[[^]]+\]\]' projects concepts index.md hot.md 2>/dev/null \
  | sed -E 's/\[\[//; s/\]\]//; s/\|.*//' | sort -u > "$tmp/refs"

echo "== Trellis health =="
echo
echo "-- Broken wikilinks (referenced but no page with that title) --"
broken=$(comm -23 "$tmp/refs" "$tmp/titles")
if [ -n "$broken" ]; then echo "$broken" | sed 's/^/  ✗ /'; issues=$((issues+$(echo "$broken"|wc -l))); else echo "  none"; fi

echo
echo "-- Orphan pages (no inbound wikilink) --"
for f in projects/*.md concepts/*.md; do
  [ -f "$f" ] || continue
  t=$(frontmatter title "$f"); [ -z "$t" ] && continue
  if ! grep -rqF "[[$t]]" projects concepts index.md hot.md 2>/dev/null; then
    echo "  ⚠ $f  (title: $t)"; issues=$((issues+1))
  fi
done | sort -u
echo "  (review orphans; not always a problem)"

echo
echo "-- Project pages missing a verify gate (loop can't safely run these) --"
for f in projects/*.md; do
  [ -f "$f" ] || continue
  v=$(frontmatter verify "$f"); s=$(frontmatter status "$f")
  if [ -z "$v" ] && [ "$s" != "archived" ]; then echo "  • $f (status: ${s:-?})"; fi
done

echo
echo "== done. issues flagged: $issues =="
