# SessionBridge — Shared Utilities
# Source this from bridge.sh

SESSION_DIR=".session-bridge"
EVENTS_FILE="${SESSION_DIR}/events.jsonl"
CONTEXT_FILE="${SESSION_DIR}/context.json"
BOOKMARKS_DIR="${SESSION_DIR}/bookmarks"

# Generate a timestamp in ISO 8601 format
sb_timestamp() {
    date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"
}

# Generate a simple UUID (not cryptographically secure, but sufficient)
sb_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    else
        # Fallback: random hex
        echo "sb-$(date +%s)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' ')"
    fi
}

# Ensure the session directory exists
sb_ensure_dir() {
    mkdir -p "${SESSION_DIR}" "${BOOKMARKS_DIR}"
}

# Check if bridge is initialized
sb_is_initialized() {
    [ -d "${SESSION_DIR}" ] && [ -f "${CONTEXT_FILE}" ]
}

# Read current context as JSON string
sb_read_context() {
    if [ -f "${CONTEXT_FILE}" ]; then
        cat "${CONTEXT_FILE}"
    else
        echo '{}'
    fi
}

# Write context file atomically
sb_write_context() {
    local tmp
    tmp="${CONTEXT_FILE}.tmp.$$"
    cat > "$tmp"
    mv "$tmp" "${CONTEXT_FILE}"
}

# Validate JSON (basic check with jq if available, otherwise accept)
sb_validate_json() {
    if command -v jq &>/dev/null; then
        echo "$1" | jq . >/dev/null 2>&1
        return $?
    fi
    return 0
}

# Check dependencies
sb_require_jq() {
    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' is required for SessionBridge operations." >&2
        echo "Install it: apt install jq  (or brew install jq)" >&2
        exit 1
    fi
}
