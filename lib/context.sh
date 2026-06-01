# SessionBridge — Active Context Management
# Functions for current session context tracking

# Initialize session context
# Usage: sb_init_context [summary]
sb_init_context() {
    local summary="${1:-Session initialized}"
    local session_id
    session_id=$(sb_uuid)
    local started_at
    started_at=$(sb_timestamp)

    sb_ensure_dir

    jq -n \
        --arg sid "$session_id" \
        --arg started "$started_at" \
        --arg summary "$summary" \
        '{
            "session_id": $sid,
            "started_at": $started,
            "active_tasks": [],
            "completed_tasks": [],
            "recent_decisions": [],
            "recent_files": [],
            "tags": {},
            "summary": $summary
        }' | sb_write_context

    echo "$session_id"
}

# Update context field (merge)
# Usage: sb_context_set <jq_filter>
# Also accepts extra jq args before the filter (e.g. --arg, --argjson)
# Example: sb_context_set '.active_tasks += [$name]'
# Example: sb_context_set --arg name "my task" '.active_tasks += [$name]'
sb_context_set() {
    local filter="${@: -1}"
    local extra_args=("${@:1:$#-1}")
    local ctx
    ctx=$(sb_read_context)

    echo "$ctx" | jq "${extra_args[@]}" "$filter" | sb_write_context
}

# Add a task to active_tasks
# Usage: sb_add_task <task_name>
sb_add_task() {
    local task="$1"
    sb_context_set --arg task "$task" '.active_tasks += [$task]'
    sb_log task_start "$(jq -n --arg task "$task" '{"task":$task}')"
}

# Mark a task as completed
# Usage: sb_complete_task <task_name>
sb_complete_task() {
    local task="$1"
    sb_context_set --arg task "$task" '.active_tasks -= [$task] | .completed_tasks += [$task]'
    sb_log task_end "$(jq -n --arg task "$task" '{"task":$task,"result":"completed"}')"
}

# Add a decision
# Usage: sb_add_decision <what> <why>
sb_add_decision() {
    local what="$1"
    local why="$2"
    sb_context_set \
        --arg what "$what" --arg why "$why" \
        '.recent_decisions = .recent_decisions[:19] + [{"what":$what,"why":$why}]'
    sb_log decision "$(jq -n --arg what "$what" --arg why "$why" '{"what":$what,"why":$why}')"
}

# Record a file touch
# Usage: sb_touch_file <path> <action>
sb_touch_file() {
    local path="$1"
    local action="${2:-read}"
    sb_context_set \
        --arg path "$path" --arg action "$action" \
        '.recent_files = .recent_files[:49] + [{"path":$path,"action":$action}]'
    sb_log file_touch "$(jq -n --arg path "$path" --arg action "$action" '{"path":$path,"action":$action}')"
}

# Get the current context summary
sb_summary() {
    sb_read_context | jq -r '.summary // "No summary"' 2>/dev/null
}

# Emit shell env vars for sourcing into an agent session
# Usage: source <(bridge.sh env)
sb_env() {
    if ! sb_is_initialized; then
        echo >&2 "SessionBridge: NOT INITIALIZED"
        return 1
    fi

    local ctx
    ctx=$(sb_read_context)

    # Emit variables with safe quoting
    local sid started summary
    sid=$(echo "$ctx" | jq -r '.session_id // ""')
    started=$(echo "$ctx" | jq -r '.started_at // ""')
    summary=$(echo "$ctx" | jq -r '.summary // ""')

    printf 'export SB_SESSION_ID=%q\n' "$sid"
    printf 'export SB_STARTED_AT=%q\n' "$started"
    printf 'export SB_SUMMARY=%q\n' "$summary"
    printf 'export SB_EVENT_COUNT=%s\n' "$(sb_event_count)"
    printf 'export SB_SESSION_DIR=%s\n' "$(cd "$SESSION_DIR" 2>/dev/null && pwd)"

    # Active tasks as newline-separated string
    local tasks
    tasks=$(echo "$ctx" | jq -r '.active_tasks | join("\\n") // ""')
    if [ -n "$tasks" ]; then
        printf 'export SB_ACTIVE_TASKS=%q\n' "$tasks"
    fi

    # Completed tasks count
    local completed_count
    completed_count=$(echo "$ctx" | jq -r '.completed_tasks | length // 0')
    printf 'export SB_COMPLETED_COUNT=%s\n' "$completed_count"

    # Count bookmarks (nullglob-safe)
    local bookmark_count
    # shellcheck disable=SC2144
    if [ -d "${BOOKMARKS_DIR}" ] && [ "$(echo "${BOOKMARKS_DIR}"/*.json)" != "${BOOKMARKS_DIR}/*.json" ]; then
        bookmark_count=$(ls "${BOOKMARKS_DIR}"/*.json 2>/dev/null | wc -l)
    else
        bookmark_count=0
    fi
    printf 'export SB_BOOKMARK_COUNT=%s\n' "$bookmark_count"
}

# Show status
sb_status() {
    if ! sb_is_initialized; then
        echo "SessionBridge: NOT INITIALIZED"
        echo "Run: bridge.sh init"
        return
    fi

    local ctx
    ctx=$(sb_read_context)

    echo "=== SessionBridge Status ==="
    echo ""

    local sid
    sid=$(echo "$ctx" | jq -r '.session_id // "unknown"')
    local started
    started=$(echo "$ctx" | jq -r '.started_at // "unknown"')
    echo "Session ID:  ${sid}"
    echo "Started at:  ${started}"

    local summary
    summary=$(echo "$ctx" | jq -r '.summary // ""')
    echo "Summary:     ${summary}"
    echo ""

    local active_tasks
    active_tasks=$(echo "$ctx" | jq -r '.active_tasks[] // empty' 2>/dev/null)
    if [ -n "$active_tasks" ]; then
        echo "Active Tasks:"
        echo "$active_tasks" | while IFS= read -r task; do
            echo "  * ${task}"
        done
        echo ""
    fi

    local completed
    completed=$(echo "$ctx" | jq -r '.completed_tasks[-5:][] // empty' 2>/dev/null)
    if [ -n "$completed" ]; then
        echo "Recent Completed:"
        echo "$completed" | while IFS= read -r task; do
            echo "  * ${task}"
        done
        echo ""
    fi

    local decision_count
    decision_count=$(echo "$ctx" | jq -r '.recent_decisions | length' 2>/dev/null)
    local file_count
    file_count=$(echo "$ctx" | jq -r '.recent_files | length' 2>/dev/null)
    local event_count
    event_count=$(sb_event_count)

    echo "Decisions logged:  ${decision_count:-0}"
    echo "Files touched:     ${file_count:-0}"
    echo "Total events:      ${event_count}"
    echo ""
}

# Generate a comprehensive natural-language session summary
# Usage: sb_summary_report
# End the current session with an automatic summary
# Usage: sb_session_end [reason]
sb_session_end() {
    local reason="${1:-completed}"
    sb_log session_end "$(jq -n --arg reason "$reason" '{"reason":$reason}')"
    echo "Session ended: ${reason}"
    echo ""
    sb_summary_report
}

# Log a heartbeat event with session status
# Usage: sb_heartbeat
sb_heartbeat() {
    local ctx
    ctx=$(sb_read_context)
    local event_count task_count summary_val
    event_count=$(sb_event_count)
    task_count=$(echo "$ctx" | jq -r '.active_tasks | length' 2>/dev/null || echo 0)
    summary_val=$(echo "$ctx" | jq -r '.summary // ""')
    
    sb_log heartbeat "$(jq -n \
        --argjson events "$event_count" \
        --argjson tasks "$task_count" \
        --arg summary "$summary_val" \
        '{"events":$events,"active_tasks":$tasks,"summary":$summary}')"
    
    local sid
    sid=$(echo "$ctx" | jq -r '.session_id // "unknown"')
    echo "Heartbeat: ${event_count} events, ${task_count} active tasks — ${summary_val}"
}

sb_summary_report() {
    if ! sb_is_initialized; then
        echo "SessionBridge: NOT INITIALIZED"
        echo "Run: bridge.sh init to start tracking"
        return
    fi

    local ctx
    ctx=$(sb_read_context)

    local sid started summary
    sid=$(echo "$ctx" | jq -r '.session_id // "unknown"')
    started=$(echo "$ctx" | jq -r '.started_at // "unknown"')
    summary=$(echo "$ctx" | jq -r '.summary // "(no description)"')

    local active_count completed_count decision_count file_count event_count
    active_count=$(echo "$ctx" | jq -r '.active_tasks | length' 2>/dev/null)
    completed_count=$(echo "$ctx" | jq -r '.completed_tasks | length' 2>/dev/null)
    decision_count=$(echo "$ctx" | jq -r '.recent_decisions | length' 2>/dev/null)
    file_count=$(echo "$ctx" | jq -r '.recent_files | length' 2>/dev/null)
    event_count=$(sb_event_count)

    local bookmark_count=0
    if [ -d "${BOOKMARKS_DIR}" ]; then
        # shellcheck disable=SC2012
        local files
        files=$(ls "${BOOKMARKS_DIR}"/*.json 2>/dev/null || true)
        if [ -n "$files" ]; then
            bookmark_count=$(echo "$files" | wc -l)
        fi
    fi

    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║        SessionBridge Session Summary      ║"
    echo "╚═══════════════════════════════════════════╝"
    echo ""
    echo "  Session:     ${summary}"
    echo "  ID:          ${sid}"
    echo "  Started:     ${started}"
    echo ""
    echo "  ── Activity ──"
    echo "  Total events:     ${event_count}"
    echo "  Active tasks:     ${active_count}"
    echo "  Completed tasks:  ${completed_count}"
    echo "  Decisions made:   ${decision_count}"
    echo "  Files touched:    ${file_count}"
    echo "  Bookmarks saved:  ${bookmark_count}"
    echo ""

    # Active tasks
    local active_tasks
    active_tasks=$(echo "$ctx" | jq -r '.active_tasks[] // empty' 2>/dev/null)
    if [ -n "$active_tasks" ]; then
        echo "  ── Active Tasks ──"
        echo "$active_tasks" | while IFS= read -r task; do
            echo "    ◇ ${task}"
        done
        echo ""
    fi

    # Recent completed (last 5)
    local recent_completed
    recent_completed=$(echo "$ctx" | jq -r '.completed_tasks[-5:][] // empty' 2>/dev/null)
    if [ -n "$recent_completed" ]; then
        echo "  ── Recently Completed ──"
        echo "$recent_completed" | while IFS= read -r task; do
            echo "    ✓ ${task}"
        done
        echo ""
    fi

    # Bookmark list
    if [ -d "${BOOKMARKS_DIR}" ]; then
        local bookmarks
        bookmarks=$(ls "${BOOKMARKS_DIR}"/*.json 2>/dev/null | xargs -I{} basename {} .json || true)
        if [ -n "$bookmarks" ]; then
            echo "  ── Bookmarks ──"
            echo "$bookmarks" | while IFS= read -r bm; do
                echo "    🔖 ${bm}"
            done
            echo ""
        fi
    fi

    # Recent decisions (last 3)
    local recent_decisions
    recent_decisions=$(echo "$ctx" | jq -r '.recent_decisions[-3:] | .[] | "\(.what): \(.why)"' 2>/dev/null)
    if [ -n "$recent_decisions" ]; then
        echo "  ── Recent Decisions ──"
        echo "$recent_decisions" | while IFS= read -r dec; do
            echo "    • ${dec}"
        done
        echo ""
    fi

    # Last 5 events (latest types)
    if [ -f "${EVENTS_FILE}" ]; then
        local recent_events
        recent_events=$(tail -5 "${EVENTS_FILE}" | jq -r '"    [\(.e)] \(.data | tostring | .[0:60])"' 2>/dev/null)
        if [ -n "$recent_events" ]; then
            echo "  ── Last Events ──"
            echo "$recent_events"
            echo ""
        fi
    fi

    # Tips
    echo "  ── Tips ──"
    echo "    • bridge.sh bookmark save <name>  — snapshot this state"
    echo "    • bridge.sh bookmark list          — see saved snapshots"
    echo "    • bridge.sh recent 10              — see recent events"
    echo ""
}
