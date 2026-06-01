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

    # Build event JSON
    local event
    if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
        event=$(printf '{"t":"%s","e":"%s","data":%s,"s":"%s"}' \
            "$timestamp" "$event_type" "$data" "$session_id")
    else
        event=$(printf '{"t":"%s","e":"%s","data":%s}' \
            "$timestamp" "$event_type" "$data")
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
