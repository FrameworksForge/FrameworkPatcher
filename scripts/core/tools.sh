#!/usr/bin/env bash
# scripts/core/tools.sh
# Environment initialization and tool checks

init_env() {
    # Allow overriding from environment before calling init_env
    : "${TOOLS_DIR:=${PWD}/tools}"
    : "${WORK_DIR:=${PWD}}"
    : "${BACKUP_DIR:=${WORK_DIR}/backup}"
    : "${MAGISK_TEMPLATE_DIR:=magisk_module}" # template dir for create_magisk_module
    mkdir -p "$BACKUP_DIR"
}

ensure_tools() {
    # Checks for java, apktool.jar and 7z (optional)
    if ! command -v java >/dev/null 2>&1; then
        err "java not found in PATH"
        return 1
    fi

    if [ ! -f "${TOOLS_DIR}/apktool.jar" ]; then
        err "apktool.jar not found at ${TOOLS_DIR}/apktool.jar"
        return 1
    fi

    if ! command -v 7z >/dev/null 2>&1; then
        warn "7z not found in PATH — create_magisk_module will try to use zip if available"
    fi

    if ! command -v zip >/dev/null 2>&1; then
        warn "zip not found in PATH — D8 optimization and module creation may fail"
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        err "unzip not found in PATH"
        return 1
    fi

    # Check for d8 (needed for optimization)
    if [ -z "${D8_CMD:-}" ]; then
        if command -v d8 >/dev/null 2>&1; then
            export D8_CMD="d8"
        elif [ -d "$HOME/android-sdk/build-tools" ]; then
            # Find the latest build-tools version
            local latest_build_tool
            latest_build_tool=$(ls -1 "$HOME/android-sdk/build-tools" | sort -V | tail -n1)
            if [ -n "$latest_build_tool" ] && [ -x "$HOME/android-sdk/build-tools/$latest_build_tool/d8" ]; then
                export D8_CMD="$HOME/android-sdk/build-tools/$latest_build_tool/d8"
                log "Found d8 at $D8_CMD"
            fi
        elif [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}/build-tools" ]; then
             # Try ANDROID_HOME if set
            local latest_build_tool
            latest_build_tool=$(ls -1 "${ANDROID_HOME}/build-tools" | sort -V | tail -n1)
            if [ -n "$latest_build_tool" ] && [ -x "${ANDROID_HOME}/build-tools/$latest_build_tool/d8" ]; then
                export D8_CMD="${ANDROID_HOME}/build-tools/$latest_build_tool/d8"
                log "Found d8 at $D8_CMD"
            fi
        fi
    fi
    
    if [ -z "${D8_CMD:-}" ]; then
        warn "d8 not found. JAR optimization will be skipped."
    fi

    return 0
}
