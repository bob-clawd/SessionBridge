# SessionBridge — Timesink Report (sb_top)
# Analyze task_start/task_end pairs to show time spent per task
# Source this from bridge.sh

# Calculate a duration string from seconds
sb_format_duration() {
    local total_s="$1"
    local sign=""
    [ "$total_s" -lt 0 ] && sign="-" && total_s=$((-total_s))
    local h m s
    h=$((total_s / 3600))
    m=$(((total_s % 3600) / 60))
    s=$((total_s % 60))
    if [ "$h" -gt 0 ]; then
        printf "%s%dh %dm %ds" "$sign" "$h" "$m" "$s"
    elif [ "$m" -gt 0 ]; then
        printf "%s%dm %ds" "$sign" "$m" "$s"
    else
        printf "%s%ds" "$sign" "$s"
    fi
}

# Convert ISO 8601 timestamp to epoch seconds (cross-platform)
sb_ts_to_epoch() {
    local ts="$1"
    local epoch
    if date --version 2>/dev/null | grep -q GNU; then
        epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    else
        # macOS fallback: strip colon from TZ offset
        local ts_clean
        ts_clean=$(echo "$ts" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts_clean" +%s 2>/dev/null || echo 0)
    fi
    echo "$epoch"
}

# Show timesink report — time spent per task derived from task_start/task_end pairs
# Usage: sb_top [limit]
# If limit is given, shows only top N tasks by duration
sb_top() {
    local limit="${1:-0}"

    if ! sb_is_initialized; then
        echo "Error: SessionBridge not initialized." >&2
        return 1
    fi

    if [ ! -f "${EVENTS_FILE}" ]; then
        echo "No events to analyze."
        return
    fi

    local ctx
    ctx=$(sb_read_context)
    local session_summary
    session_summary=$(echo "$ctx" | jq -r '.summary // "(no description)"')

    # Parse events.jsonl: extract all task_start and task_end events
    # Group by task name, find earliest start and latest end
    local tasks_data
    tasks_data=$(jq -s '
        [.[] | select(.e == "task_start" or .e == "task_end")]
        | group_by(.data.task // "unknown")
        | map({
            task: .[0].data.task,
            session: (.[0].s // ""),
            starts: [.[] | select(.e == "task_start") | .t],
            ends: [.[] | select(.e == "task_end") | .t]
        })
    ' "${EVENTS_FILE}" 2>/dev/null || echo '[]')

    local task_count
    task_count=$(echo "$tasks_data" | jq 'length' 2>/dev/null || echo 0)

    if [ "$task_count" -eq 0 ]; then
        echo "No task events found in the log."
        echo "Use: bridge.sh task add <name> and bridge.sh task done <name>"
        return
    fi

    local now_epoch
    now_epoch=$(date +%s)

    # Build the report data: compute durations
    local report_lines=""
    local completed=0
    local running=0

    while IFS= read -r task_info; do
        [ -z "$task_info" ] && continue
        local task_name
        task_name=$(echo "$task_info" | jq -r '.task // "?"')
        local start_count
        start_count=$(echo "$task_info" | jq '.starts | length')
        local end_count
        end_count=$(echo "$task_info" | jq '.ends | length')

        local first_start last_end
        first_start=$(echo "$task_info" | jq -r '.starts[0] // empty')
        last_end=$(echo "$task_info" | jq -r '.ends[-1] // empty')

        local duration_s=0
        local status
        local status_icon

        if [ -n "$first_start" ]; then
            local start_epoch
            start_epoch=$(sb_ts_to_epoch "$first_start")

            if [ -n "$last_end" ]; then
                local end_epoch
                end_epoch=$(sb_ts_to_epoch "$last_end")
                duration_s=$((end_epoch - start_epoch))
                [ "$duration_s" -lt 0 ] && duration_s=0
                status="completed"
                status_icon="✓"
                completed=$((completed + 1))
            else
                # Still running: use now as end
                if [ "$start_epoch" -gt 0 ]; then
                    duration_s=$((now_epoch - start_epoch))
                fi
                status="running"
                status_icon="▶"
                running=$((running + 1))
            fi
        fi

        local count_str=""
        if [ "$start_count" -gt 1 ]; then
            count_str=" (${start_count}x)"
        fi

        local duration_str
        duration_str=$(sb_format_duration "$duration_s")

        # Build sortable line: duration_seconds|status_icon|task_name|duration_str|count_str
        report_lines="${report_lines}${duration_s}|${status_icon}|${task_name}|${duration_str}|${count_str}"$'\n'
    done <<< "$(echo "$tasks_data" | jq -c '.[]')"

    # Sort by duration descending and apply limit
    local sorted
    sorted=$(echo "$report_lines" | sort -t'|' -k1 -rn)

    if [ "$limit" -gt 0 ] 2>/dev/null; then
        sorted=$(echo "$sorted" | head -n "$limit")
    fi

    local total_duration_s=0
    total_duration_s=$(echo "$sorted" | awk -F'|' '{s+=$1} END {print int(s)}')
    local total_duration_str
    total_duration_str=$(sb_format_duration "$total_duration_s")

    # ── Output ──
    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║        SessionBridge Timesink Report      ║"
    echo "╚═══════════════════════════════════════════╝"
    echo ""
    echo "  Session:  ${session_summary}"
    echo "  Tasks:    ${task_count} total (${completed} completed, ${running} running)"
    echo "  Total:    ${total_duration_str}"
    [ "$limit" -gt 0 ] && echo "  Showing:  top ${limit} by duration"
    echo ""
    echo "  Duration       Status  Task"
    echo "  ─────────────  ──────  ─────────────────────────────────────"
    
    while IFS='|' read -r secs icon task dur_str count_str; do
        [ -z "$secs" ] && continue
        # Pad duration to 14 chars
        printf "  %-14s %s      %s%s\n" "$dur_str" "$icon" "$task" "$count_str"
    done <<< "$sorted"

    echo "  ─────────────  ──────  ─────────────────────────────────────"
    printf "  %-14s\n" "$total_duration_str"
    echo ""

    # Tips for running tasks
    if [ "$running" -gt 0 ]; then
        echo "  ▶ Running tasks: $running still active"
        echo "    Use 'bridge.sh task done <name>' to close them"
        echo ""
    fi

    # Log that we ran a timesink analysis
    sb_log timesink_analysis "$(jq -n \
        --argjson tasks "$task_count" \
        --argjson completed "$completed" \
        --argjson running "$running" \
        --argjson total_seconds "$total_duration_s" \
        '{"tasks":$tasks,"completed":$completed,"running":$running,"total_seconds":$total_seconds}')"
}
