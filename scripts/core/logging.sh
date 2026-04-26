#!/usr/bin/env bash
# scripts/core/logging.sh
# Logging and timing utilities

# Enhanced logging functions
log() { printf "%s\n" "[INFO] $*" >&2; }
warn() { printf "%s\n" "[WARN] $*" >&2; }
err() { printf "%s\n" "[ERROR] $*" >&2; }

# Progress indicator
show_progress() {
    local current="$1"
    local total="$2"
    local description="$3"
    local percent=$((current * 100 / total))
    printf "\r[%3d%%] %s" "$percent" "$description" >&2
}

# Timing functions
start_timer() {
    TIMER_START=$(date +%s)
}

end_timer() {
    local TIMER_END
    TIMER_END=$(date +%s)
    local duration=$((TIMER_END - TIMER_START))
    log "Operation completed in ${duration}s"
}
