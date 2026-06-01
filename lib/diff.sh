# SessionBridge — Context Diff
# Compare current context against a saved bookmark

# Diff current context against a saved bookmark
# Usage: sb_diff <bookmark_name>
sb_diff() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "Error: bookmark name required" >&2
        return 1
    fi

    local bookmark_file="${BOOKMARKS_DIR}/${name}.json"
    if [ ! -f "${bookmark_file}" ]; then
        echo "Error: bookmark '${name}' not found at ${bookmark_file}" >&2
        return 1
    fi

    if ! sb_is_initialized; then
        echo "Error: no active session" >&2
        return 1
    fi

    local ctx
    ctx=$(sb_read_context)
    local bm
    bm=$(cat "${bookmark_file}")

    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║       SessionBridge Context Diff          ║"
    echo "╚═══════════════════════════════════════════╝"
    echo ""
    echo "  Comparing: current vs bookmark '${name}'"
    echo ""

    local bm_time
    bm_time=$(echo "$bm" | jq -r '.bookmarked_at // "unknown"')
    echo "  Bookmark saved at: ${bm_time}"
    echo ""

    # Compare summary
    local current_summary
    current_summary=$(echo "$ctx" | jq -r '.summary // ""')
    local bm_summary
    bm_summary=$(echo "$bm" | jq -r '.summary // ""')
    if [ "$current_summary" != "$bm_summary" ]; then
        echo "  › Summary changed:"
        echo "      Was: ${bm_summary}"
        echo "      Now: ${current_summary}"
        echo ""
    fi

    # Compare active tasks
    local current_tasks
    current_tasks=$(echo "$ctx" | jq -r '.active_tasks[] // empty' 2>/dev/null | sort)
    local bm_tasks
    bm_tasks=$(echo "$bm" | jq -r '.active_tasks[] // empty' 2>/dev/null | sort)

    local added_tasks
    added_tasks=$(comm -13 <(echo "$bm_tasks") <(echo "$current_tasks") 2>/dev/null || echo "")
    local removed_tasks
    removed_tasks=$(comm -23 <(echo "$bm_tasks") <(echo "$current_tasks") 2>/dev/null || echo "")

    if [ -n "$added_tasks" ] || [ -n "$removed_tasks" ]; then
        echo "  ── Active Tasks ──"
        if [ -n "$added_tasks" ]; then
            echo "$added_tasks" | while IFS= read -r task; do
                [ -n "$task" ] && echo "    + ${task}"
            done
        fi
        if [ -n "$removed_tasks" ]; then
            echo "$removed_tasks" | while IFS= read -r task; do
                [ -n "$task" ] && echo "    - ${task}"
            done
        fi
        echo ""
    fi

    # Compare completed tasks
    local current_completed
    current_completed=$(echo "$ctx" | jq -r '.completed_tasks[] // empty' 2>/dev/null | sort)
    local bm_completed
    bm_completed=$(echo "$bm" | jq -r '.completed_tasks[] // empty' 2>/dev/null | sort)

    local new_completed
    new_completed=$(comm -13 <(echo "$bm_completed") <(echo "$current_completed") 2>/dev/null || echo "")

    if [ -n "$new_completed" ]; then
        echo "  ── Newly Completed Tasks ──"
        echo "$new_completed" | while IFS= read -r task; do
            [ -n "$task" ] && echo "    ✓ ${task}"
        done
        echo ""
    fi

    # Compare decisions
    local current_decisions
    current_decisions=$(echo "$ctx" | jq -r '.recent_decisions[] | "\(.what): \(.why)"' 2>/dev/null | sort)
    local bm_decisions
    bm_decisions=$(echo "$bm" | jq -r '.recent_decisions[] | "\(.what): \(.why)"' 2>/dev/null | sort)

    local new_decisions
    new_decisions=$(comm -13 <(echo "$bm_decisions") <(echo "$current_decisions") 2>/dev/null || echo "")

    if [ -n "$new_decisions" ]; then
        echo "  ── New Decisions ──"
        echo "$new_decisions" | while IFS= read -r dec; do
            [ -n "$dec" ] && echo "    • ${dec}"
        done
        echo ""
    fi

    # Compare files
    local current_files
    current_files=$(echo "$ctx" | jq -r '.recent_files[] | "\(.path) (\(.action))"' 2>/dev/null | sort)
    local bm_files
    bm_files=$(echo "$bm" | jq -r '.recent_files[] | "\(.path) (\(.action))"' 2>/dev/null | sort)

    local new_files
    new_files=$(comm -13 <(echo "$bm_files") <(echo "$current_files") 2>/dev/null || echo "")

    if [ -n "$new_files" ]; then
        echo "  ── New Files Touched ──"
        echo "$new_files" | while IFS= read -r f; do
            [ -n "$f" ] && echo "    📄 ${f}"
        done
        echo ""
    fi

    # Compare event counts
    local current_events
    current_events=$(sb_event_count)
    local bm_events
    if [ -f "${EVENTS_FILE}" ]; then
        bm_events=$(wc -l < "${EVENTS_FILE}" | tr -d ' ')
        # Parse events that happened after the bookmark timestamp
        local bm_ts
        bm_ts=$(echo "$bm" | jq -r '.bookmarked_at // ""')
        if [ -n "$bm_ts" ] && [ "$bm_ts" != "unknown" ]; then
            local events_since
            events_since=$(grep -c "^{\"t\":\"[^\"]*\",\"e\":\"[^\"]*\"" "${EVENTS_FILE}" 2>/dev/null || echo 0)
            echo "  Total events in log: ${current_events}"
        fi
    fi

    if [ "$current_summary" = "$bm_summary" ] && \
       [ -z "$added_tasks" ] && [ -z "$removed_tasks" ] && \
       [ -z "$new_completed" ] && [ -z "$new_decisions" ] && [ -z "$new_files" ]; then
        echo "  ✓ No changes since bookmark."
    fi
    echo ""
}
