#!/usr/bin/env bash
# Trellis installer — puts `trellis` on your PATH and creates ~/.trellis.
# Safe to re-run. Does not touch your projects or any vault content.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# 1) make the scripts executable
chmod +x "$HERE/bin/trellis" "$HERE"/loop/*.sh "$HERE"/buddy/*.command 2>/dev/null || true

# 2) runtime dir for status + (optional) buddy venv
mkdir -p "$HOME/.trellis"

# 3) symlink the CLI onto PATH
BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"
ln -sf "$HERE/bin/trellis" "$BINDIR/trellis"
echo "Linked: $BINDIR/trellis -> $HERE/bin/trellis"

case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *) echo
     echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
     echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo
echo "Done. Next:"
echo "  1) Open this folder in Obsidian (it's your brain / vault)."
echo "  2) Replace projects/example-app.md with a real project (set its 'path:')."
echo "  3) Make sure your agent CLI is installed:  claude   (or codex)."
echo "  4) Run:  trellis        # the menu"
echo
echo "The loop is DRY_RUN by default and holds PRs for your review — nothing"
echo "touches your repos or GitHub until you say so. See README.md and GUIDE.md."
