#!/bin/zsh
launchctl unload "$HOME/Library/LaunchAgents/com.trellis.buddy.plist" 2>/dev/null
pkill -f "buddy/buddy.py" && echo "Trellis Buddy stopped." || echo "Buddy wasn't running."
sleep 0.6
