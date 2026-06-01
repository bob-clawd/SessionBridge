# SessionBridge — Bookmark Management
# Save and restore context snapshots

# Save a bookmark
# Usage: sb_bookmark_save <name>
sb_bookmark_save() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "Error: bookmark name required" >&2
        return 1
    fi

    local bookmark_file="${BOOKMARKS_DIR}/${name}.json"
    local ctx
    ctx=$(sb_read_context)

    # Add metadata to the bookmark
    local saved_at
    saved_at=$(sb_timestamp)
    echo "$ctx" | jq --arg ts "$saved_at" '. + {"bookmarked_at": $ts}' > "${bookmark_file}"

    if [ $? -eq 0 ]; then
        sb_log bookmark_save "{\"name\":\"${name}\"}"
        echo "Bookmark '${name}' saved."
    else
        echo "Error: failed to save bookmark" >&2
        return 1
    fi
}

# Restore a bookmark
# Usage: sb_bookmark_restore <name>
sb_bookmark_restore() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "Error: bookmark name required" >&2
        return 1
    fi

    local bookmark_file="${BOOKMARKS_DIR}/${name}.json"
    if [ ! -f "${bookmark_file}" ]; then
        echo "Error: bookmark '${name}' not found" >&2
        return 1
    fi

    # Restore the saved context (strip bookmarked_at metadata)
    cat "${bookmark_file}" | jq 'del(.bookmarked_at)' | sb_write_context
    sb_log bookmark_restore "{\"name\":\"${name}\"}"

    echo "Bookmark '${name}' restored."
    echo "Context snapshot from: $(cat "${bookmark_file}" | jq -r '.bookmarked_at // "unknown"')"
}

# List all bookmarks
# Usage: sb_bookmark_list
sb_bookmark_list() {
    if [ ! -d "${BOOKMARKS_DIR}" ]; then
        echo "No bookmarks."
        return
    fi

    local count
    count=$(ls "${BOOKMARKS_DIR}"/*.json 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        echo "No bookmarks."
        return
    fi

    echo "Bookmarks:"
    for f in "${BOOKMARKS_DIR}"/*.json; do
        local name
        name=$(basename "$f" .json)
        local saved_at
        saved_at=$(cat "$f" | jq -r '.bookmarked_at // "unknown"' 2>/dev/null)
        local summary
        summary=$(cat "$f" | jq -r '.summary // ""' 2>/dev/null)
        echo "  ${name}  (${saved_at})"
        if [ -n "$summary" ]; then
            echo "    ↳ ${summary}"
        fi
    done
}

# Delete a bookmark
# Usage: sb_bookmark_delete <name>
sb_bookmark_delete() {
    local name="$1"
    local bookmark_file="${BOOKMARKS_DIR}/${name}.json"
    if [ ! -f "${bookmark_file}" ]; then
        echo "Error: bookmark '${name}' not found" >&2
        return 1
    fi
    rm "${bookmark_file}"
    echo "Bookmark '${name}' deleted."
}
