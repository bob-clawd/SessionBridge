#!/usr/bin/env bash
#
# SessionBridge — Workspace Integration Script
#
# Source this at session start to auto-init bridge.sh.
# Usage:
#   source integrate.sh [session_summary]
#
# Sets up SB_* environment variables and logs session start.
# On shell exit, logs session_end automatically.
#
# NOTE: This script is meant to be SOURCED, not executed.
# Don't use set -e — it would affect the parent shell.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/bridge.sh"

if [ ! -f "$BRIDGE" ]; then
    echo "SessionBridge: bridge.sh not found at ${BRIDGE}" >&2
    return 1
fi

# Check for jq
if ! command -v jq &>/dev/null; then
    echo "SessionBridge: jq is required. Install with: apt install jq" >&2
    return 1
fi

SESSION_SUMMARY="${1:-$(basename "$(pwd)") session}"

# Initialize (with auto-GC to keep things lean)
SB_GC_KEEP=500 "$BRIDGE" init "$SESSION_SUMMARY" 2>&1

# Source env vars
source <("$BRIDGE" env 2>/dev/null) || true

echo ""
echo " ╔══════════════════════════════════════╗"
echo " ║     SessionBridge Active v1.3        ║"
echo " ╠══════════════════════════════════════╣"
echo " ║  Session:  ${SB_SUMMARY:-$SESSION_SUMMARY}"
echo " ║  ID:       ${SB_SESSION_ID:-(unknown)}"
echo " ║  Tasks:    ${SB_ACTIVE_TASKS:-none}"
echo " ║  Events:   ${SB_EVENT_COUNT:-0}"
echo " ╚══════════════════════════════════════╝"
echo ""

# Log session_end on shell exit
sb_atexit() {
    if [ -f "$BRIDGE" ]; then
        "$BRIDGE" log session_end '{"reason":"shell_exit"}' >/dev/null 2>&1 || true
    fi
}
trap sb_atexit EXIT
