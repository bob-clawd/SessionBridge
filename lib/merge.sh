# SessionBridge — Session Merge
# Merge events from one session directory into the current session

# Merge events from a source session directory into the current session
# Usage: sb_merge <source_dir> [--skip-dupes]
sb_merge() {
    local source_dir="$1"
    local skip_dupes=false

    # Parse optional flags
    for arg in "$@"; do
        [ "$arg" = "--skip-dupes" ] && skip_dupes=true
    done

    if [ -z "$source_dir" ]; then
        echo "Error: source directory required" >&2
        echo "Usage: bridge.sh merge <source_dir> [--skip-dupes]" >&2
        return 1
    fi

    if ! sb_is_initialized; then
        echo "Error: no active session (run bridge.sh init first)" >&2
        return 1
    fi

    # Accept both root dirs and .session-bridge dirs
    local source_base="$source_dir"
    local source_events="${source_base}/events.jsonl"
    local source_context="${source_base}/context.json"
    if [ ! -f "$source_events" ] && [ -d "${source_base}/${SESSION_DIR}" ]; then
        source_base="${source_base}/${SESSION_DIR}"
        source_events="${source_base}/events.jsonl"
        source_context="${source_base}/context.json"
    fi

    if [ ! -f "$source_events" ]; then
        echo "Error: source has no events file: ${source_events}" >&2
        return 1
    fi

    # Read source metadata
    local source_session_id=""
    local source_summary=""
    if [ -f "$source_context" ]; then
        source_session_id=$(jq -r '.session_id // ""' "$source_context")
        source_summary=$(jq -r '.summary // ""' "$source_context")
    fi
    [ -z "$source_summary" ] && source_summary="(unknown)"

    local total_source
    total_source=$(wc -l < "$source_events" | tr -d ' ')

    echo "Merging ${total_source} events from '${source_summary}'..."
    echo ""

    # Count events before
    local before
    before=$(sb_event_count)

    # Read all source events and append to our events file
    local merged_count=0
    local skipped_count=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Validate JSON
        if ! echo "$line" | jq . >/dev/null 2>&1; then
            skipped_count=$((skipped_count + 1))
            continue
        fi

        # Check for duplicates if requested
        if [ "$skip_dupes" = true ]; then
            local source_e source_t
            source_e=$(echo "$line" | jq -r '.e // ""')
            source_t=$(echo "$line" | jq -r '.t // ""')
            if [ -n "$source_e" ] && [ -n "$source_t" ]; then
                local existing
                existing=$(grep -c "\"e\":\"${source_e}\"" "${EVENTS_FILE}" 2>/dev/null || echo 0)
                # Lighter dupe check: skip if same event type + timestamp exists
                if grep -q "\"e\":\"${source_e}\",\"data\":.*\"t\":\"${source_t}\"" "${EVENTS_FILE}" 2>/dev/null; then
                    skipped_count=$((skipped_count + 1))
                    continue
                fi
            fi
        fi

        echo "$line" >> "${EVENTS_FILE}"
        merged_count=$((merged_count + 1))
    done < "$source_events"

    # Merge context fields (aggregate decisions, files, tasks)
    if [ -f "$source_context" ]; then
        local ctx
        ctx=$(sb_read_context)

        # Merge active tasks (deduplicate)
        local merged
        merged=$(echo "$ctx" | jq --slurpfile src "$source_context" '
            .active_tasks = (.active_tasks + $src[0].active_tasks | unique)
        ')

        # Merge completed tasks (deduplicate)
        merged=$(echo "$merged" | jq --slurpfile src "$source_context" '
            .completed_tasks = (.completed_tasks + $src[0].completed_tasks | unique)
        ')

        # Merge recent decisions (deduplicate by "what")
        merged=$(echo "$merged" | jq --slurpfile src "$source_context" '
            .recent_decisions = (.recent_decisions + $src[0].recent_decisions | unique_by(.what))
            | .recent_decisions = .recent_decisions[-20:]
        ')

        # Merge recent files (deduplicate by path, keep most recent action)
        merged=$(echo "$merged" | jq --slurpfile src "$source_context" '
            .recent_files = (.recent_files + $src[0].recent_files | reverse | unique_by(.path) | reverse)
            | .recent_files = .recent_files[-50:]
        ')

        echo "$merged" | sb_write_context
    fi

    local after
    after=$(sb_event_count)

    # Log the merge event
    sb_log session_merge "{\"source\":\"${source_summary}\",\"source_session\":\"${source_session_id}\",\"merged\":${merged_count},\"skipped\":${skipped_count},\"total_before\":${before},\"total_after\":${after}}"

    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║           Merge Complete                  ║"
    echo "╚═══════════════════════════════════════════╝"
    echo ""
    echo "  Source:        ${source_summary}"
    echo "  Events merged: ${merged_count}"
    [ "$skipped_count" -gt 0 ] && echo "  Skipped:       ${skipped_count}"
    echo "  Before merge:  ${before}"
    echo "  After merge:   ${after}"
    echo ""
}
