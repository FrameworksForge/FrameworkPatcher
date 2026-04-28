#!/bin/bash

# Set up environment variables for GitHub workflow
TOOLS_DIR="$(pwd)/tools"
WORK_DIR="$(pwd)"
BACKUP_DIR="$WORK_DIR/backup"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# ============================================
# Feature Flags (set by command-line arguments)
# ============================================
FEATURE_DISABLE_SIGNATURE_VERIFICATION=0
FEATURE_KAORIOS_TOOLBOX=0
FEATURE_ADD_GBOARD=0

# Function to decompile JAR file
decompile_jar() {
    local jar_file="$1"
    local base_name
    base_name="$(basename "$jar_file" .jar)"
    local output_dir="$WORK_DIR/${base_name}_decompile"

    echo "Decompiling $jar_file with apktool..."

    # Validate JAR file before processing
    if [ ! -f "$jar_file" ]; then
        echo "❌ Error: JAR file $jar_file not found!"
        exit 1
    fi

    # Check if JAR file is valid ZIP
    if ! unzip -t "$jar_file" >/dev/null 2>&1; then
        echo "❌ Error: $jar_file is corrupted or not a valid ZIP file!"
        echo "File size: $(stat -c%s "$jar_file") bytes"
        echo "File type: $(file "$jar_file")"
        echo "This usually means the download was incomplete or corrupted."
        echo "Please check the download URL and try again."
        exit 1
    fi

    rm -rf "$output_dir" "$base_name"
    mkdir -p "$output_dir"

    mkdir -p "$BACKUP_DIR/$base_name"
    unzip -o "$jar_file" "META-INF/*" "res/*" -d "$BACKUP_DIR/$base_name" >/dev/null 2>&1

    # Run apktool with better error handling
    if ! java -jar "$TOOLS_DIR/apktool.jar" d -q -f "$jar_file" -o "$output_dir"; then
        echo "❌ Error: Failed to decompile $jar_file with apktool"
        echo "This may indicate the JAR file is corrupted or incompatible."
        echo "File size: $(stat -c%s "$jar_file") bytes"
        exit 1
    fi

    mkdir -p "$output_dir/unknown"
    cp -r "$BACKUP_DIR/$base_name/res" "$output_dir/unknown/" 2>/dev/null
    cp -r "$BACKUP_DIR/$base_name/META-INF" "$output_dir/unknown/" 2>/dev/null
}

# Function to recompile JAR file
recompile_jar() {
    local jar_file="$1"
    local base_name
    base_name="$(basename "$jar_file" .jar)"
    local output_dir="$WORK_DIR/${base_name}_decompile"
    local patched_jar="${base_name}_patched.jar"

    echo "Recompiling $jar_file with apktool..."

    # Check if decompiled directory exists
    if [ ! -d "$output_dir" ]; then
        echo "❌ Error: Decompiled directory $output_dir not found!"
        echo "This means the decompilation step failed."
        exit 1
    fi

    # Check if apktool.yml exists (required for recompilation)
    if [ ! -f "$output_dir/apktool.yml" ]; then
        echo "⚠️ Warning: apktool.yml not found in $output_dir"
        echo "This usually means the decompilation didn't create proper metadata."
        echo "Attempting to continue anyway..."
    fi

    # Run apktool with better error handling
    if ! java -jar "$TOOLS_DIR/apktool.jar" b -q -f "$output_dir" -o "$patched_jar"; then
        echo "❌ Error: Failed to recompile $output_dir with apktool"
        echo "This may indicate issues with the decompiled files."
        echo "Decompiled directory contents:"
        ls -la "$output_dir" || echo "Directory not accessible"
        exit 1
    fi

    echo "Created patched JAR: $patched_jar"
}

# Note: patching functions are sourced from helper.sh -> core/patching.sh


# ============================================
# Feature-specific patch functions for framework.jar
# ============================================

# Apply signature verification bypass patches to framework.jar (Android 14)
apply_framework_signature_patches() {
    local decompile_dir="$1"

    echo "Applying signature verification patches to framework.jar (Android 14)..."

    # Patch getMinimumSignatureSchemeVersionForTargetSdk to return 0
    echo "Patching getMinimumSignatureSchemeVersionForTargetSdk..."
    add_static_return_patch "getMinimumSignatureSchemeVersionForTargetSdk" 0 "$decompile_dir"

    # Patch verifyMessageDigest to return 1
    echo "Patching verifyMessageDigest..."
    add_static_return_patch "verifyMessageDigest" 1 "$decompile_dir"

    # Patch verifySignatures - find and patch invoke-interface result
    echo "Patching verifySignatures..."
    local file
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l "invoke-interface.*ParseResult;->isError()Z" 2>/dev/null | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-interface {v0}, Landroid/content/pm/parsing/result/ParseResult;->isError()Z"
        local linenos
        linenos=$(grep -nF "$pattern" "$file" | cut -d: -f1)

        if [ -n "$linenos" ]; then
            for lineno in $linenos; do
                local move_result_lineno=$((lineno + 1))
                local current_line
                current_line=$(sed -n "${move_result_lineno}p" "$file" | sed 's/^[ \t]*//')
                if [[ "$current_line" == "move-result v1" ]]; then
                    local indent
                    indent=$(sed -n "${move_result_lineno}p" "$file" | grep -o '^[ \t]*')
                    sed -i "$((move_result_lineno + 1))i\\
${indent}const/4 v1, 0x0" "$file"
                    echo "Patched verifySignatures at line $((move_result_lineno + 1))"
                    break
                fi
            done
        fi
    fi

    # Patch verifyV1Signature
    echo "Patching verifyV1Signature..."
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l "verifyV1Signature.*ParseInput.*Ljava/lang/String;Z" 2>/dev/null | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-static.*verifyV1Signature"
        local lineno
        lineno=$(grep -n "$pattern" "$file" | cut -d: -f1 | head -n1)
        if [ -n "$lineno" ]; then
            sed -i "${lineno}i\\
    const/4 p3, 0x0" "$file"
            echo "Patched verifyV1Signature at line $lineno"
        fi
    fi

    # Patch verifyV2Signature
    echo "Patching verifyV2Signature..."
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l "verifyV2Signature.*ParseInput.*Ljava/lang/String;Z" 2>/dev/null | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-static.*verifyV2Signature"
        local lineno
        lineno=$(grep -n "$pattern" "$file" | cut -d: -f1 | head -n1)
        if [ -n "$lineno" ]; then
            sed -i "${lineno}i\\
    const/4 p3, 0x0" "$file"
            echo "Patched verifyV2Signature at line $lineno"
        fi
    fi

    # Patch verifyV3Signature
    echo "Patching verifyV3Signature..."
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l "verifyV3Signature.*ParseInput.*Ljava/lang/String;Z" 2>/dev/null | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-static.*verifyV3Signature"
        local lineno
        lineno=$(grep -n "$pattern" "$file" | cut -d: -f1 | head -n1)
        if [ -n "$lineno" ]; then
            sed -i "${lineno}i\\
    const/4 p3, 0x0" "$file"
            echo "Patched verifyV3Signature at line $lineno"
        fi
    fi

    # Patch verifyV3AndBelowSignatures
    echo "Patching verifyV3AndBelowSignatures..."
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l "verifyV3AndBelowSignatures.*ParseInput.*Ljava/lang/String;IZ" 2>/dev/null | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-static.*verifyV3AndBelowSignatures"
        local lineno
        lineno=$(grep -n "$pattern" "$file" | cut -d: -f1 | head -n1)
        if [ -n "$lineno" ]; then
            sed -i "${lineno}i\\
    const/4 p3, 0x0" "$file"
            echo "Patched verifyV3AndBelowSignatures at line $lineno"
        fi
    fi

    # Patch checkCapability to return 1
    echo "Patching checkCapability..."
    add_static_return_patch "checkCapability" 1 "$decompile_dir"

    # Patch checkCapabilityRecover to return 1
    echo "Patching checkCapabilityRecover..."
    add_static_return_patch "checkCapabilityRecover" 1 "$decompile_dir"

    # Patch isPackageWhitelistedForHiddenApis to return 1
    echo "Patching isPackageWhitelistedForHiddenApis..."
    add_static_return_patch "isPackageWhitelistedForHiddenApis" 1 "$decompile_dir"

    # Patch StrictJarFile findEntry
    echo "Patching StrictJarFile findEntry..."
    file=$(find "$decompile_dir" -type f -name "StrictJarFile.smali" | head -n 1)
    if [ -f "$file" ]; then
        local start_line
        start_line=$(grep -n "invoke-virtual.*findEntry.*Ljava/util/zip/ZipEntry;" "$file" | cut -d: -f1 | head -n1)

        if [ -n "$start_line" ]; then
            local i=$((start_line + 1))
            local total_lines
            total_lines=$(wc -l <"$file")

            while [ "$i" -le "$total_lines" ]; do
                line=$(sed -n "${i}p" "$file")
                if [[ "$line" == *"if-eqz v6"* ]]; then
                    # Remove the if-eqz line
                    sed -i "${i}d" "$file"
                    echo "Removed if-eqz at line $i"
                    break
                fi
                i=$((i + 1))
            done
        fi
    fi

    echo "Signature verification patches applied to framework.jar (Android 14)"
}

# Main framework patching function
patch_framework() {
    local framework_path="$WORK_DIR/framework.jar"
    local decompile_dir="$WORK_DIR/framework_decompile"

    echo "Starting framework.jar patch..."

    # Check if any framework features are enabled
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ]; then
        echo "No framework features selected, skipping framework.jar"
        return 0
    fi

    # Decompile framework.jar
    decompile_jar "$framework_path"

    # Apply feature-specific patches based on flags
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ]; then
        apply_framework_signature_patches "$decompile_dir"
    fi

    if [ $FEATURE_KAORIOS_TOOLBOX -eq 1 ]; then
        # Source the Kaorios patching functions
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "${SCRIPT_DIR}/core/kaorios_patches.sh"
        apply_kaorios_toolbox_patches "$decompile_dir"
    fi

    # Recompile framework.jar
    recompile_jar "$framework_path"
    d8_optimize_jar "framework_patched.jar"

    # Clean up
    rm -rf "$WORK_DIR/framework" "$decompile_dir"

    if [ ! -f "framework_patched.jar" ]; then
        err "Critical Error: framework_patched.jar was not created."
        return 1
    fi

    echo "Framework.jar patching completed."
}

# ============================================
# Feature-specific patch functions for services.jar
# ============================================

# Apply signature verification bypass patches to services.jar (Android 14)
apply_services_signature_patches() {
    local decompile_dir="$1"

    echo "Applying signature verification patches to services.jar (Android 14)..."

    # Patch checkDowngrade to return-void
    echo "Patching checkDowngrade..."
    patch_return_void_method "checkDowngrade" "$decompile_dir"

    # Patch shouldCheckUpgradeKeySetLocked to return 0
    echo "Patching shouldCheckUpgradeKeySetLocked..."
    add_static_return_patch "shouldCheckUpgradeKeySetLocked" 0 "$decompile_dir"

    # Patch verifySignatures to return 0
    echo "Patching verifySignatures..."
    add_static_return_patch "verifySignatures" 0 "$decompile_dir"

    # Patch matchSignaturesCompat to return 1
    echo "Patching matchSignaturesCompat..."
    add_static_return_patch "matchSignaturesCompat" 1 "$decompile_dir"

    # Patch isPersistent check
    echo "Patching isPersistent check..."
    local file
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l "invoke-interface.*isPersistent()Z" 2>/dev/null | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-interface {v4}, Lcom/android/server/pm/pkg/AndroidPackage;->isPersistent()Z"
        local linenos
        linenos=$(grep -nF "$pattern" "$file" | cut -d: -f1)

        if [ -n "$linenos" ]; then
            for lineno in $linenos; do
                local move_result_lineno=$((lineno + 1))
                local current_line
                current_line=$(sed -n "${move_result_lineno}p" "$file" | sed 's/^[ \t]*//')
                if [[ "$current_line" == "move-result v2" ]]; then
                    local indent
                    indent=$(sed -n "${move_result_lineno}p" "$file" | grep -o '^[ \t]*')
                    sed -i "$((move_result_lineno + 1))i\\
${indent}const/4 v2, 0x0" "$file"
                    echo "Patched isPersistent check at line $((move_result_lineno + 1))"
                    break
                fi
            done
        fi
    fi

    echo "Signature verification patches applied to services.jar (Android 14)"
}

# Main services patching function
patch_services() {
    local services_path="$WORK_DIR/services.jar"
    local decompile_dir="$WORK_DIR/services_decompile"

    echo "Starting services.jar patch..."

    # Check if any services features are enabled
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ]; then
        echo "No services features selected, skipping services.jar"
        return 0
    fi

    # Decompile services.jar
    decompile_jar "$services_path"

    # Apply feature-specific patches based on flags
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ]; then
        apply_services_signature_patches "$decompile_dir"
    fi

    # Recompile services.jar
    recompile_jar "$services_path"
    d8_optimize_jar "services_patched.jar"

    # Clean up
    rm -rf "$WORK_DIR/services" "$decompile_dir"

    if [ ! -f "services_patched.jar" ]; then
        err "Critical Error: services_patched.jar was not created."
        return 1
    fi

    echo "Services.jar patching completed."
}

# ============================================
# Feature-specific patch functions for miui-services.jar
# ============================================

# Apply signature verification bypass patches to miui-services.jar (Android 14)
apply_miui_services_signature_patches() {
    local decompile_dir="$1"

    echo "Applying signature verification patches to miui-services.jar (Android 14)..."

    # Note: Android 14 miui-services.jar typically doesn't require signature patches
    # as most signature verification is handled in framework.jar and services.jar
    echo "No miui-services.jar signature patches required for Android 14"

    echo "Signature verification patches applied to miui-services.jar (Android 14)"
}

# Apply Gboard support patches to miui-services.jar (replace Baidu input with Gboard)
apply_miui_services_gboard_support() {
    local decompile_dir="$1"
    local search_string="com.baidu.input_mi"
    local replace_string="com.google.android.inputmethod.latin"

    echo "Applying Gboard support patches to miui-services.jar..."

    # Target smali files for Gboard support
    local gboard_classes=(
        "com/android/server/am/ActivityManagerServiceImpl\$1.smali"
        "com/android/server/input/InputManagerServiceStubImpl.smali"
        "com/android/server/inputmethod/InputMethodManagerServiceImpl.smali"
        "com/android/server/wm/MiuiSplitInputMethodImpl.smali"
    )

    for class_file in "${gboard_classes[@]}"; do
        local file
        file=$(find "$decompile_dir" -type f -path "*/${class_file}" | head -n 1)
        if [ -f "$file" ]; then
            echo "Replacing Baidu input with Gboard in $(basename "$file")..."
            sed -i "s/${search_string}/${replace_string}/g" "$file"
            echo "✓ Patched $(basename "$file")"
        else
            echo "⚠ File not found: $class_file"
        fi
    done

    echo "Gboard support patches applied to miui-services.jar"
}

# Main miui-services patching function
patch_miui_services() {
    local miui_services_path="$WORK_DIR/miui-services.jar"
    local decompile_dir="$WORK_DIR/miui-services_decompile"

    echo "Starting miui-services.jar patch..."

    # Check if any miui-services features are enabled
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] &&
        [ $FEATURE_ADD_GBOARD -eq 0 ]; then
        echo "No miui-services features selected, skipping miui-services.jar"
        return 0
    fi

    # Decompile miui-services.jar
    decompile_jar "$miui_services_path"

    # Apply feature-specific patches based on flags
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ]; then
        apply_miui_services_signature_patches "$decompile_dir"
    fi

    if [ $FEATURE_ADD_GBOARD -eq 1 ]; then
        apply_miui_services_gboard_support "$decompile_dir"
    fi

    # Recompile miui-services.jar
    recompile_jar "$miui_services_path"
    d8_optimize_jar "miui-services_patched.jar"

    # Clean up
    rm -rf "$WORK_DIR/miui-services" "$decompile_dir"

    if [ ! -f "miui-services_patched.jar" ]; then
        err "Critical Error: miui-services_patched.jar was not created."
        return 1
    fi

    echo "Miui-services.jar patching completed."
}

# ============================================
# Feature-specific patch functions for miui-framework.jar
# ============================================

# Apply Gboard support patches to miui-framework.jar (replace Baidu input with Gboard)
apply_miui_framework_gboard_support() {
    local decompile_dir="$1"
    local search_string="com.baidu.input_mi"
    local replace_string="com.google.android.inputmethod.latin"

    echo "Applying Gboard support patches to miui-framework.jar..."

    # Target smali files for Gboard support in miui-framework
    local gboard_classes=(
        "android/inputmethodservice/InputMethodServiceInjector.smali"
        "android/view/DisplayInfoInjector\$2.smali"
        "miui/util/HapticFeedbackUtil.smali"
    )

    for class_file in "${gboard_classes[@]}"; do
        local file
        file=$(find "$decompile_dir" -type f -path "*/${class_file}" | head -n 1)
        if [ -f "$file" ]; then
            echo "Replacing Baidu input with Gboard in $(basename "$file")..."
            sed -i "s/${search_string}/${replace_string}/g" "$file"
            echo "✓ Patched $(basename "$file")"
        else
            echo "⚠ File not found: $class_file"
        fi
    done

    echo "Gboard support patches applied to miui-framework.jar"
}

# Main miui-framework patching function
patch_miui_framework() {
    local miui_framework_path="$WORK_DIR/miui-framework.jar"
    local decompile_dir="$WORK_DIR/miui-framework_decompile"

    echo "Starting miui-framework.jar patch..."

    # Check if any miui-framework features are enabled
    if [ $FEATURE_ADD_GBOARD -eq 0 ]; then
        echo "No miui-framework features selected, skipping miui-framework.jar"
        return 0
    fi

    # Decompile miui-framework.jar
    decompile_jar "$miui_framework_path"

    # Apply feature-specific patches based on flags
    if [ $FEATURE_ADD_GBOARD -eq 1 ]; then
        apply_miui_framework_gboard_support "$decompile_dir"
    fi

    # Recompile miui-framework.jar
    recompile_jar "$miui_framework_path"
    d8_optimize_jar "miui-framework_patched.jar"

    # Clean up
    rm -rf "$WORK_DIR/miui-framework" "$decompile_dir"

    if [ ! -f "miui-framework_patched.jar" ]; then
        err "Critical Error: miui-framework_patched.jar was not created."
        return 1
    fi

    echo "Miui-framework.jar patching completed."
}

# Source helper functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helper.sh"
source "$SCRIPT_DIR/core/version.sh"

# Main function
main() {
    # Check for required arguments
    if [ $# -lt 3 ]; then
        cat <<EOF
Usage: $0 <api_level> <device_name> <version_name> [JAR_OPTIONS] [FEATURE_OPTIONS]

JAR OPTIONS (specify which JARs to patch):
  --framework           Patch framework.jar
  --services            Patch services.jar
  --miui-services       Patch miui-services.jar
  --miui-framework      Patch miui-framework.jar
  (If no JAR option specified, all JARs will be patched)

FEATURE OPTIONS (specify which features to apply):
  --disable-signature-verification    Disable signature verification (default if no feature specified)
  --kaorios-toolbox                   Include Kaorios Toolbox (Play Integrity Fix)
  --add-gboard                         Add Gboard support (replace Baidu input)

EXAMPLES:
  # Apply signature verification bypass to all JARs (backward compatible)
  $0 34 xiaomi 1.0.0

  # Apply signature verification to framework only
  $0 34 xiaomi 1.0.0 --framework --disable-signature-verification --enable-kaorios-toolbox

Creates a single module compatible with Magisk, KSU, and SUFS
EOF
        exit 1
    fi

    # Parse arguments
    API_LEVEL="$1"
    DEVICE_NAME="$2"
    VERSION_NAME="$3"
    shift 3

    # Check which JARs to patch
    PATCH_FRAMEWORK=0
    PATCH_SERVICES=0
    PATCH_MIUI_SERVICES=0
    PATCH_MIUI_FRAMEWORK=0
    FEATURE_KAORIOS_TOOLBOX=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --framework)
                PATCH_FRAMEWORK=1
                ;;
            --services)
                PATCH_SERVICES=1
                ;;
            --miui-services)
                PATCH_MIUI_SERVICES=1
                ;;
            --miui-framework)
                PATCH_MIUI_FRAMEWORK=1
                ;;
            --disable-signature-verification)
                FEATURE_DISABLE_SIGNATURE_VERIFICATION=1
                ;;
            --kaorios-toolbox)
                FEATURE_KAORIOS_TOOLBOX=1
                ;;
            --add-gboard)
                FEATURE_ADD_GBOARD=1
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
        shift
    done

    # If no JAR specified, patch all
    if [ $PATCH_FRAMEWORK -eq 0 ] && [ $PATCH_SERVICES -eq 0 ] && [ $PATCH_MIUI_SERVICES -eq 0 ] && [ $PATCH_MIUI_FRAMEWORK -eq 0 ]; then
        PATCH_FRAMEWORK=1
        PATCH_SERVICES=1
        PATCH_MIUI_SERVICES=1
        PATCH_MIUI_FRAMEWORK=1
    fi

    # If no feature specified, default to signature verification (backward compatibility)
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] && [ $FEATURE_KAORIOS_TOOLBOX -eq 0 ] && [ $FEATURE_ADD_GBOARD -eq 0 ]; then
        FEATURE_DISABLE_SIGNATURE_VERIFICATION=1
        echo "No feature specified, defaulting to --disable-signature-verification"
    fi

    # Display selected features
    echo "============================================"
    echo "Framework Patcher Engine v${PATCH_ENGINE_VERSION:-unknown}"
    echo "============================================"
    echo "Selected Features:"
    [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ] && echo "  ✓ Disable Signature Verification"
    [ $FEATURE_KAORIOS_TOOLBOX -eq 1 ] && echo "  ✓ Include Kaorios Toolbox"
    [ $FEATURE_ADD_GBOARD -eq 1 ] && echo "  ✓ Add Gboard Support"
    echo "============================================"

    # Build features CSV for manifest
    local FEATURES_CSV=""
    [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}disable_signature_verification"
    [ $FEATURE_KAORIOS_TOOLBOX -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}kaorios_toolbox"
    [ $FEATURE_ADD_GBOARD -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}add_gboard"

    # Initialize environment and check tools
    init_env
    ensure_tools || exit 1

    # Patch requested JARs
    if [ $PATCH_FRAMEWORK -eq 1 ]; then
        patch_framework
    fi

    if [ $PATCH_SERVICES -eq 1 ]; then
        patch_services
    fi

    if [ $PATCH_MIUI_SERVICES -eq 1 ]; then
        patch_miui_services
    fi

    if [ $PATCH_MIUI_FRAMEWORK -eq 1 ]; then
        patch_miui_framework
    fi

    # Create module with manifest metadata
    create_module "$API_LEVEL" "$DEVICE_NAME" "$VERSION_NAME" "$FEATURE_KAORIOS_TOOLBOX" \
        "14" "$FEATURES_CSV" "${WORKFLOW_RUN_ID:-local}" "${WORKFLOW_URL:-}" "${WORKFLOW_RELEASE_URL:-}"

    echo "All patching completed successfully!"
}

# Run main function with all arguments
main "$@"
