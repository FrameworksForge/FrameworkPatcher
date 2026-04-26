#!/usr/bin/env bash
# scripts/core/patching.sh
# Smali patching functions

find_smali_method_file() {
    local decompile_dir="$1"
    local method="$2"
    grep -r -l --include="*.smali" "[[:space:]]*\.method.*${method}" "$decompile_dir" 2>/dev/null | head -n1
}

add_static_return_patch() {
    local method="$1"
    local ret_val="$2" # expect hex nibble w/o 0x OR decimal (we assume hex nibble for const/4 usage)
    local decompile_dir="$3"
    local file

    [ -z "$method" ] || true
    [ -z "$decompile_dir" ] && {
        err "add_static_return_patch: missing decompile_dir"
        return 1m
    }

    file=$(find_smali_method_file "$decompile_dir" "$method")
    [ -z "$file" ] && {
        warn "Method $method not found in $decompile_dir"
        return 0
    }

    local start
    start=$(grep -n "^[[:space:]]*\.method.* ${method}" "$file" | cut -d: -f1 | head -n1)
    [ -z "$start" ] && {
        warn "Method $method start not found"
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
        warn "End not found for $method in $file"
        return 0
    }

    local method_head
    method_head=$(sed -n "${start}p" "$file")
    method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

    # Replace method body with a simple const/return
    sed -i "${start},${end}c\\
$method_head_escaped\\
    .registers 8\\
    const/4 v0, 0x${ret_val}\\
    return v0\\
.end method" "$file"

    log "Patched $method in $file to return 0x${ret_val}"
}

patch_return_void_method() {
    local method="$1"
    local decompile_dir="$2"
    local file

    [ -z "$decompile_dir" ] && {
        err "patch_return_void_method: missing decompile_dir"
        return 1
    }

    file=$(find_smali_method_file "$decompile_dir" "$method")
    [ -z "$file" ] && {
        warn "Method $method not found in $decompile_dir"
        return 0
    }

    local start
    start=$(grep -n "^[[:space:]]*\.method.* ${method}" "$file" | cut -d: -f1 | head -n1)
    [ -z "$start" ] && {
        warn "Method $method start not found"
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
        warn "Method $method end not found"
        return 0
    }

    local method_head
    method_head=$(sed -n "${start}p" "$file")
    method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

    sed -i "${start},${end}c\\
$method_head_escaped\\
    .registers 8\\
    return-void\\
.end method" "$file"

    log "Patched $method in $file to return-void"
}

modify_invoke_custom_methods() {
    local decompile_dir="$1"
    echo "Checking for invoke-custom in $decompile_dir..."

    # Use find with + instead of \; to batch files and suppress all grep errors
    local smali_files
    # Redirect both stdout and stderr, and use || true to prevent failures
    smali_files=$(find "$decompile_dir" -type f -name "*.smali" 2>/dev/null | while read -r f; do
        if [ -f "$f" ] && grep -s -q "invoke-custom" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done)

    [ -z "$smali_files" ] && {
        log "No invoke-custom found"
        return 0
    }

    local count=0
    while IFS= read -r smali_file; do
        # Skip if file doesn't exist (extra safety check)
        [ ! -f "$smali_file" ] && continue

        count=$((count + 1))

        # equals
        sed -i "/.method.*equals(/,/^.end method$/ {
            /^    .registers/c\\    .registers 2
            /^    invoke-custom/d
            /^    move-result/d
            /^    return/c\\    const/4 v0, 0x0\\n\\n    return v0
        }" "$smali_file" 2>/dev/null || true

        # hashCode
        sed -i "/.method.*hashCode(/,/^.end method$/ {
            /^    .registers/c\\    .registers 2
            /^    invoke-custom/d
            /^    move-result/d
            /^    return/c\\    const/4 v0, 0x0\\n\\n    return v0
        }" "$smali_file" 2>/dev/null || true

        # toString
        sed -i "/.method.*toString(/,/^.end method$/ {
            s/^[[:space:]]*\\.registers.*/    .registers 1/
            /^    invoke-custom/d
            /^    move-result.*/d
            /^    return.*/c\\    const/4 v0, 0x0\\n\\n    return-object v0
        }" "$smali_file" 2>/dev/null || true
    done <<<"$smali_files"

    if [ "$count" -gt 0 ]; then
        log "Modified $count files with invoke-custom"
    else
        log "No invoke-custom found"
    fi
}

patch_return_void_methods_all() {
    local method_name="$1"
    local decompile_dir="$2"

    [ -z "$decompile_dir" ] && {
        err "patch_return_void_methods_all: missing decompile_dir"
        return 1
    }

    # Find all files containing the method
    local files
    files=$(find "$decompile_dir" -type f -name "*.smali" -exec grep -s -l "^[[:space:]]*\\.method.*${method_name}" {} + 2>/dev/null || true)

    [ -z "$files" ] && {
        warn "No occurrences of ${method_name} found in $decompile_dir"
        return 0
    }

    local file
    for file in $files; do
        # Patch each occurrence within the file
        # We iterate from bottom to top to keep line numbers stable
        local starts
        starts=$(grep -n "^[[:space:]]*\\.method.*${method_name}" "$file" | cut -d: -f1 | sort -nr)
        [ -z "$starts" ] && continue

        local start end total_lines i line method_head method_head_escaped
        total_lines=$(wc -l <"$file")

        for start in $starts; do
            end=0
            i="$start"
            while [ "$i" -le "$total_lines" ]; do
                line=$(sed -n "${i}p" "$file")
                [[ "$line" == *".end method"* ]] && {
                    end="$i"
                    break
                }
                i=$((i + 1))
            done
            [ "$end" -eq 0 ] && {
                warn "End not found for ${method_name} in $file (start $start)"
                continue
            }

            method_head=$(sed -n "${start}p" "$file")
            method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

            sed -i "${start},${end}c\\
${method_head_escaped}\\
    .registers 8\\
    return-void\\
.end method" "$file"
        done

        log "Patched all ${method_name} overloads in $(basename "$file") to return-void"
    done

    return 0
}
