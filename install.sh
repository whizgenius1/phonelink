#!/bin/bash
# Build and install phonelink into ~/.local/bin, optionally starting it at login.
#
#   ./install.sh                                   build + install only
#   ./install.sh --autostart                       ...and start at login (first connected device)
#   ./install.sh --autostart --serial ABC123 --speed 2.5 --edge left
set -euo pipefail

LABEL="com.libeforge.phonelink"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/phonelink"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/phonelink.log"
SRC="$(cd "$(dirname "$0")" && pwd)/phonelink.swift"

autostart=false
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --autostart) autostart=true ;;
        --serial|--speed|--edge) [ $# -ge 2 ] || { echo "$1 needs a value"; exit 2; }; args+=("$1" "$2"); shift ;;
        --no-clipboard|--no-cmd-as-ctrl) args+=("$1") ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
    shift
done

missing=()
command -v swiftc >/dev/null || missing+=("Xcode command line tools  →  xcode-select --install")
command -v adb    >/dev/null || missing+=("adb     →  brew install android-platform-tools")
command -v scrcpy >/dev/null || missing+=("scrcpy  →  brew install scrcpy")
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing requirements:"; printf '  - %s\n' "${missing[@]}"; exit 1
fi

echo "Building…"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swiftc -O -swift-version 5 "$SRC" -o "$tmp/phonelink"
codesign -f -s - -i "$LABEL" "$tmp/phonelink" 2>/dev/null

mkdir -p "$BIN_DIR"
# Stop a running copy first so the new build takes over cleanly.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -INT -x phonelink 2>/dev/null || true
mv "$tmp/phonelink" "$BIN"
echo "Installed $BIN"

if $autostart; then
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    {
        cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
EOF
        for a in ${args[@]+"${args[@]}"}; do printf '        <string>%s</string>\n' "$a"; done
        cat <<EOF
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    } > "$PLIST"
    plutil -lint "$PLIST" >/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Auto-start enabled ($PLIST). Log: $LOG"
elif [ -f "$PLIST" ]; then
    # Reinstall without --autostart: keep the existing login item running.
    launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "Restarted existing auto-start ($PLIST)"
fi

cat <<EOF

One-time step — grant Accessibility permission:
  System Settings → Privacy & Security → Accessibility → + → ⌘⇧G → $BIN
  (After every reinstall: remove phonelink with − and add it again — macOS
   ties the permission to the exact build.)
EOF
if $autostart; then
    echo "  Then restart it:  launchctl kickstart -k gui/\$(id -u)/$LABEL"
else
    echo "  Then run:  $BIN ${args[*]+"${args[*]}"}"
fi
