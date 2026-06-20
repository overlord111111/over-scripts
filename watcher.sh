#!/usr/bin/env bash
# ============================================================================
# watcher.sh — Monitor a directory for changes (inotify or polling).
#
# Uses inotifywait when available (Linux), falls back to stat-based polling
# on systems without inotify (macOS, WSL older kernels, etc.).
#
# Usage:
#   ./watcher.sh /path/to/watch
#   ./watcher.sh /path/to/watch --poll-interval 2
#   ./watcher.sh /path/to/watch --log watcher.log --exclude '\.tmp$'
#   ./watcher.sh /path/to/watch --recursive --events create,delete
# ============================================================================

set -euo pipefail

# ---- defaults ---------------------------------------------------------------
WATCH_DIR=""
LOG_FILE=""
POLL_INTERVAL=1
RECURSIVE=false
EXCLUDE_PATTERN=""
EVENTS="create,delete,modify,move"
VERBOSE=false

# ---- helpers ----------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <directory> [options]

Monitor a directory for file-system changes and log them.

Options:
  --log FILE          Write change log to FILE (default: stdout)
  --poll-interval N   Polling interval in seconds (default: 1, only used
                      when inotifywait is unavailable)
  --recursive, -r     Watch subdirectories recursively
  --events LIST       Comma-separated events to watch (default: create,delete,
                      modify,move). Used only with inotifywait.
  --exclude PATTERN   Regex pattern to exclude paths (egrep syntax)
  --verbose, -v       Print extra info during startup
  --help, -h          Show this help and exit

Examples:
  ./watcher.sh /var/log --log /tmp/watcher.log
  ./watcher.sh ~/projects --recursive --exclude '\.(git|pyc)$'
  ./watcher.sh /data/uploads --poll-interval 5 --log changes.log
EOF
    exit 0
}

log_msg() {
    local level="$1"
    shift
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    fi
}

# ---- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage ;;
        --log) shift; LOG_FILE="$1"; shift ;;
        --poll-interval) shift; POLL_INTERVAL="$1"; shift ;;
        --recursive|-r) RECURSIVE=true; shift ;;
        --events) shift; EVENTS="$1"; shift ;;
        --exclude) shift; EXCLUDE_PATTERN="$1"; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        --*) echo "Unknown option: $1"; usage ;;
        *)  if [[ -z "$WATCH_DIR" ]]; then
                WATCH_DIR="$1"
            else
                echo "Unexpected argument: $1"
                usage
            fi
            shift ;;
    esac
done

if [[ -z "$WATCH_DIR" ]]; then
    echo "ERROR: missing <directory> argument"
    usage
fi

if [[ ! -d "$WATCH_DIR" ]]; then
    echo "ERROR: '$WATCH_DIR' is not a directory"
    exit 1
fi

# Resolve to absolute path
WATCH_DIR="$(cd "$WATCH_DIR" && pwd)"

$VERBOSE && echo "Watching: $WATCH_DIR"
$VERBOSE && echo "Poll interval: ${POLL_INTERVAL}s"

# ---- inotify backend -------------------------------------------------------
use_inotify=false
if command -v inotifywait &>/dev/null; then
    use_inotify=true
fi

if $use_inotify; then
    $VERBOSE && echo "Backend: inotifywait"

    # Build args
    INOTIFY_ARGS=(-m --timefmt '%Y-%m-%d %H:%M:%S' --format '%T|%w%f|%e|%f')
    if $RECURSIVE; then
        INOTIFY_ARGS+=(-r)
    fi
    INOTIFY_ARGS+=(--event "$(echo "$EVENTS" | tr ',' ' ')" )
    INOTIFY_ARGS+=("$WATCH_DIR")

    log_msg "INFO" "Started watching (inotify): $WATCH_DIR"

    inotifywait "${INOTIFY_ARGS[@]}" 2>/dev/null | while IFS='|' read -r ts path event file; do
        if [[ -n "$EXCLUDE_PATTERN" ]]; then
            echo "$path" | grep -qE "$EXCLUDE_PATTERN" && continue
        fi
        log_msg "CHANGE" "$event | $path"
    done

# ---- polling backend -------------------------------------------------------
else
    $VERBOSE && echo "Backend: polling (inotifywait not found)"
    log_msg "INFO" "Started watching (polling, interval=${POLL_INTERVAL}s): $WATCH_DIR"

    # Collect initial snapshot
    declare -A snapshot
    if $RECURSIVE; then
        while IFS= read -r -d '' f; do
            snapshot["$f"]="$(stat -c '%Y.%s' "$f" 2>/dev/null || echo 0)"
        done < <(find "$WATCH_DIR" -type f -print0 2>/dev/null)
    else
        for f in "$WATCH_DIR"/*; do
            [[ -f "$f" ]] || continue
            snapshot["$f"]="$(stat -c '%Y.%s' "$f" 2>/dev/null || echo 0)"
        done
    fi

    while true; do
        sleep "$POLL_INTERVAL"
        local new_snapshot=()
        if $RECURSIVE; then
            while IFS= read -r -d '' f; do
                new_snapshot+=("$f")
            done < <(find "$WATCH_DIR" -type f -print0 2>/dev/null)
        else
            for f in "$WATCH_DIR"/*; do
                [[ -f "$f" ]] || continue
                new_snapshot+=("$f")
            done
        fi

        # Check for deleted / modified
        for old_f in "${!snapshot[@]}"; do
            if [[ ! -f "$old_f" ]]; then
                [[ -n "$EXCLUDE_PATTERN" ]] && echo "$old_f" | grep -qE "$EXCLUDE_PATTERN" && continue
                log_msg "CHANGE" "delete | $old_f"
                unset snapshot["$old_f"]
            else
                new_mtime="$(stat -c '%Y.%s' "$old_f" 2>/dev/null || echo 0)"
                if [[ "${snapshot[$old_f]}" != "$new_mtime" ]]; then
                    [[ -n "$EXCLUDE_PATTERN" ]] && echo "$old_f" | grep -qE "$EXCLUDE_PATTERN" && continue
                    log_msg "CHANGE" "modify | $old_f"
                    snapshot["$old_f"]="$new_mtime"
                fi
            fi
        done

        # Check for new files
        for new_f in "${new_snapshot[@]}"; if [[ -z "${snapshot[$new_f]:-}" ]]; then
            snapshot["$new_f"]="$(stat -c '%Y.%s' "$new_f" 2>/dev/null || echo 0)"
            [[ -n "$EXCLUDE_PATTERN" ]] && echo "$new_f" | grep -qE "$EXCLUDE_PATTERN" && continue
            log_msg "CHANGE" "create | $new_f"
        fi; done
    done
fi
