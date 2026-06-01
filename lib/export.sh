# SessionBridge — Markdown Export
# Export session event log as a human-readable Markdown report

# Export the event log as a Markdown summary report
# Usage: sb_export [output_file]
# If no output file is given, prints to stdout
sb_export() {
    local output_file="${1:-}"
    
    if ! sb_is_initialized; then
        echo "Error: SessionBridge not initialized." >&2
        return 1
    fi

    if [ ! -f "${EVENTS_FILE}" ]; then
        echo "No events to export."
        return
    fi

    local ctx
    ctx=$(sb_read_context)
    
    local sid started summary
    sid=$(echo "$ctx" | jq -r '.session_id // "unknown"')
    started=$(echo "$ctx" | jq -r '.started_at // "unknown"')
    summary=$(echo "$ctx" | jq -r '.summary // "(no description)"')

    local active_count completed_count decision_count file_count event_count
    active_count=$(echo "$ctx" | jq -r '.active_tasks | length' 2>/dev/null || echo 0)
    completed_count=$(echo "$ctx" | jq -r '.completed_tasks | length' 2>/dev/null || echo 0)
    decision_count=$(echo "$ctx" | jq -r '.recent_decisions | length' 2>/dev/null || echo 0)
    file_count=$(echo "$ctx" | jq -r '.recent_files | length' 2>/dev/null || echo 0)
    event_count=$(sb_event_count)

    # Compute durations from task_start / task_end pairs
    local time_data
    time_data=$(jq -s '
        [.[] | select(.e == "task_start" or .e == "task_end")]
        | group_by(.data.task)
        | map({
            task: .[0].data.task,
            start: (map(select(.e == "task_start")) | .[0].t // null),
            end: (map(select(.e == "task_end")) | .[0].t // null)
        })
        | map(select(.start != null))
    ' "${EVENTS_FILE}" 2>/dev/null || echo '[]')

    # Build the report
    local report=""

    # Header
    report+="# SessionBridge Export\n\n"
    report+="**Session:** ${summary}\n\n"
    report+="## Overview\n\n"
    report+="| Property | Value |\n"
    report+="|----------|-------|\n"
    report+="| Session ID | \`${sid}\` |\n"
    report+="| Started | ${started} |\n"
    report+="| Total Events | ${event_count} |\n"
    report+="| Active Tasks | ${active_count} |\n"
    report+="| Completed Tasks | ${completed_count} |\n"
    report+="| Decisions | ${decision_count} |\n"
    report+="| Files Touched | ${file_count} |\n"
    report+="\n"

    # Active Tasks section
    local active_tasks
    active_tasks=$(echo "$ctx" | jq -r '.active_tasks[] // empty' 2>/dev/null)
    if [ -n "$active_tasks" ]; then
        report+="## Active Tasks\n\n"
        while IFS= read -r task; do
            report+="- [ ] ${task}\n"
        done <<< "$active_tasks"
        report+="\n"
    fi

    # Completed Tasks section
    local completed_tasks
    completed_tasks=$(echo "$ctx" | jq -r '.completed_tasks[] // empty' 2>/dev/null)
    if [ -n "$completed_tasks" ]; then
        report+="## Completed Tasks\n\n"
        while IFS= read -r task; do
            report+="- [x] ${task}\n"
        done <<< "$completed_tasks"
        report+="\n"
    fi

    # Task timing section
    local has_timing
    has_timing=$(echo "$time_data" | jq 'length' 2>/dev/null || echo 0)
    if [ "$has_timing" -gt 0 ]; then
        report+="## Task Timing\n\n"
        report+="| Task | Start | End |\n"
        report+="|------|-------|-----|\n"
        while IFS= read -r row; do
            local task_name start_ts end_ts
            task_name=$(echo "$row" | jq -r '.task // "?"')
            start_ts=$(echo "$row" | jq -r '.start // "?"')
            end_ts=$(echo "$row" | jq -r '.end // "—"')
            report+="| ${task_name} | ${start_ts} | ${end_ts} |\n"
        done <<< "$(echo "$time_data" | jq -c '.[]')"
        report+="\n"
    fi

    # Decisions section
    local decisions
    decisions=$(echo "$ctx" | jq -r '.recent_decisions[] | "\(.what)\(if .why != "" and .why != null then ": " + .why else "" end)"' 2>/dev/null)
    if [ -n "$decisions" ]; then
        report+="## Decisions\n\n"
        while IFS= read -r dec; do
            report+="- ${dec}\n"
        done <<< "$decisions"
        report+="\n"
    fi

    # Files section
    local files
    files=$(echo "$ctx" | jq -r '.recent_files[] | "\(.path) (\(.action))"' 2>/dev/null)
    if [ -n "$files" ]; then
        report+="## Files\n\n"
        while IFS= read -r f; do
            report+="- ${f}\n"
        done <<< "$files"
        report+="\n"
    fi

    # Full Event Log
    report+="## Event Log\n\n"
    report+="All ${event_count} events (newest first):\n\n"
    report+="| Timestamp | Type | Details |\n"
    report+="|-----------|------|--------|\n"

    # Read events in reverse order (newest first)
    local events_reversed
    events_reversed=$(tac "${EVENTS_FILE}" 2>/dev/null || tail -r "${EVENTS_FILE}" 2>/dev/null || awk '{a[NR]=$0} END {for(i=NR;i>0;i--) print a[i]}' "${EVENTS_FILE}")
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts etype data_str
        ts=$(echo "$line" | jq -r '.t // "?"' 2>/dev/null)
        etype=$(echo "$line" | jq -r '.e // "?"' 2>/dev/null)
        data_str=$(echo "$line" | jq -r '.data | del(.tags) | tostring | .[0:100]' 2>/dev/null || echo "?")
        # Escape pipe chars for Markdown table
        data_str=$(echo "$data_str" | sed 's/|/\\|/g')
        report+="| ${ts} | \`${etype}\` | ${data_str} |\n"
    done <<< "$events_reversed"

    report+="\n"
    report+="---\n"
    report+="*Generated by SessionBridge v1.15*\n"

    # Output
    if [ -n "$output_file" ]; then
        # Ensure directory exists
        mkdir -p "$(dirname "$output_file")" 2>/dev/null || true
        printf "%b" "$report" > "$output_file"
        echo "Exported to: ${output_file}"
        sb_log export "{\"path\":\"${output_file}\",\"events\":${event_count}}"
    else
        printf "%b" "$report"
    fi
}

# Export the event log as a minimal JSON dump (useful for machine consumption)
# Usage: sb_export_json [output_file]
sb_export_json() {
    local output_file="${1:-}"

    if ! sb_is_initialized; then
        echo "Error: SessionBridge not initialized." >&2
        return 1
    fi

    if [ ! -f "${EVENTS_FILE}" ]; then
        echo "[]"
        return
    fi

    # Build JSON array from JSONL
    local json
    json=$(jq -s '.' "${EVENTS_FILE}" 2>/dev/null || echo '[]')

    if [ -n "$output_file" ]; then
        echo "$json" > "$output_file"
        echo "Exported JSON to: ${output_file}"
    else
        echo "$json"
    fi
}
