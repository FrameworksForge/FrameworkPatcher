#!/usr/bin/env bash
# scripts/core/version.sh
# Reads the patch engine version from the VERSION file.
# Source this file to get PATCH_ENGINE_VERSION in your environment.

_VERSION_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/VERSION"

if [ ! -f "$_VERSION_FILE" ]; then
    echo "[ERROR] VERSION file not found at $_VERSION_FILE" >&2
    PATCH_ENGINE_VERSION="unknown"
else
    PATCH_ENGINE_VERSION="$(tr -d '[:space:]' < "$_VERSION_FILE")"
fi

export PATCH_ENGINE_VERSION
