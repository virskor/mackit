#!/bin/bash
# Quickly build and run Mackit
# Usage:
#   ./run.sh             Build debug and launch (default, fastest iteration)
#   ./run.sh release     Build release and launch
#   ./run.sh debug -n    Build only, do not launch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CONFIG="debug"
LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        -n|--no-launch) LAUNCH=0 ;;
        -h|--help)
            echo "Usage: ./run.sh [debug|release] [-n|--no-launch]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: ./run.sh [debug|release] [-n|--no-launch]" >&2
            exit 1
            ;;
    esac
done

APP="$ROOT/Mackit.app"
ICNS="$ROOT/.build/AppIcon.icns"
MACKIT_BIN="$APP/Contents/MacOS/Mackit"
# The tray agent is an embedded separate process: the same binary as the main
# app, but a different bundle. If the old agent is not killed, the main app may
# switch to a new binary while the tray still runs the old code.
AGENT_BIN="$APP/Contents/Library/LoginItems/MackitAgent.app/Contents/MacOS/MackitAgent"

START=$(date +%s)

# Stop already running instances, otherwise the old process keeps hold of the window.
# Match the executable's full path rather than -f full command-line matching: the
# latter would hit any unrelated process whose command line contains this path
# (e.g. tail -f on the app log).
stop_process() {
    local bin="$1"
    if pgrep -f "$bin" > /dev/null 2>&1; then
        echo "==> Stopping running instance: $(basename "$bin")"
        pkill -f "$bin" || true
        # Wait for the process to actually exit, to avoid "Text file busy" when replacing the binary
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -f "$bin" > /dev/null 2>&1 || break
            sleep 0.3
        done
    fi
}
stop_process "$MACKIT_BIN"
stop_process "$AGENT_BIN"

echo "==> Building ${CONFIG}"
# Skip regenerating the icon when an icns already exists, to speed up repeated builds
if [ -f "$ICNS" ]; then
    MACKIT_SKIP_ICON=1 Scripts/build-app.sh "$CONFIG"
else
    Scripts/build-app.sh "$CONFIG"
fi

ELAPSED=$(( $(date +%s) - START ))

if [ "$LAUNCH" -eq 1 ]; then
    echo "==> Launching Mackit.app (the main app starts the tray agent automatically)"
    open "$APP"
    echo
    echo "Done in ${ELAPSED}s: $APP"
    echo "Stop: pkill -f \"$MACKIT_BIN\"; pkill -f \"$AGENT_BIN\""
else
    echo
    echo "Done in ${ELAPSED}s (not launched): $APP"
fi
