#!/usr/bin/env bash
# scripts/core/manifest.sh
# Build manifest generation for traceability and reproducibility.

# Requires: PATCH_ENGINE_VERSION (from version.sh)
# Usage:    generate_manifest <device> <base_rom> <android_version> <api_level> <features_csv> [workflow_run_id] [workflow_url]
# Output:   writes build-manifest.json to $WORK_DIR (or cwd)

generate_manifest() {
    local device="$1"
    local base_rom="$2"
    local android_version="$3"
    local api_level="$4"
    local features_csv="$5"
    local workflow_run_id="${6:-local}"
    local workflow_url="${7:-}"

    local manifest_file="${WORK_DIR:-.}/build-manifest.json"
    local git_commit git_branch build_time

    git_commit="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
    git_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
    build_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Build features JSON array from CSV
    local features_json="[]"
    if [ -n "$features_csv" ]; then
        features_json=$(echo "$features_csv" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
            awk 'BEGIN{printf "["} NR>1{printf ","} {printf "\"%s\"", $0} END{printf "]"}')
    fi

    # Collect checksums of produced artifacts
    local checksums_json="{"
    local first=1
    for artifact in framework_patched.jar services_patched.jar miui-services_patched.jar miui-framework_patched.jar; do
        if [ -f "${WORK_DIR:-.}/$artifact" ]; then
            local hash
            hash="$(sha256sum "${WORK_DIR:-.}/$artifact" | cut -d' ' -f1)"
            [ $first -eq 0 ] && checksums_json+=","
            checksums_json+="\"${artifact}\": \"sha256:${hash}\""
            first=0
        fi
    done
    checksums_json+="}"

    # Read tool versions from lock file
    local apktool_version="unknown"
    local lock_file="${WORK_DIR:-.}/tools/versions.lock"
    if [ -f "$lock_file" ] && command -v python3 >/dev/null 2>&1; then
        apktool_version=$(python3 -c "
import json, sys
try:
    d = json.load(open('$lock_file'))
    print(d.get('apktool', {}).get('version', 'unknown'))
except:
    print('unknown')
" 2>/dev/null)
    fi

    cat > "$manifest_file" <<MANIFEST_EOF
{
  "schema_version": "1.0",
  "patch_engine_version": "${PATCH_ENGINE_VERSION:-unknown}",
  "git_commit": "${git_commit}",
  "git_branch": "${git_branch}",
  "device": "${device}",
  "base_rom": "${base_rom}",
  "android_version": "${android_version}",
  "api_level": "${api_level}",
  "features": ${features_json},
  "build_time": "${build_time}",
  "checksums": ${checksums_json},
  "tool_versions": {
    "apktool": "${apktool_version}"
  },
  "workflow_run_id": "${workflow_run_id}",
  "workflow_url": "${workflow_url}"
}
MANIFEST_EOF

    echo "[INFO] Build manifest written to $manifest_file"
}

# Add module ZIP checksum after creation
update_manifest_with_zip_checksum() {
    local zip_file="$1"
    local manifest_file="${WORK_DIR:-.}/build-manifest.json"

    if [ -f "$zip_file" ] && [ -f "$manifest_file" ] && command -v python3 >/dev/null 2>&1; then
        local zip_hash
        zip_hash="$(sha256sum "$zip_file" | cut -d' ' -f1)"
        python3 -c "
import json, sys
try:
    with open('$manifest_file', 'r') as f:
        m = json.load(f)
    m['checksums']['module_zip'] = 'sha256:$zip_hash'
    with open('$manifest_file', 'w') as f:
        json.dump(m, f, indent=2)
except Exception as e:
    print(f'[WARN] Failed to update manifest with ZIP checksum: {e}', file=sys.stderr)
"
        echo "[INFO] Updated manifest with module ZIP checksum"
    fi
}
