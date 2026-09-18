#!/bin/bash
# Re-grant Accessibility / Screen Recording after installing an update.
# Usage: ./script/fix-permissions.sh [/path/to/Ice.app]
#
# Release builds are ad-hoc signed, so the app's designated requirement is a
# pinned cdhash rather than a stable Developer ID. Every build has a different
# hash, so the csreq macOS stored when you first granted access stops matching:
# System Settings keeps showing the toggle as on while tccd denies the app.
# Dropping the stale rows lets the next grant bind to the new signature.
set -e

APP="${1:-/Applications/Ice.app}"
BUNDLE_ID="com.jordanbaird.Ice"

if [[ ! -d "$APP" ]]; then
  echo "not found: $APP"
  echo "usage: $0 [/path/to/Ice.app]"
  exit 1
fi

echo "Ice: $APP"
codesign -dvvv "$APP" 2>&1 | grep -E 'CDHash=|flags=' | sed 's/^/  /' || true
echo

# tccd caches authorization for a running process, so quit before resetting —
# otherwise Ice stays half-denied until the next launch anyway.
if pgrep -f "$APP" >/dev/null 2>&1; then
  echo "quitting Ice"
  osascript -e 'quit app "Ice"' 2>/dev/null || true
  sleep 2
  pkill -f "$APP" 2>/dev/null || true
  sleep 1
fi

echo "resetting TCC entries for $BUNDLE_ID"
# ListenEvent/PostEvent usually have no row; a miss is not an error.
for SERVICE in Accessibility ScreenCapture ListenEvent PostEvent; do
  if tccutil reset "$SERVICE" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "  $SERVICE — reset"
  else
    echo "  $SERVICE — nothing to reset"
  fi
done

echo
echo "relaunching Ice"
open -a "$APP"
sleep 3
pgrep -f "$APP" >/dev/null 2>&1 || echo "warning: Ice did not start"

cat <<'EOF'

Now re-grant in System Settings > Privacy & Security:
  Accessibility      hiding and moving menu bar items
  Screen Recording   menu bar item images, Ice Bar

If a greyed-out Ice entry is still listed, select it, press "-", then let Ice
prompt again.
EOF
