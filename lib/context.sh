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

    cat <<JSON | sb_write_context
{
  "session_id": "${session_id}",
  "started_at": "${started_at}",
  "active_tasks": [],
  "completed_tasks": [],
  "recent_decisions": [],
  "recent_files": [],
  "tags": {},
  "summary": "${summary}"
}
JSON

    echo "$session_id"
}

# Update context field (merge)
# Usage: sb_context_set <jq_filter>
# Example: sb_context_set '.summary = "Working on X"'
sb_context_set() {
    local filter="$1"
    local ctx
    ctx=$(sb_read_context)

    echo "$ctx" | jq "$filter" | sb_write_context
}

# Add a task to active_tasks
# Usage: sb_add_task <task_name>
sb_add_task() {
    local task="$1"
    sb_context_set ".active_tasks += [\"${task}\"]"
    sb_log task_start "{\"task\":\"${task}\"}"
}

# Mark a task as completed
# Usage: sb_complete_task <task_name>
sb_complete_task() {
    local task="$1"
    sb_context_set ".active_tasks -= [\"${task}\"] | .completed_tasks += [\"${task}\"]"
    sb_log task_end "{\"task\":\"${task}\",\"result\":\"completed\"}"
}

# Add a decision
# Usage: sb_add_decision <what> <why>
sb_add_decision() {
    local what="$1"
    local why="$2"
    local entry
    entry=$(printf '{"what":"%s","why":"%s"}' "$what" "$why")
    sb_context_set ".recent_decisions = .recent_decisions[:19] + [${entry}]"
    sb_log decision "$entry"
}

# Record a file touch
# Usage: sb_touch_file <path> <action>
sb_touch_file() {
    local path="$1"
    local action="${2:-read}"
    local entry
    entry=$(printf '{"path":"%s","action":"%s"}' "$path" "$action")
    sb_context_set ".recent_files = .recent_files[:49] + [${entry}]"
    sb_log file_touch "$entry"
}

# Get the current context summary
sb_summary() {
    sb_read_context | jq -r '.summary // "No summary"' 2>/dev/null
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
