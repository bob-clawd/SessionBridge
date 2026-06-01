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
