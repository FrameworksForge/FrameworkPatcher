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
FEATURE_CN_NOTIFICATION_FIX=0
FEATURE_DISABLE_SECURE_FLAG=0
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

# Function to patch method with direct file path (no searching)
patch_method_in_file() {
    local method="$1"
    local ret_val="$2"
    local file="$3"

    # Check if file exists
    if [ ! -f "$file" ]; then
        echo "⚠ File not found: $(basename "$file")"
        return
    fi

    local start
    start=$(grep -n "^[[:space:]]*\.method.* $method" "$file" | cut -d: -f1 | head -n1)
    [ -z "$start" ] && {
        echo "⚠ Method $method not found in $(basename "$file")"
        return
    }

    local total_lines end=0 i="$start"
    total_lines=$(wc -l <"$file")
    while [ "$i" -le "$total_lines" ]; do
        line=$(sed -n "${i}p" "$file")
        [[ "$line" == *".end method"* ]] && {
            end="$i"
            break
        }
        i=$((i + 1))
    done

    [ "$end" -eq 0 ] && {
        echo "⚠ End not found for $method"
        return
    }

    local method_head
    method_head=$(sed -n "${start}p" "$file")
    method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

    sed -i "${start},${end}c\\
$method_head_escaped\\
    .registers 8\\
    const/4 v0, 0x$ret_val\\
    return v0\\
.end method" "$file"

    echo "✓ Patched $method to return $ret_val in $(basename "$file")"
}

# Function to add static return patch (legacy - searches for file)
add_static_return_patch() {
    local method="$1"
    local ret_val="$2"
    local decompile_dir="$3"
    local file

    # Simple working approach from old script
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l ".method.* $method" 2>/dev/null | head -n 1)

    [ -z "$file" ] && return

    # Call the new function with found file
    patch_method_in_file "$method" "$ret_val" "$file"
}

# Function to patch return-void method with direct file path
patch_return_void_in_file() {
    local method="$1"
    local file="$2"

    # Check if file exists
    if [ ! -f "$file" ]; then
        echo "⚠ File not found: $(basename "$file")"
        return
    fi

    local start
    start=$(grep -n "^[[:space:]]*\.method.* $method" "$file" | cut -d: -f1 | head -n1)
    [ -z "$start" ] && {
        echo "⚠ Method $method not found in $(basename "$file")"
        return
    }

    local total_lines end=0 i="$start"
    total_lines=$(wc -l <"$file")
    while [ "$i" -le "$total_lines" ]; do
        line=$(sed -n "${i}p" "$file")
        [[ "$line" == *".end method"* ]] && {
            end="$i"
            break
        }
        i=$((i + 1))
    done

    [ "$end" -eq 0 ] && {
        echo "⚠ Method $method end not found"
        return
    }

    local method_head
    method_head=$(sed -n "${start}p" "$file")
    method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

    sed -i "${start},${end}c\\
$method_head_escaped\\
    .registers 8\\
    return-void\\
.end method" "$file"

    echo "✓ Patched $method → return-void in $(basename "$file")"
}

# Function to patch return-void method (legacy - searches for file)
patch_return_void_method() {
    local method="$1"
    local decompile_dir="$2"
    local file

    # Simple working approach from old script
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l ".method.* $method" 2>/dev/null | head -n 1)
    [ -z "$file" ] && {
        echo "Method $method not found"
        return
    }

    # Call the new function with found file
    patch_return_void_in_file "$method" "$file"
}

# Function to replace an entire method with a custom implementation
replace_entire_method() {
    local method_signature="$1"
    local decompile_dir="$2"
    local new_method_body="$3"
    local specific_class="$4" # Optional: specific class name to search in
    local file

    # If specific class provided, search in that class file
    if [ -n "$specific_class" ]; then
        file=$(find "$decompile_dir" -type f -path "*/${specific_class}.smali" | head -n 1)
        if [ -z "$file" ]; then
            echo "⚠ Class file $specific_class.smali not found"
            return 0
        fi
        # Verify method exists in this file
        if ! grep -q "\.method.* ${method_signature}" "$file" 2>/dev/null; then
            echo "⚠ Method $method_signature not found in $specific_class"
            return 0
        fi
    else
        # Search across all smali files
        file=$(find "$decompile_dir" -type f -name "*.smali" -exec grep -l "\.method.* ${method_signature}" {} + 2>/dev/null | head -n 1)
    fi

    [ -z "$file" ] && {
        echo "⚠ Method $method_signature not found in decompile directory"
        return 0
    }

    local start
    start=$(grep -n "^[[:space:]]*\.method.* ${method_signature}" "$file" | cut -d: -f1 | head -n1)
    [ -z "$start" ] && {
        echo "⚠ Method $method_signature start not found in $(basename "$file")"
        return 0
    }

    local total_lines end=0 i="$start" line
    total_lines=$(wc -l <"$file")
    while [ "$i" -le "$total_lines" ]; do
        line=$(sed -n "${i}p" "$file")
        [[ "$line" == *".end method"* ]] && {
            end="$i"
            break
        }
        i=$((i + 1))
    done

    [ "$end" -eq 0 ] && {
        echo "⚠ Method $method_signature end not found in $(basename "$file")"
        return 0
    }

    local method_head
    method_head=$(sed -n "${start}p" "$file")
    method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

    # Replace the entire method with the new body
    sed -i "${start},${end}c\\
$method_head_escaped\\
$new_method_body\\
.end method" "$file"

    echo "✓ Replaced entire method $method_signature in $(basename "$file")"
    return 0
}

# Function to modify invoke-custom methods
modify_invoke_custom_methods() {
    local decompile_dir="$1"
    echo "Checking for invoke-custom..."

    # Simple working approach from old script
    local smali_files
    smali_files=$(grep -rl "invoke-custom" "$decompile_dir" --include="*.smali" 2>/dev/null)

    [ -z "$smali_files" ] && {
        echo "No invoke-custom found"
        return
    }

    local count=0
    for smali_file in $smali_files; do
        count=$((count + 1))

        # Patch equals method
        sed -i "/.method.*equals(/,/^.end method$/ {
            /^    .registers/c\    .registers 2
            /^    invoke-custom/d
            /^    move-result/d
            /^    return/c\    const/4 v0, 0x0\n\n    return v0
        }" "$smali_file"

        # Patch hashCode method
        sed -i "/.method.*hashCode(/,/^.end method$/ {
            /^    .registers/c\    .registers 2
            /^    invoke-custom/d
            /^    move-result/d
            /^    return/c\    const/4 v0, 0x0\n\n    return v0
        }" "$smali_file"

        # Patch toString method
        sed -i "/.method.*toString(/,/^.end method$/ {
            s/^[[:space:]]*\.registers.*/    .registers 1/
            /^    invoke-custom/d
            /^    move-result.*/d
            /^    return.*/c\    const/4 v0, 0x0\n\n    return-object v0
        }" "$smali_file"
    done

    echo "[INFO] Modified $count files with invoke-custom"
}

# ============================================
# Feature-specific patch functions for framework.jar
# ============================================

# Apply signature verification bypass patches to framework.jar
apply_framework_signature_patches() {
    local decompile_dir="$1"

    echo "Applying signature verification patches to framework.jar..."

    # Patch ParsingPackageUtils isError result
    local file
    file=$(find "$decompile_dir" -type f -path "*/com/android/internal/pm/pkg/parsing/ParsingPackageUtils.smali" | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-interface {v2}, Landroid/content/pm/parsing/result/ParseResult;->isError()Z"
        local linenos
        linenos=$(grep -nF "$pattern" "$file" | cut -d: -f1)

        if [ -n "$linenos" ]; then
            local patched=0
            for invoke_lineno in $linenos; do
                found=0
                for offset in 1 2 3; do
                    move_lineno=$((invoke_lineno + offset))
                    line_content=$(sed -n "${move_lineno}p" "$file" | sed 's/^[ \t]*//')
                    if [[ "$line_content" == "const/4 v4, 0x0" ]]; then
                        echo "Already patched at line $move_lineno"
                        found=1
                        patched=1
                        break 2
                    fi
                    if [[ "$line_content" == "move-result v4" ]]; then
                        indent=$(sed -n "${move_lineno}p" "$file" | grep -o '^[ \t]*')
                        sed -i "$((move_lineno + 1))i\\
${indent}const/4 v4, 0x0" "$file"
                        echo "Patched const/4 v4, 0x0 after move-result v4 at line $((move_lineno + 1))"
                        found=1
                        patched=1
                        break 2
                    fi
                done
            done
            [ $patched -eq 0 ] && echo "Unable to patch: No matching pattern found where patching makes sense."
        else
            echo "Pattern not found in $file"
        fi
    else
        echo "ParsingPackageUtils.smali not found"
    fi

    # Patch invoke unsafeGetCertsWithoutVerification
    echo "Patching invoke-static call for unsafeGetCertsWithoutVerification..."
    local file
    file=$(find "$decompile_dir" -type f -name "*.smali" -print0 | xargs -0 grep -l "ApkSignatureVerifier;->unsafeGetCertsWithoutVerification" 2>/dev/null | head -n 1)
    if [ -f "$file" ]; then
        local pattern="ApkSignatureVerifier;->unsafeGetCertsWithoutVerification"
        local line_numbers
        line_numbers=$(grep -n "$pattern" "$file" | cut -d: -f1)

        for lineno in $line_numbers; do
            local previous_line
            previous_line=$(sed -n "$((lineno - 1))p" "$file")
            echo "$previous_line" | grep -q "const/4 v1, 0x1" && {
                echo "Already patched above line $lineno"
                continue
            }
            sed -i "${lineno}i\\
    const/4 v1, 0x1" "$file"
            echo "Patched at line $((lineno)) in file: $file"
        done
    else
        echo "Smali file containing the target line not found"
    fi

    # Patch ApkSigningBlockUtils isEqual
    echo "Patching ApkSigningBlockUtils isEqual check..."
    local file
    file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSigningBlockUtils.smali" | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z"
        local linenos
        linenos=$(grep -nF "$pattern" "$file" | cut -d: -f1)

        if [ -n "$linenos" ]; then
            for invoke_lineno in $linenos; do
                found=0
                for offset in 1 2 3; do
                    move_result_lineno=$((invoke_lineno + offset))
                    current_line=$(sed -n "${move_result_lineno}p" "$file" | sed 's/^[ \t]*//')
                    if [[ "$current_line" == "const/4 v7, 0x1" ]]; then
                        echo "Already patched line $move_result_lineno"
                        found=1
                        break
                    fi
                    if [[ "$current_line" == "move-result v7" ]]; then
                        orig_indent=$(sed -n "${move_result_lineno}p" "$file" | grep -o '^[ \t]*')
                        sed -i "${move_result_lineno}s|.*|${orig_indent}const/4 v7, 0x1|" "$file"
                        echo "Patched move-result at line $move_result_lineno"
                        found=1
                        break
                    fi
                done
                [ $found -eq 0 ] && echo "move-result v7 not found within 3 lines after invoke-static at line $invoke_lineno"
            done
        else
            echo "Target invoke-static line not found in $file"
        fi
    else
        echo "ApkSigningBlockUtils.smali not found"
    fi

    # Patch verifyV1Signature
    echo "Patching verifyV1Signature method only..."
    local file
    file=$(find "$decompile_dir" -type f -name "*ApkSignatureVerifier.smali" | head -n 1)
    if [ -f "$file" ]; then
        local method="verifyV1Signature"

        lines=$(grep -n "$method" "$file" | cut -d: -f1)
        if [ -n "$lines" ]; then
            for lineno in $lines; do
                line_text=$(sed -n "${lineno}p" "$file")
                echo "$line_text" | grep -q "invoke-static" || continue
                next_line=$(sed -n "$((lineno + 1))p" "$file" | grep -E "\.method|\.end method")
                [ -n "$next_line" ] && continue
                above=$((lineno - 1))
                sed -n "${above}p" "$file" | grep -q "const/4 p3, 0x0" || {
                    sed -i "${lineno}i\\
    const/4 p3, 0x0" "$file"
                    echo "Patched $method"
                }
            done
        else
            echo "No $method found in $file"
        fi
    else
        echo "File not found"
    fi

    # Patch ApkSignatureSchemeV2Verifier isEqual
    echo "Patching ApkSignatureSchemeV2Verifier isEqual check..."
    local file
    file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSignatureSchemeV2Verifier.smali" | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-static {v8, v7}, Ljava/security/MessageDigest;->isEqual([B[B)Z"
        local linenos
        linenos=$(grep -nF "$pattern" "$file" | cut -d: -f1)

        if [ -n "$linenos" ]; then
            for invoke_lineno in $linenos; do
                found=0
                for offset in 1 2 3; do
                    move_result_lineno=$((invoke_lineno + offset))
                    current_line=$(sed -n "${move_result_lineno}p" "$file" | sed 's/^[ \t]*//')
                    if [[ "$current_line" == "const/4 v0, 0x1" ]]; then
                        echo "Already patched line $move_result_lineno"
                        found=1
                        break
                    fi
                    if [[ "$current_line" == "move-result v0" ]]; then
                        orig_indent=$(sed -n "${move_result_lineno}p" "$file" | grep -o '^[ \t]*')
                        sed -i "${move_result_lineno}s|.*|${orig_indent}const/4 v0, 0x1|" "$file"
                        echo "Patched move-result at line $move_result_lineno"
                        found=1
                        break
                    fi
                done
                [ $found -eq 0 ] && echo "move-result v0 not found within 3 lines after invoke-static at line $invoke_lineno"
            done
        else
            echo "Target invoke-static line not found in $file"
        fi
    else
        echo "ApkSignatureSchemeV2Verifier.smali not found"
    fi

    # Patch ApkSignatureSchemeV3Verifier isEqual
    echo "Patching ApkSignatureSchemeV3Verifier isEqual check..."
    local file
    file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSignatureSchemeV3Verifier.smali" | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-static {v12, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z"
        local linenos
        linenos=$(grep -nF "$pattern" "$file" | cut -d: -f1)

        if [ -n "$linenos" ]; then
            for invoke_lineno in $linenos; do
                found=0
                for offset in 1 2 3; do
                    move_result_lineno=$((invoke_lineno + offset))
                    current_line=$(sed -n "${move_result_lineno}p" "$file" | sed 's/^[ \t]*//')
                    if [[ "$current_line" == "const/4 v0, 0x1" ]]; then
                        echo "Already patched line $move_result_lineno"
                        found=1
                        break
                    fi
                    if [[ "$current_line" == "move-result v0" ]]; then
                        orig_indent=$(sed -n "${move_result_lineno}p" "$file" | grep -o '^[ \t]*')
                        sed -i "${move_result_lineno}s|.*|${orig_indent}const/4 v0, 0x1|" "$file"
                        echo "Patched move-result at line $move_result_lineno"
                        found=1
                        break
                    fi
                done
                [ $found -eq 0 ] && echo "move-result v0 not found within 3 lines after invoke-static at line $invoke_lineno"
            done
        else
            echo "Target invoke-static line not found in $file"
        fi
    else
        echo "ApkSignatureSchemeV3Verifier.smali not found"
    fi

    # Patch PackageParserException error
    echo "Patching PackageParser\$PackageParserException error assignments..."
    local file
    file=$(find "$decompile_dir" -type f -path "*/android/content/pm/PackageParser\$PackageParserException.smali" | head -n 1)
    if [ -f "$file" ]; then
        local pattern="iput p1, p0, Landroid/content/pm/PackageParser\$PackageParserException;->error:I"
        local line_numbers
        line_numbers=$(grep -nF "$pattern" "$file" | cut -d: -f1)

        if [ -n "$line_numbers" ]; then
            for lineno in $line_numbers; do
                local insert_line=$((lineno - 1))
                local prev_line
                prev_line=$(sed -n "${insert_line}p" "$file")

                echo "$prev_line" | grep -q "const/4 p1, 0x0" && {
                    echo "Already patched above line $lineno"
                    continue
                }

                # Insert just above iput line
                sed -i "${lineno}i\\
    const/4 p1, 0x0" "$file"
                echo "Patched const/4 p1, 0x0 above line $lineno"
            done
        else
            echo "Target iput line not found in $file"
        fi
    else
        echo "PackageParser\$PackageParserException.smali not found"
    fi

    # Patch packageParser equals android
    echo "Patching parseBaseApkCommon() in PackageParser..."
    local file
    file=$(find "$decompile_dir" -type f -path "*/android/content/pm/PackageParser.smali" | head -n 1)
    if [ -f "$file" ]; then
        local start_line end_line
        start_line=$(grep -n ".method.*parseBaseApkCommon" "$file" | cut -d: -f1 | head -n 1)

        if [ -n "$start_line" ]; then
            end_line=$(tail -n +"$start_line" "$file" | grep -n ".end method" | head -n 1 | cut -d: -f1)
            end_line=$((start_line + end_line - 1))

            local move_result_line
            move_result_line=$(sed -n "${start_line},${end_line}p" "$file" | grep -n "move-result v5" | head -n 1 | cut -d: -f1)

            if [ -n "$move_result_line" ]; then
                local insert_line=$((start_line + move_result_line))

                # Check if already patched
                local next_line
                next_line=$(sed -n "$((insert_line + 1))p" "$file")
                if echo "$next_line" | grep -q "const/4 v5, 0x1"; then
                    echo "Already patched at line $((insert_line + 1))"
                else
                    # Insert after move-result v5
                    sed -i "$((insert_line + 1))i\\
    const/4 v5, 0x1" "$file"
                    echo "Correctly patched const/4 v5, 0x1 after move-result v5 at line $((insert_line + 1))"
                fi
            else
                echo "move-result v5 not found"
            fi
        else
            echo "Method parseBaseApkCommon not found"
        fi
    else
        echo "PackageParser.smali not found"
    fi

    # Patch strictjar findEntry removal
    echo "Patching StrictJarFile..."
    local file
    file=$(find "$decompile_dir" -type f -name "StrictJarFile.smali" | head -n 1)
    if [ -f "$file" ]; then
        local start_line
        start_line=$(grep -n "\->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;" "$file" | cut -d: -f1 | head -n 1)

        if [ -n "$start_line" ]; then
            local i=$((start_line + 1))
            local if_line=""
            local cond_label=""
            # local cond_line=""  # Currently unused but kept for future use
            local line=""

            while [ "$i" -le "$((start_line + 20))" ]; do
                line=$(sed -n "${i}p" "$file" | tr -d '\r')

                if [ -z "$if_line" ] && echo "$line" | grep -qE '^[[:space:]]*if-eqz[[:space:]]+v6,[[:space:]]+:cond_'; then
                    if_line=$i
                fi

                if [ -z "$cond_label" ] && echo "$line" | grep -qE '^[[:space:]]*:cond_[0-9a-zA-Z_]+'; then
                    cond_label=$(echo "$line" | grep -oE ':cond_[0-9a-zA-Z_]+')
                    # cond_line=$i  # Currently unused but kept for future use
                fi

                if [ -n "$if_line" ] && [ -n "$cond_label" ]; then
                    break
                fi

                i=$((i + 1))
            done

            if [ -n "$if_line" ]; then
                sed -i "${if_line}d" "$file"
                echo "Removed if-eqz jump at line $if_line."
            else
                echo "No matching if-eqz line found."
            fi

            if [ -n "$cond_label" ]; then
                # Replace label with label + nop (instead of deleting)
                sed -i "s/^[[:space:]]*${cond_label}[[:space:]]*$/    ${cond_label}\n    nop/" "$file"
                echo "Neutralized label ${cond_label} with nop."
            else
                echo "No matching :cond_ label found."
            fi

            echo "StrictJarFile patch completed."
        else
            echo "Method findEntry not found."
        fi
    else
        echo "StrictJarFile.smali not found."
    fi

    # Patch static methods with hardcoded paths (faster and no errors)
    echo "Patching verifyMessageDigest..."
    patch_method_in_file "verifyMessageDigest" 1 "$decompile_dir/smali_classes4/android/util/jar/StrictJarVerifier.smali"

    echo "Patching hasAncestorOrSelf..."
    patch_method_in_file "hasAncestorOrSelf" 1 "$decompile_dir/smali/android/content/pm/SigningDetails.smali"

    echo "Patching getMinimumSignatureSchemeVersionForTargetSdk..."
    patch_method_in_file "getMinimumSignatureSchemeVersionForTargetSdk" 0 "$decompile_dir/smali_classes4/android/util/apk/ApkSignatureVerifier.smali"

    # Patch checkCapability variants in SigningDetails
    echo "Patching checkCapability variants..."
    for file in "$decompile_dir/smali/android/content/pm/SigningDetails.smali" \
        "$decompile_dir/smali/android/content/pm/PackageParser\$SigningDetails.smali"; do
        if [ -f "$file" ]; then
            patch_method_in_file "checkCapability(Landroid/content/pm/SigningDetails;I)Z" 1 "$file"
            patch_method_in_file "checkCapability(Landroid/content/pm/PackageParser\$SigningDetails;I)Z" 1 "$file"
            patch_method_in_file "checkCapability(Ljava/lang/String;I)Z" 1 "$file"
            patch_method_in_file "checkCapabilityRecover(Landroid/content/pm/SigningDetails;I)Z" 1 "$file"
            patch_method_in_file "checkCapabilityRecover(Landroid/content/pm/PackageParser\$SigningDetails;I)Z" 1 "$file"
        fi
    done

    # Patch checkCapability String in SigningDetails
    echo "Patching checkCapability(Ljava/lang/String;I)Z in SigningDetails..."
    local method="checkCapability(Ljava/lang/String;I)Z"
    local ret_val="1"
    local class_file="SigningDetails.smali"
    local file
    file=$(find "$decompile_dir" -type f -name "$class_file" 2>/dev/null | head -n 1)

    if [ -f "$file" ]; then
        local starts
        starts=$(grep -n "^[[:space:]]*\.method.* $method" "$file" | cut -d: -f1)

        if [ -n "$starts" ]; then
            for start in $starts; do
                local total_lines end=0 i="$start"
                total_lines=$(wc -l <"$file")
                while [ "$i" -le "$total_lines" ]; do
                    line=$(sed -n "${i}p" "$file")
                    [[ "$line" == *".end method"* ]] && {
                        end="$i"
                        break
                    }
                    i=$((i + 1))
                done

                if [ "$end" -ne 0 ]; then
                    local method_head method_head_escaped
                    method_head=$(sed -n "${start}p" "$file")
                    method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

                    sed -i "${start},${end}c\\
$method_head_escaped\\
    .registers 8\\
    const/4 v0, 0x$ret_val\\
    return v0\\
.end method" "$file"

                    echo "Patched $method to return $ret_val"
                else
                    echo "End method not found for $method"
                fi
            done
        else
            echo "Method $method not found"
        fi
    else
        echo "$class_file not found"
    fi

    echo "Signature verification patches applied to framework.jar"
}

# Apply CN notification fix patches to framework.jar
apply_framework_cn_notification_fix() {
    local decompile_dir="$1"

    echo "Applying CN notification fix to framework.jar..."

    # Note: For Android 15, CN notification fix only applies to miui-services.jar
    # No changes needed in framework.jar for this feature
    echo "CN notification fix: No framework.jar patches required for Android 15"

    echo "CN notification fix applied to framework.jar"
}

# Apply disable secure flag patches to framework.jar
apply_framework_disable_secure_flag() {
    local decompile_dir="$1"

    echo "Applying disable secure flag patches to framework.jar..."

    # Note: For Android 15, disable secure flag does not require framework.jar patches
    # Only services.jar and miui-services.jar are affected
    echo "Disable secure flag: No framework.jar patches required for Android 15"

    echo "Disable secure flag patches applied to framework.jar"
}

# Main framework patching function
patch_framework() {
    local framework_path="$WORK_DIR/framework.jar"
    local decompile_dir="$WORK_DIR/framework_decompile"

    echo "Starting framework patch..."

    # Check if any framework features are enabled
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] &&
        [ $FEATURE_CN_NOTIFICATION_FIX -eq 0 ] &&
        [ $FEATURE_DISABLE_SECURE_FLAG -eq 0 ] &&
        [ $FEATURE_KAORIOS_TOOLBOX -eq 0 ]; then
        echo "No framework features selected, skipping framework.jar"
        return 0
    fi

    # Decompile framework.jar
    decompile_jar "$framework_path"

    # Apply invoke-custom patches (common to all features)
    modify_invoke_custom_methods "$decompile_dir"

    # Apply feature-specific patches based on flags
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ]; then
        apply_framework_signature_patches "$decompile_dir"
    fi

    if [ $FEATURE_CN_NOTIFICATION_FIX -eq 1 ]; then
        apply_framework_cn_notification_fix "$decompile_dir"
    fi

    if [ $FEATURE_DISABLE_SECURE_FLAG -eq 1 ]; then
        apply_framework_disable_secure_flag "$decompile_dir"
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

    echo "Framework patching completed."
}

# ============================================
# Feature-specific patch functions for services.jar
# ============================================

# Apply signature verification bypass patches to services.jar
apply_services_signature_patches() {
    local decompile_dir="$1"

    echo "Applying signature verification patches to services.jar..."

    # Patch methods with hardcoded paths (faster and no errors)
    echo "Patching checkDowngrade..."
    patch_return_void_in_file "checkDowngrade" "$decompile_dir/smali_classes2/com/android/server/pm/PackageManagerServiceUtils.smali"

    # Patch service InstallPackageHelper equals
    echo "Patching equals() result in InstallPackageHelper..."
    local file
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/pm/InstallPackageHelper.smali" | head -n 1)
    if [ -f "$file" ]; then
        local pattern="invoke-virtual {v5, v9}, Ljava/lang/Object;->equals(Ljava/lang/Object;)Z"
        local linenos
        linenos=$(grep -nF "$pattern" "$file" | cut -d: -f1)

        if [ -n "$linenos" ]; then
            for invoke_lineno in $linenos; do
                found=0
                for offset in 1 2 3; do
                    move_result_lineno=$((invoke_lineno + offset))
                    current_line=$(sed -n "${move_result_lineno}p" "$file" | sed 's/^[ \t]*//')
                    if [[ "$current_line" == "const/4 v12, 0x1" ]]; then
                        echo "Already patched at line $move_result_lineno"
                        found=1
                        break
                    fi
                    if [[ "$current_line" == "move-result v12" ]]; then
                        # Check if next line already is const/4 v12, 0x1
                        next_content=$(sed -n "$((move_result_lineno + 1))p" "$file" | sed 's/^[ \t]*//')
                        if [[ "$next_content" == "const/4 v12, 0x1" ]]; then
                            echo "Already patched just after move-result at line $((move_result_lineno + 1))"
                            found=1
                            break
                        fi
                        indent=$(sed -n "${move_result_lineno}p" "$file" | grep -o '^[ \t]*')
                        sed -i "$((move_result_lineno + 1))i\\
${indent}const/4 v12, 0x1" "$file"
                        echo "Patched const/4 v12, 0x1 after move-result v12 at line $((move_result_lineno + 1))"
                        found=1
                        break
                    fi
                done
                [ $found -eq 0 ] && echo "move-result v12 not found within 3 lines after invoke-virtual at line $invoke_lineno"
            done
        else
            echo "Target invoke-virtual line not found in $file"
        fi
    else
        echo "InstallPackageHelper.smali not found in services jar"
    fi

    # Patch service ReconcilePackageUtils clinit
    echo "Patching <clinit>() in ReconcilePackageUtils..."
    local file
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/pm/ReconcilePackageUtils.smali" | head -n 1)
    if [ -f "$file" ]; then
        local start_line end_line
        # Find the line number of the static constructor start
        start_line=$(grep -nF ".method static constructor <clinit>()V" "$file" | cut -d: -f1 | head -n 1)
        # Find the line number of the end of the method starting from start_line
        end_line=$(awk "NR>$start_line && /\\.end method/ {print NR; exit}" "$file")

        if [ -n "$start_line" ] && [ -n "$end_line" ]; then
            # Search for const/4 v0, 0x0 inside the method and patch if found
            local const_line
            const_line=$(awk "NR>$start_line && NR<$end_line && /const\\/4 v0, 0x0/ {print NR; exit}" "$file")
            if [ -n "$const_line" ]; then
                local content
                content=$(sed -n "${const_line}p" "$file")
                if [[ "$content" == *"0x1"* ]]; then
                    echo "Already patched at line $const_line"
                else
                    sed -i "${const_line}s/const\\/4 v0, 0x0/const\\/4 v0, 0x1/" "$file"
                    echo "Patched const/4 v0, 0x1 at line $const_line"
                fi
            else
                echo "const/4 v0, 0x0 not found inside <clinit> in $file"
            fi
        else
            echo "<clinit> method not found properly in $file"
        fi
    else
        echo "ReconcilePackageUtils.smali not found in services jar"
    fi

    # Patch static methods with hardcoded paths
    echo "Patching shouldCheckUpgradeKeySetLocked..."
    patch_method_in_file "shouldCheckUpgradeKeySetLocked" 0 "$decompile_dir/smali_classes2/com/android/server/pm/KeySetManagerService.smali"

    echo "Patching verifySignatures..."
    patch_method_in_file "verifySignatures" 0 "$decompile_dir/smali_classes2/com/android/server/pm/PackageManagerServiceUtils.smali"

    echo "Patching matchSignaturesCompat..."
    patch_method_in_file "matchSignaturesCompat" 1 "$decompile_dir/smali_classes2/com/android/server/pm/PackageManagerServiceUtils.smali"

    # echo "Patching compareSignatures..."
    # patch_method_in_file "compareSignatures" 0 "$decompile_dir/smali_classes2/com/android/server/pm/PackageManagerServiceUtils.smali"

    echo "Signature verification patches applied to services.jar"
}

# Apply CN notification fix patches to services.jar
apply_services_cn_notification_fix() {
    local decompile_dir="$1"

    echo "Applying CN notification fix to services.jar..."

    # Note: For Android 15, CN notification fix only applies to miui-services.jar
    # No changes needed in services.jar for this feature
    echo "CN notification fix: No services.jar patches required for Android 15"

    echo "CN notification fix applied to services.jar"
}

# Apply disable secure flag patches to services.jar
apply_services_disable_secure_flag() {
    local decompile_dir="$1"

    echo "Applying disable secure flag patches to services.jar..."

    # Android 15: Patch WindowState.isSecureLocked()
    echo "Patching WindowState.isSecureLocked()..."
    local method_body="    .registers 6\n\n    const/4 v0, 0x0\n\n    return v0"
    replace_entire_method "isSecureLocked()Z" "$decompile_dir" "$method_body" "com/android/server/wm/WindowState"

    echo "Disable secure flag patches applied to services.jar"
}

# Main services patching function
patch_services() {
    local services_path="$WORK_DIR/services.jar"
    local decompile_dir="$WORK_DIR/services_decompile"

    echo "Starting services.jar patch..."

    # Check if any services features are enabled
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] &&
        [ $FEATURE_CN_NOTIFICATION_FIX -eq 0 ] &&
        [ $FEATURE_DISABLE_SECURE_FLAG -eq 0 ]; then
        echo "No services features selected, skipping services.jar"
        return 0
    fi

    # Decompile services.jar
    decompile_jar "$services_path"

    # Apply feature-specific patches based on flags
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ]; then
        apply_services_signature_patches "$decompile_dir"
    fi

    if [ $FEATURE_CN_NOTIFICATION_FIX -eq 1 ]; then
        apply_services_cn_notification_fix "$decompile_dir"
    fi

    if [ $FEATURE_DISABLE_SECURE_FLAG -eq 1 ]; then
        apply_services_disable_secure_flag "$decompile_dir"
    fi

    # Modify invoke-custom methods (common to all features)
    modify_invoke_custom_methods "$decompile_dir"

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

# Apply signature verification bypass patches to miui-services.jar
apply_miui_services_signature_patches() {
    local decompile_dir="$1"

    echo "Applying signature verification patches to miui-services.jar..."

    # Patch methods with hardcoded paths (faster and no errors)
    echo "Patching canBeUpdate..."
    patch_return_void_in_file "canBeUpdate" "$decompile_dir/smali/com/android/server/pm/PackageManagerServiceImpl.smali"

    echo "Patching verifyIsolationViolation..."
    patch_return_void_in_file "verifyIsolationViolation" "$decompile_dir/smali/com/android/server/pm/PackageManagerServiceImpl.smali"

    echo "Signature verification patches applied to miui-services.jar"
}

# Apply CN notification fix patches to miui-services.jar
apply_miui_services_cn_notification_fix() {
    local decompile_dir="$1"

    echo "Applying CN notification fix to miui-services.jar..."

    # Patch BroadcastQueueModernStubImpl
    local file
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/BroadcastQueueModernStubImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        echo "Patching BroadcastQueueModernStubImpl.smali..."
        sed -i 's/sget-boolean v2, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v2, 0x1/g' "$file"
        echo "✓ Patched BroadcastQueueModernStubImpl (v2)"
    else
        echo "⚠ BroadcastQueueModernStubImpl.smali not found"
    fi

    # Patch ActivityManagerServiceImpl (has two occurrences: v1 and v4)
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/ActivityManagerServiceImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        echo "Patching ActivityManagerServiceImpl.smali..."
        sed -i 's/sget-boolean v1, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v1, 0x1/g' "$file"
        sed -i 's/sget-boolean v4, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v4, 0x1/g' "$file"
        echo "✓ Patched ActivityManagerServiceImpl (v1, v4)"
    else
        echo "⚠ ActivityManagerServiceImpl.smali not found"
    fi

    # Patch ProcessManagerService
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/ProcessManagerService.smali" | head -n 1)
    if [ -f "$file" ]; then
        echo "Patching ProcessManagerService.smali..."
        sed -i 's/sget-boolean v0, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v0, 0x1/g' "$file"
        echo "✓ Patched ProcessManagerService (v0)"
    else
        echo "⚠ ProcessManagerService.smali not found"
    fi

    # Patch ProcessSceneCleaner
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/ProcessSceneCleaner.smali" | head -n 1)
    if [ -f "$file" ]; then
        echo "Patching ProcessSceneCleaner.smali..."
        sed -i 's/sget-boolean v0, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v0, 0x1/g' "$file"
        echo "✓ Patched ProcessSceneCleaner (v0)"
    else
        echo "⚠ ProcessSceneCleaner.smali not found"
    fi

    echo "CN notification fix applied to miui-services.jar"
}

# Apply disable secure flag patches to miui-services.jar
apply_miui_services_disable_secure_flag() {
    local decompile_dir="$1"

    echo "Applying disable secure flag patches to miui-services.jar..."

    # Android 15: Patch WindowManagerServiceImpl.notAllowCaptureDisplay()
    echo "Patching WindowManagerServiceImpl.notAllowCaptureDisplay()..."
    local method_body="    .registers 9\n\n    const/4 v0, 0x0\n\n    return v0"
    replace_entire_method "notAllowCaptureDisplay(Lcom/android/server/wm/RootWindowContainer;I)Z" "$decompile_dir" "$method_body" "com/android/server/wm/WindowManagerServiceImpl"

    echo "Disable secure flag patches applied to miui-services.jar"
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
        [ $FEATURE_CN_NOTIFICATION_FIX -eq 0 ] &&
        [ $FEATURE_DISABLE_SECURE_FLAG -eq 0 ] &&
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

    if [ $FEATURE_CN_NOTIFICATION_FIX -eq 1 ]; then
        apply_miui_services_cn_notification_fix "$decompile_dir"
    fi

    if [ $FEATURE_DISABLE_SECURE_FLAG -eq 1 ]; then
        apply_miui_services_disable_secure_flag "$decompile_dir"
    fi

    if [ $FEATURE_ADD_GBOARD -eq 1 ]; then
        apply_miui_services_gboard_support "$decompile_dir"
    fi

    # Modify invoke-custom methods (common to all features)
    modify_invoke_custom_methods "$decompile_dir"

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

    # Modify invoke-custom methods (common to all features)
    modify_invoke_custom_methods "$decompile_dir"

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
  --cn-notification-fix                Apply CN notification fix
  --disable-secure-flag                Disable secure flag
  --add-gboard                         Add Gboard support (replace Baidu input)
  (You can specify multiple features, they will all be applied)

EXAMPLES:
  # Apply signature verification bypass to all JARs (backward compatible)
  $0 35 xiaomi 1.0.0

  # Apply signature verification to framework only
  $0 35 xiaomi 1.0.0 --framework --disable-signature-verification

  # Apply CN notification fix to all JARs
  $0 35 xiaomi 1.0.0 --cn-notification-fix

  # Apply both signature bypass and secure flag to framework and services
  $0 35 xiaomi 1.0.0 --framework --services --disable-signature-verification --disable-secure-flag

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
            --cn-notification-fix)
                FEATURE_CN_NOTIFICATION_FIX=1
                ;;
            --disable-secure-flag)
                FEATURE_DISABLE_SECURE_FLAG=1
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
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] &&
        [ $FEATURE_CN_NOTIFICATION_FIX -eq 0 ] &&
        [ $FEATURE_DISABLE_SECURE_FLAG -eq 0 ] &&
        [ $FEATURE_KAORIOS_TOOLBOX -eq 0 ] &&
        [ $FEATURE_ADD_GBOARD -eq 0 ]; then
        FEATURE_DISABLE_SIGNATURE_VERIFICATION=1
        echo "No feature specified, defaulting to --disable-signature-verification"
    fi

    # Display selected features
    echo "============================================"
    echo "Framework Patcher Engine v${PATCH_ENGINE_VERSION:-unknown}"
    echo "============================================"
    echo "Selected Features:"
    [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ] && echo "  ✓ Disable Signature Verification"
    [ $FEATURE_CN_NOTIFICATION_FIX -eq 1 ] && echo "  ✓ CN Notification Fix"
    [ $FEATURE_DISABLE_SECURE_FLAG -eq 1 ] && echo "  ✓ Disable Secure Flag"
    [ $FEATURE_KAORIOS_TOOLBOX -eq 1 ] && echo "  ✓ Kaorios Toolbox (Play Integrity Fix)"
    [ $FEATURE_ADD_GBOARD -eq 1 ] && echo "  ✓ Add Gboard Support"
    echo "============================================"

    # Build features CSV for manifest
    local FEATURES_CSV=""
    [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}disable_signature_verification"
    [ $FEATURE_CN_NOTIFICATION_FIX -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}cn_notification_fix"
    [ $FEATURE_DISABLE_SECURE_FLAG -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}disable_secure_flag"
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
        "15" "$FEATURES_CSV" "${WORKFLOW_RUN_ID:-local}" "${WORKFLOW_URL:-}" "${WORKFLOW_RELEASE_URL:-}"

    echo "All patching completed successfully!"
}

# Run main function with all arguments
main "$@"
