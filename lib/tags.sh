# SessionBridge — Tag-based Event Filtering
# Query events by tags attached to event data

# Show all known tags with event counts
# Usage: sb_tag_list
sb_tag_list() {
    if [ ! -f "${EVENTS_FILE}" ]; then
        echo "No tags found (no events)."
        return
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: jq required for tag operations" >&2
        return 1
    fi

    local has_tags
    has_tags=$(jq -r 'select(.data.tags != null and (.data.tags | length) > 0) | .data.tags[]' "${EVENTS_FILE}" 2>/dev/null | sort | uniq -c | sort -rn)

    if [ -z "$has_tags" ]; then
        echo "No tags found."
        return
    fi

    local total_tagged
    total_tagged=$(echo "$has_tags" | awk '{sum += $1} END {print sum}')

    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║           SessionBridge Tags              ║"
    echo "╚═══════════════════════════════════════════╝"
    echo ""
    echo "  Total tagged events: ${total_tagged}"
    echo ""

    echo "  Tags:"
    echo "$has_tags" | while IFS= read -r line; do
        local count name
        count=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ //')
        echo "    #${name}  (${count})"
    done
    echo ""
}

# Show events matching a specific tag
# Usage: sb_tag_show <tag> [count]
sb_tag_show() {
    local tag="$1"
    local count="${2:-20}"

    if [ -z "$tag" ]; then
        echo "Usage: sb_tag_show <tag> [count]" >&2
        return 1
    fi

    if [ ! -f "${EVENTS_FILE}" ]; then
        echo "No events."
        return
    fi

    local results
    results=$(jq -c --arg tag "$tag" 'select(.data.tags != null and (.data.tags | index($tag)) != null)' "${EVENTS_FILE}" 2>/dev/null | tail -n "$count")

    if [ -z "$results" ]; then
        echo "No events with tag '#${tag}'."
        return
    fi

    local total
    total=$(jq --arg tag "$tag" 'select(.data.tags != null and (.data.tags | index($tag)) != null)' "${EVENTS_FILE}" 2>/dev/null | wc -l | tr -d ' ')

    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║        Events tagged: #${tag}                "
    echo "╚═══════════════════════════════════════════╝"
    echo ""
    echo "  Total: ${total} events  (showing last ${count})"
    echo ""

    echo "$results" | while IFS= read -r line; do
        local ts event_type summary
        ts=$(echo "$line" | jq -r '.t // "?"')
        event_type=$(echo "$line" | jq -r '.e // "?"')
        summary=$(echo "$line" | jq -r '.data | del(.tags) | tostring | .[0:80]')
        echo "  [${ts}] ${event_type}"
        echo "    ${summary}"
        echo ""
    done
}
