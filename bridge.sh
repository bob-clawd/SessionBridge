#!/usr/bin/env bash
#
# SessionBridge — Agent session continuity tool
#
# Usage: bridge.sh <command> [args...]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library modules
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/context.sh"
source "${SCRIPT_DIR}/lib/bookmarks.sh"
source "${SCRIPT_DIR}/lib/diff.sh"
source "${SCRIPT_DIR}/lib/tags.sh"

# --- Help ---
show_help() {
    cat <<HELP
SessionBridge — Agent session continuity

USAGE:
  bridge.sh init [summary]    Initialize a new session (set SB_GC_KEEP for auto-GC)
  bridge.sh status            Show current session status
  bridge.sh summary           Show a comprehensive session summary with stats
  bridge.sh env               Emit shell env vars (source via: source <(bridge.sh env))
  bridge.sh log <type> [data] Log an event (data as JSON string)
  bridge.sh recent [n]        Show recent N events (default 10)
  bridge.sh diff <bookmark>   Compare current context with a saved bookmark
  bridge.sh gc [keep]         Garbage-collect events, keep last N (default 500)
  bridge.sh checkpoint [note] Save a checkpoint event
  bridge.sh task add <name>   Add an active task
  bridge.sh task done <name>  Mark task as completed
  bridge.sh touch <path> [act] Record a file touch (act: read/wrote/created)
  bridge.sh decision <what> [why] Log a decision
  bridge.sh tag list             List known tags with counts
  bridge.sh tag show <tag>       Show events by tag
  bridge.sh bookmark save <n> Save context as bookmark
  bridge.sh bookmark restore <n> Restore context from bookmark
  bridge.sh bookmark list     List saved bookmarks
  bridge.sh bookmark delete <n> Delete a bookmark

EXAMPLES:
  bridge.sh init "Working on logging module"
  bridge.sh log task_start '{"task":"implement log.sh"}'
  bridge.sh decision "Use JSONL" "Zero dependencies"
  bridge.sh touch src/main.py created
  bridge.sh recent 5
  bridge.sh bookmark save pre-refactor
  bridge.sh diff pre-refactor

SOURCE INTO AGENT (bash/zsh):
  source <(bridge.sh env)
  echo \"Session: \$SB_SESSION_ID\"
  echo \"Tasks: \$SB_ACTIVE_TASKS\"

HOUSEKEEPING:
  bridge.sh gc [keep=N]   Remove all but last N events from log

AUTO-GC:
  SB_GC_KEEP=500 bridge.sh init "My session"   Auto-GC on init
HELP
}

# --- Main dispatcher ---
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "${cmd}" in
        init)
            sb_require_jq
            local summary="${1:-Session initialized}"
            local keep_gc="${SB_GC_KEEP:-}"

            # Auto-GC: if SB_GC_KEEP is set, gc before init
            if [ -n "$keep_gc" ] && [ -f "${EVENTS_FILE}" ]; then
                sb_gc "$keep_gc" >/dev/null 2>&1 || true
            fi

            local session_id
            session_id=$(sb_init_context "${summary}")
            sb_log session_start "{\"reason\":\"init\",\"summary\":\"${summary}\"}" "${session_id}"
            echo "SessionBridge initialized."
            echo "Session ID: ${session_id}"
            if [ -n "${keep_gc}" ]; then
                echo "Auto-GC: keeping last ${keep_gc} events"
            fi
            ;;

        status)
            sb_require_jq
            sb_status
            ;;

        summary)
            sb_require_jq
            sb_summary_report
            ;;

        env)
            sb_require_jq
            sb_env
            ;;

        log)
            if [ $# -lt 1 ]; then
                echo "Usage: bridge.sh log <event_type> [json_data] [--tag tag1 tag2...]" >&2
                exit 1
            fi
            local event_type="$1"
            shift
            local data=""
            local tags=()
            local consuming_tags=0
            for arg in "$@"; do
                if [ "$arg" = "--tag" ]; then
                    consuming_tags=1
                elif [ $consuming_tags -eq 1 ]; then
                    tags+=("$arg")
                elif [ -z "$data" ]; then
                    data="$arg"
                fi
            done
            [ -z "$data" ] && data='{}'
            if [ ${#tags[@]} -gt 0 ]; then
                local tags_json
                tags_json=$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)
                data=$(echo "$data" | jq --argjson newtags "$tags_json" '.tags = (.tags // []) + $newtags | .tags |= unique' 2>/dev/null || echo "$data")
            fi
            sb_log "${event_type}" "${data}"
            ;;

        tag)
            local sub="${1:-}"
            shift 2>/dev/null || true
            sb_require_jq
            case "${sub}" in
                list)
                    sb_tag_list
                    ;;
                show)
                    local tag_name="${1:-}"
                    local tag_count="${2:-20}"
                    if [ -z "$tag_name" ]; then
                        echo "Usage: bridge.sh tag show <tag> [count]" >&2
                        exit 1
                    fi
                    sb_tag_show "${tag_name}" "${tag_count}"
                    ;;
                *)
                    echo "Usage: bridge.sh tag <list|show>" >&2
                    exit 1
            esac
            ;;

        recent)
            local count="${1:-10}"
            sb_recent "${count}"
            ;;

        diff)
            sb_require_jq
            local name="${1:-}"
            if [ -z "$name" ]; then
                echo "Usage: bridge.sh diff <bookmark_name>" >&2
                exit 1
            fi
            sb_diff "${name}"
            ;;

        gc)
            local keep="${1:-500}"
            sb_gc "${keep}"
            ;;

        checkpoint)
            local note="${1:-checkpoint}"
            sb_log checkpoint "{\"note\":\"${note}\"}"
            echo "Checkpoint logged."
            ;;

        task)
            local sub="${1:-}"
            shift || true
            case "${sub}" in
                add)   sb_require_jq; sb_add_task "${1:-unnamed}"; echo "Task added: ${1:-unnamed}" ;;
                done)  sb_require_jq; sb_complete_task "${1:-unnamed}"; echo "Task completed: ${1:-unnamed}" ;;
                *)     echo "Usage: bridge.sh task <add|done> <name>" >&2; exit 1 ;;
            esac
            ;;

        touch)
            local path="${1:-}"
            local action="${2:-touched}"
            if [ -z "$path" ]; then
                echo "Usage: bridge.sh touch <path> [action]" >&2
                exit 1
            fi
            sb_require_jq
            sb_touch_file "${path}" "${action}"
            echo "Logged: ${action} ${path}"
            ;;

        decision)
            local what="${1:-}"
            local why="${2:-}"
            if [ -z "$what" ]; then
                echo "Usage: bridge.sh decision <what> [why]" >&2
                exit 1
            fi
            sb_require_jq
            sb_add_decision "${what}" "${why}"
            echo "Decision logged: ${what}"
            ;;

        bookmark)
            local sub="${1:-}"
            shift || true
            sb_require_jq
            case "${sub}" in
                save)    sb_bookmark_save "${1:-}";;
                restore) sb_bookmark_restore "${1:-}";;
                list)    sb_bookmark_list;;
                delete)  sb_bookmark_delete "${1:-}";;
                *)       echo "Usage: bridge.sh bookmark <save|restore|list|delete> [name]" >&2; exit 1 ;;
            esac
            ;;

        help|--help|-h)
            show_help
            ;;

        *)
            echo "Unknown command: ${cmd}" >&2
            echo "Run 'bridge.sh help' for usage." >&2
            exit 1
            ;;
    esac
}

main "$@"
