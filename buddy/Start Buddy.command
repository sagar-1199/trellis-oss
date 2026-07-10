#!/bin/zsh
# Trellis Buddy launcher — self-bootstrapping. Double-click to start Rivet.
# First run creates an isolated Python with the macOS UI bindings (~1 minute);
# after that, starting is instant. Works from wherever the repo is cloned.
set -e
HERE="${0:A:h}"                               # this buddy/ folder, wherever it lives
BUDDY="$HERE/buddy.py"
VENV="${BUDDY_VENV:-$HOME/.trellis/buddy-venv}"
mkdir -p "$HOME/.trellis"

if [ ! -x "$VENV/bin/python" ]; then
  echo "First run — setting up Rivet's Python (about a minute)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
  "$VENV/bin/pip" -q install pyobjc-framework-Cocoa pyobjc-framework-Quartz
fi
# self-repair: make sure the frameworks actually import
"$VENV/bin/python" -c "import AppKit, Quartz" 2>/dev/null || \
  "$VENV/bin/pip" -q install pyobjc-framework-Cocoa pyobjc-framework-Quartz

# install/refresh the login item so Rivet survives reboots
PLIST="$HOME/Library/LaunchAgents/com.trellis.buddy.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.trellis.buddy</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV/bin/python</string>
    <string>$BUDDY</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/.trellis/buddy.log</string>
  <key>StandardErrorPath</key><string>$HOME/.trellis/buddy.log</string>
</dict>
</plist>
EOF
pkill -f "buddy/buddy.py" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 2
pgrep -f "buddy/buddy.py" >/dev/null || {   # fallback if launchd is being difficult
  nohup "$VENV/bin/python" "$BUDDY" >>"$HOME/.trellis/buddy.log" 2>&1 &
  disown 2>/dev/null || true
}
sleep 1
clear
echo "Rivet is on duty above your Dock."
echo "  green antenna = idle (dozing in the corner) | orange = working | gray = asleep"
echo "  He now starts automatically at login. You can close this window."
