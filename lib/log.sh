# SessionBridge — Event Logging
# Functions for writing to and reading from the event log

# Log an event to events.jsonl
# Usage: sb_log <event_type> [json_data] [session_id]
sb_log() {
    local event_type="$1"
    local data="${2:-}"
    [ -z "$data" ] && data='{}'
    local session_id="${3:-}"
    local timestamp

    sb_ensure_dir
    timestamp=$(sb_timestamp)

    if [ -z "$session_id" ]; then
        session_id=$(sb_read_context | jq -r '.session_id // empty' 2>/dev/null)
    fi

    # Build event JSON safely with jq to avoid injection
    # -c = compact output so each event is one JSONL line
    local event
    if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
        event=$(jq -c -n \
            --arg t "$timestamp" \
            --arg e "$event_type" \
            --argjson d "$data" \
            --arg s "$session_id" \
            '{"t":$t,"e":$e,"data":$d,"s":$s}')
    else
        event=$(jq -c -n \
            --arg t "$timestamp" \
            --arg e "$event_type" \
            --argjson d "$data" \
            '{"t":$t,"e":$e,"data":$d}')
    fi

    echo "$event" >> "${EVENTS_FILE}"
    echo "$event"
}

# Read recent N events
# Usage: sb_recent [count]
sb_recent() {
    local count="${1:-10}"
    if [ ! -f "${EVENTS_FILE}" ]; then
        echo "No events yet."
        return
    fi
    tail -n "$count" "${EVENTS_FILE}"
}

# Count total events
sb_event_count() {
    if [ ! -f "${EVENTS_FILE}" ]; then
        echo 0
        return
    fi
    wc -l < "${EVENTS_FILE}" | tr -d ' '
}

# Get events by type
# Usage: sb_events_by_type <event_type> [count]
sb_events_by_type() {
    local event_type="$1"
    local count="${2:-10}"
    if [ ! -f "${EVENTS_FILE}" ]; then
        return
    fi
    grep "\"e\":\"${event_type}\"" "${EVENTS_FILE}" | tail -n "$count"
}

# Get the most recent event of a type
# Usage: sb_last_event <event_type>
sb_last_event() {
    local event_type="$1"
    sb_events_by_type "$event_type" 1
}

# Garbage-collect old events, keeping only the last N
# Usage: sb_gc [keep]
# Default: keep the last 500 events
sb_gc() {
    local keep="${1:-500}"
    if [ ! -f "${EVENTS_FILE}" ]; then
        echo "No events to clean."
        return
    fi

    local total
    total=$(sb_event_count)

    if [ "$total" -le "$keep" ]; then
        echo "Events (${total}) within keep limit (${keep}), nothing to clean."
        return
    fi

    local remove_count=$((total - keep))
    local tmp
    tmp="${EVENTS_FILE}.tmp.$$"

    tail -n "$keep" "${EVENTS_FILE}" > "$tmp"
    mv "$tmp" "${EVENTS_FILE}"

    echo "GC: removed ${remove_count} old events, kept ${keep}"
}

# Get event log file size (bytes)
# Usage: sb_log_size
sb_log_size() {
    if [ ! -f "${EVENTS_FILE}" ]; then
        echo 0
        return
    fi
    wc -c < "${EVENTS_FILE}" | tr -d ' '
}
