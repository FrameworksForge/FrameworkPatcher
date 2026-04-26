#!/usr/bin/env bash
# scripts/core/apk_ops.sh
# APK/JAR manipulation functions

backup_original_jar() {
    local jar_file="$1"
    local base_name
    base_name=$(basename "$jar_file" .jar)
    mkdir -p "$BACKUP_DIR/$base_name"
    # Save META-INF and res if present (silently ignore missing)
    unzip -o "$jar_file" "META-INF/*" "res/*" -d "$BACKUP_DIR/$base_name" >/dev/null 2>&1 || true
    # Also copy whole jar for safety
    cp -a "$jar_file" "$BACKUP_DIR/${base_name}.orig.jar"
    log "Backed up $jar_file -> $BACKUP_DIR/$base_name"
}

decompile_jar() {
    local jar_file="$1"
    local base_name
    base_name=$(basename "$jar_file" .jar)
    local output_dir="${WORK_DIR}/${base_name}_decompile"

    log "Decompiling $jar_file -> $output_dir (apktool)"
    rm -rf "$output_dir" "$base_name" >/dev/null 2>&1 || true
    mkdir -p "$output_dir"

    backup_original_jar "$jar_file"

    java -jar "${TOOLS_DIR}/apktool.jar" d -q -f "$jar_file" -o "$output_dir" || {
        err "apktool failed to decompile $jar_file"
        return 1
    }

    # copy META-INF and res into unknown/ (keeps resources for later)
    mkdir -p "$output_dir/unknown"
    cp -r "$BACKUP_DIR/$base_name/res" "$output_dir/unknown/" 2>/dev/null || true
    cp -r "$BACKUP_DIR/$base_name/META-INF" "$output_dir/unknown/" 2>/dev/null || true

    log "Decompile finished: $output_dir"

    # Provide compatibility symlinks for tools expecting smali_classes* paths
    # Map classes -> smali and classesN -> smali_classesN if not already present
    if [ -d "$output_dir/classes" ] && [ ! -e "$output_dir/smali" ]; then
        ln -s "classes" "$output_dir/smali" 2>/dev/null || true
    fi
    for n in 2 3 4 5 6 7 8 9; do
        if [ -d "$output_dir/classes${n}" ] && [ ! -e "$output_dir/smali_classes${n}" ]; then
            ln -s "classes${n}" "$output_dir/smali_classes${n}" 2>/dev/null || true
        fi
    done

    echo "$output_dir"
}

recompile_jar() {
    local jar_file="$1" # original jar file path (used only for name)
    local base_name
    base_name=$(basename "$jar_file" .jar)
    local output_dir="${WORK_DIR}/${base_name}_decompile"
    local patched_jar="${base_name}_patched.jar"

    log "Recompiling $output_dir -> $patched_jar"
    if [ ! -d "$output_dir" ]; then
        err "Recompile failed: decompile dir not found: $output_dir"
        return 1
    fi

    java -jar "${TOOLS_DIR}/apktool.jar" b -q -f "$output_dir" -o "$patched_jar" || {
        err "apktool build failed for $output_dir"
        return 1
    }

    log "Created patched JAR: $patched_jar"
    echo "$patched_jar"
}

d8_optimize_jar() {
    local jar_file="$1"
    
    # Configuration
    # API 30 (Android 11) is used to ensure compatibility with most build tools
    # while supporting recent DEX features.
    local MIN_API=30
    
    # Use the provided D8_CMD variable or default to 'd8'
    local d8_cmd="${D8_CMD:-d8}"
    
    if ! command -v "$d8_cmd" >/dev/null 2>&1; then
        echo "[WARN] d8 command not found. Skipping optimization."
        return 0
    fi

    if ! command -v zip >/dev/null 2>&1; then
        echo "[WARN] zip command not found. Skipping optimization."
        return 0
    fi

    echo "[INFO] Starting D8 DEX optimization for target: $(basename "$jar_file")"

    local work_dir="${jar_file}_opt_work"
    rm -rf "$work_dir"
    mkdir -p "$work_dir/raw"
    mkdir -p "$work_dir/out"

    # Backup the original JAR before modification in place
    cp "$jar_file" "${jar_file}.bak"

    # 1. Extract DEX files
    # We ignore resources and META-INF to process code only.
    echo "[INFO] Extracting DEX files..."
    if ! unzip -q -j "$jar_file" "*.dex" -d "$work_dir/raw"; then
        echo "[WARN] Failed to extract DEX files. Skipping optimization."
        mv "${jar_file}.bak" "$jar_file"
        rm -rf "$work_dir"
        return 0
    fi
    
    # Verify extraction
    if [ -z "$(ls -A "$work_dir/raw" 2>/dev/null)" ]; then
        echo "[WARN] No DEX files found in JAR. Skipping optimization."
        rm "${jar_file}.bak"
        rm -rf "$work_dir"
        return 0
    fi

    # 2. Execute D8
    # --release: Removes debug information (lines, source files) to reduce size.
    # --min-api: Ensures proper multidex partitioning.
    echo "[INFO] Executing D8 merge and redivision..."
    local d8_stderr="$work_dir/d8.stderr.log"
    if ! "$d8_cmd" "$work_dir/raw"/*.dex \
        --output "$work_dir/out" \
        --min-api "$MIN_API" \
        --release 2> >(tee "$d8_stderr" >&2); then
        if grep -qi "defined multiple times" "$d8_stderr" 2>/dev/null; then
            echo "[WARN] D8 skipped due to duplicate class definitions across input DEX files."
            echo "[WARN] Keeping rebuilt JAR without D8 optimization: $(basename "$jar_file")"
        else
            echo "[WARN] D8 compilation failed. Keeping rebuilt JAR without optimization."
        fi
        mv "${jar_file}.bak" "$jar_file"
        rm -rf "$work_dir"
        return 0
    fi

    # Check for output files (in case D8 exited 0 but produced nothing, e.g. API level warning)
    if [ -z "$(ls -A "$work_dir/out" 2>/dev/null)" ]; then
        echo "[WARN] D8 compilation produced no output. Keeping rebuilt JAR without optimization."
        mv "${jar_file}.bak" "$jar_file"
        rm -rf "$work_dir"
        return 0
    fi

    # 3. Update the JAR archive
    # Existing DEX files must be deleted first as the optimized output 
    # may contain fewer DEX files than the input.
    echo "[INFO] Updating JAR archive..."
    
    # Remove all existing .dex files from the archive
    if ! zip -d -q "$jar_file" "*.dex" 2>/dev/null; then
        echo "[WARN] Failed to remove existing DEX files. Result might be mixed."
        # Not fatal, zip -u might overwrite, but duplicates could exist if naming changes
    fi
    
    # Inject optimized .dex files
    local zip_success=0
    (
        cd "$work_dir/out" || exit 1
        zip -u -q -0 "../../$(basename "$jar_file")" classes*.dex
    ) && zip_success=1

    if [ $zip_success -ne 1 ]; then
        echo "[WARN] Failed to update JAR with optimized DEX files. Restoring rebuilt JAR without optimization."
        mv "${jar_file}.bak" "$jar_file"
        rm -rf "$work_dir"
        return 0
    fi

    # 4. Cleanup and Reporting
    local new_size
    new_size=$(du -h "$jar_file" | cut -f1)
    
    echo "[INFO] Optimization completed successfully."
    echo "[INFO] Final file size: $new_size"
    
    rm "${jar_file}.bak"
    rm -rf "$work_dir"
}
