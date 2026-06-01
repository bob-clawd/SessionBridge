#!/usr/bin/env bash
#
# SessionBridge — Cron Exitpoint Wrapper
#
# Called AFTER hourly cron project work completes.
# Logs task completion, final heartbeat, and ends the session.
#
# Usage from cron payload:
#   /bin/bash -c "cd ~/.openclaw/workspace/session-bridge && bash cron_exitpoint.sh"
#
# Full cron lifecycle (inline payload):
#   cd ~/.openclaw/workspace/session-bridge/ \
#   && bash cron_entrypoint.sh \
#   && <PROJECT_WORK> \
#   && bash cron_exitpoint.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/bridge.sh"
SESSION_DIR="${SCRIPT_DIR}/.session-bridge"

echo "=== SessionBridge: Cron Exitpoint ==="

# Guard: no active session
if [ ! -f "${SESSION_DIR}/context.json" ]; then
    echo "[SessionBridge] No active session — skipping exitpoint."
    exit 0
fi

# 1. Task done — abschliessen
echo "[SessionBridge] Completing task..."
"$BRIDGE" task done "Hourly project work" 2>/dev/null || true

# 2. Final heartbeat
echo "[SessionBridge] Final heartbeat..."
"$BRIDGE" heartbeat

# 3. Session beenden
echo "[SessionBridge] Ending session..."
"$BRIDGE" end "cron_complete"

echo "=== SessionBridge: Done ==="
