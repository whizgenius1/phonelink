#!/bin/bash
# Remove phonelink: stop it, remove the login item, the binary and its log.
set -u
LABEL="com.libeforge.phonelink"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -INT -x phonelink 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/phonelink" \
      "$HOME/Library/Logs/phonelink.log" /tmp/phonelink.lock
echo "phonelink removed. You can also delete its entry in"
echo "System Settings → Privacy & Security → Accessibility."
