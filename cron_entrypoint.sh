#!/usr/bin/env bash
#
# SessionBridge — Cron Entrypoint Wrapper
#
# This script wraps the Project Work cron job with SessionBridge lifecycle.
# Once the cron payload is updated to call this script, every hourly
# project work session will automatically log heartbeats, checkpoints,
# and tasks.
#
# Usage from cron payload:
#   /bin/bash -c "cd ~/.openclaw/workspace/session-bridge && bash cron_entrypoint.sh"
#
# Or inline in the cron message, replace the old single-message payload with:
#
#   "message": "Führe cron_entrypoint.sh aus:\n\ncd ~/.openclaw/workspace/session-bridge\nbash cron_entrypoint.sh\n\nDanach lies CURRENT_PROJECT.md und treib das Projekt voran. Committe und pushe."
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/bridge.sh"
SESSION_DIR="${SCRIPT_DIR}/.session-bridge"

echo "=== SessionBridge: Cron Entrypoint ==="

# Auto-init if no session exists yet
if [ ! -f "${SESSION_DIR}/context.json" ]; then
    echo "[SessionBridge] No active session — initializing..."
    "$BRIDGE" init "Hourly cron project work"
    echo "[SessionBridge] Session initialized."
fi

# 1. Heartbeat — loggt Liveness
echo "[SessionBridge] Heartbeat..."
"$BRIDGE" heartbeat

# 2. Auto-Checkpoint — loggt Checkpoint wenn >60min inaktiv
echo "[SessionBridge] Auto-Checkpoint..."
"$BRIDGE" autockpt 60

# 3. Task start (wird später per end abgeschlossen)
echo "[SessionBridge] Task: Hourly project work"
"$BRIDGE" task add "Hourly project work"

echo "=== SessionBridge initialized ==="
echo ""
