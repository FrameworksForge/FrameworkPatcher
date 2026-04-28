#!/usr/bin/env bash
# patcher_a16.sh - Android 16 framework/services patcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper.sh"

# ============================================
# Feature Flags (set by command-line arguments)
# ============================================
FEATURE_DISABLE_SIGNATURE_VERIFICATION=0
FEATURE_CN_NOTIFICATION_FIX=0
FEATURE_DISABLE_SECURE_FLAG=0
FEATURE_KAORIOS_TOOLBOX=0
FEATURE_ADD_GBOARD=0

# ----------------------------------------------
# Internal helpers (python-powered transformations)
# ----------------------------------------------

insert_line_before_all() {
    local file="$1"
    local pattern="$2"
    local new_line="$3"

    python3 - "$file" "$pattern" "$new_line" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
pattern = sys.argv[2]
new_line = sys.argv[3]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
matched = False
changed = False

i = 0
while i < len(lines):
    line = lines[i]
    if pattern in line:
        matched = True
        indent = re.match(r"\s*", line).group(0)
        candidate = f"{indent}{new_line}"
        if i > 0 and lines[i - 1].strip() == new_line.strip():
            i += 1
            continue
        lines.insert(i, candidate)
        changed = True
        i += 2
    else:
        i += 1

if not matched:
    sys.exit(3)

if changed:
    path.write_text("\n".join(lines) + "\n")
PY

    local status=$?
    case "$status" in
        0)
            log "Inserted '${new_line}' before lines containing pattern '${pattern##*/}' in $(basename "$file")"
            ;;
        3)
            warn "Pattern '${pattern}' not found in $(basename "$file")"
            ;;
        4)
            warn "File not found: $file"
            ;;
        *)
            err "Failed to insert '${new_line}' in $file (status $status)"
            return 1
            ;;
    esac

    return 0
}

insert_const_before_condition_near_string() {
    local file="$1"
    local search_string="$2"
    local condition_prefix="$3"
    local register="$4"
    local value="$5"

    python3 - "$file" "$search_string" "$condition_prefix" "$register" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
search_string = sys.argv[2]
condition_prefix = sys.argv[3]
register = sys.argv[4]
value = sys.argv[5]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
matched = False
changed = False

for idx, line in enumerate(lines):
    if search_string in line:
        matched = True
        start = max(0, idx - 20)
        for j in range(idx - 1, start - 1, -1):
            stripped = lines[j].strip()
            if stripped.startswith(condition_prefix):
                indent = re.match(r"\s*", lines[j]).group(0)
                insert_line = f"{indent}const/4 {register}, 0x{value}"
                if j == 0 or lines[j - 1].strip() != f"const/4 {register}, 0x{value}":
                    lines.insert(j, insert_line)
                    changed = True
                break

if not matched:
    sys.exit(3)

if changed:
    path.write_text("\n".join(lines) + "\n")
PY

    local status=$?
    case "$status" in
        0)
            log "Inserted const for ${register} near condition '${condition_prefix}' in $(basename "$file")"
            ;;
        3)
            warn "Search string '${search_string}' not found in $(basename "$file")"
            ;;
        4)
            warn "File not found: $file"
            ;;
        *)
            err "Failed to patch condition in $file (status $status)"
            return 1
            ;;
    esac

    return 0
}

replace_move_result_after_invoke() {
    local file="$1"
    local invoke_pattern="$2"
    local replacement="$3"

    python3 - "$file" "$invoke_pattern" "$replacement" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
invoke_pattern = sys.argv[2]
replacement = sys.argv[3]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
matched = False
changed = False

i = 0
while i < len(lines):
    line = lines[i]
    if invoke_pattern in line:
        matched = True
        for j in range(i + 1, min(i + 6, len(lines))):
            target = lines[j].strip()
            if target.startswith('move-result'):
                indent = re.match(r"\s*", lines[j]).group(0)
                desired = f"{indent}{replacement}"
                if target == replacement:
                    break
                if lines[j].strip() == replacement:
                    break
                lines[j] = desired
                changed = True
                break
        i = i + 1
    else:
        i += 1

if not matched:
    sys.exit(3)

if changed:
    path.write_text("\n".join(lines) + "\n")
PY

    local status=$?
    case "$status" in
        0)
            log "Replaced move-result after invoke '${invoke_pattern##*/}' in $(basename "$file")"
            ;;
        3)
            warn "Invoke pattern '${invoke_pattern}' not found in $(basename "$file")"
            ;;
        4)
            warn "File not found: $file"
            ;;
        *)
            err "Failed to replace move-result in $file (status $status)"
            return 1
            ;;
    esac

    return 0
}

force_methods_return_const() {
    local file="$1"
    local method_substring="$2"
    local ret_val="$3"

    if [ -z "$file" ]; then
        warn "force_methods_return_const: skipped empty file path for '${method_substring}'"
        return 0
    fi

    if [ ! -f "$file" ]; then
        warn "force_methods_return_const: file not found $file"
        return 0
    fi

    python3 - "$file" "$method_substring" "$ret_val" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
method_key = sys.argv[2]
ret_val = sys.argv[3]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
found = 0
modified = 0
const_line = f"const/4 v0, 0x{ret_val}"

i = 0
while i < len(lines):
    stripped = lines[i].lstrip()
    if stripped.startswith('.method') and method_key in stripped:
        if ')V' in stripped:
            i += 1
            continue
        found += 1
        j = i + 1
        while j < len(lines) and not lines[j].lstrip().startswith('.end method'):
            j += 1
        if j >= len(lines):
            break
        body = lines[i:j+1]
        already = (
            len(body) >= 4
            and body[1].strip() == '.registers 8'
            and body[2].strip() == const_line
            and body[3].strip().startswith('return')
        )
        if already:
            i = j + 1
            continue
        stub = [
            lines[i],
            '    .registers 8',
            f'    {const_line}',
            '    return v0',
            '.end method'
        ]
        lines[i:j+1] = stub
        modified += 1
        i = i + len(stub)
    else:
        i += 1

if modified:
    path.write_text('\n'.join(lines) + '\n')

if found == 0:
    sys.exit(3)
PY

    local status=$?
    case "$status" in
        0)
            log "Set return constant 0x${ret_val} for methods containing '${method_substring}' in $(basename "$file")"
            ;;
        3)
            warn "No methods containing '${method_substring}' found in $(basename "$file")"
            ;;
        4)
            warn "File not found: $file"
            ;;
        *)
            err "Failed to rewrite methods '${method_substring}' in $file (status $status)"
            return 1
            ;;
    esac

    return 0
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
            warn "Class file $specific_class.smali not found"
            return 0
        fi
        # Verify method exists in this file
        if ! grep -s -q "\.method.* ${method_signature}" "$file" 2>/dev/null; then
            warn "Method $method_signature not found in $specific_class"
            return 0
        fi
    else
        # Search across all smali files
        file=$(find "$decompile_dir" -type f -name "*.smali" -exec grep -s -l "\.method.* ${method_signature}" {} + 2>/dev/null | head -n 1)
    fi

    [ -z "$file" ] && {
        warn "Method $method_signature not found in decompile directory"
        return 0
    }

    local start
    start=$(grep -n "^[[:space:]]*\.method.* ${method_signature}" "$file" | cut -d: -f1 | head -n1)
    [ -z "$start" ] && {
        warn "Method $method_signature start not found in $(basename "$file")"
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
        warn "Method $method_signature end not found in $(basename "$file")"
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

    log "✓ Replaced entire method $method_signature in $(basename "$file")"
    return 0
}

replace_if_block_in_strict_jar_file() {
    local file="$1"

    python3 - "$file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
changed = False

for idx, line in enumerate(lines):
    if 'invoke-virtual {p0, v5}, Landroid/util/jar/StrictJarFile;->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;' in line:
        # locate if-eqz v6
        if_idx = None
        for j in range(idx + 1, min(idx + 12, len(lines))):
            stripped = lines[j].strip()
            if stripped.startswith('if-eqz v6, :cond_'):
                if_idx = j
                break
        if if_idx is not None:
            del lines[if_idx]
            changed = True
        # adjust label
        for j in range(idx + 1, min(idx + 20, len(lines))):
            stripped = lines[j].strip()
            if re.match(r':cond_[0-9a-zA-Z_]+', stripped):
                indent = re.match(r'\s*', lines[j]).group(0)
                label = stripped
                # ensure a nop directly after label
                if j + 1 < len(lines) and lines[j + 1].strip() == 'nop':
                    break
                lines.insert(j + 1, f'{indent}nop')
                lines[j] = f'{indent}{label}'
                changed = True
                break
        break

if changed:
    path.write_text('\n'.join(lines) + '\n')
PY

    local status=$?
    case "$status" in
        0)
            log "Removed if-eqz guard in $(basename "$file")"
            ;;
        4)
            warn "StrictJarFile.smali not found"
            ;;
        *)
            err "Failed to adjust StrictJarFile (status $status)"
            return 1
            ;;
    esac

    return 0
}

patch_reconcile_clinit() {
    local file="$1"

    python3 - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
changed = False

for idx, line in enumerate(lines):
    if '.method static constructor <clinit>()V' in line:
        for j in range(idx + 1, len(lines)):
            stripped = lines[j].strip()
            if stripped == '.end method':
                break
            if stripped == 'const/4 v0, 0x0':
                lines[j] = lines[j].replace('0x0', '0x1')
                changed = True
                break
        break

if changed:
    path.write_text('\n'.join(lines) + '\n')
PY

    local status=$?
    case "$status" in
        0)
            log "Updated <clinit> constant in $(basename "$file")"
            ;;
        4)
            warn "ReconcilePackageUtils.smali not found"
            ;;
        *)
            err "Failed to patch ReconcilePackageUtils (status $status)"
            return 1
            ;;
    esac

    return 0
}

ensure_const_before_if_for_register() {
    local file="$1"
    local invoke_pattern="$2"
    local condition_prefix="$3"
    local register="$4"
    local value="$5"

    python3 - "$file" "$invoke_pattern" "$condition_prefix" "$register" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
invoke_pattern = sys.argv[2]
condition_prefix = sys.argv[3]
register = sys.argv[4]
value = sys.argv[5]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
matched = False
changed = False

for idx, line in enumerate(lines):
    if invoke_pattern in line:
        matched = True
        for j in range(max(0, idx - 1), max(0, idx - 10), -1):
            stripped = lines[j].strip()
            if stripped.startswith(condition_prefix):
                indent = re.match(r'\s*', lines[j]).group(0)
                insert_line = f'{indent}const/4 {register}, 0x{value}'
                if j == 0 or lines[j - 1].strip() != f'const/4 {register}, 0x{value}':
                    lines.insert(j, insert_line)
                    changed = True
                break

if not matched:
    sys.exit(3)

if changed:
    path.write_text('\n'.join(lines) + '\n')
PY

    local status=$?
    case "$status" in
        0)
            log "Forced ${register} to 0x${value} before condition '${condition_prefix}' in $(basename "$file")"
            ;;
        3)
            warn "Invoke pattern '${invoke_pattern}' not found in $(basename "$file")"
            ;;
        4)
            warn "File not found: $file"
            ;;
        *)
            err "Failed to enforce const on ${register} in $file (status $status)"
            return 1
            ;;
    esac

    return 0
}

replace_is_international_build_checks() {
    local file="$1"

    python3 - "$file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
pattern = re.compile(r'^(\s*)sget-boolean\s+([vp]\d+),\s+Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z(\s*.*)$')
matched = False
changed = False

for idx, line in enumerate(lines):
    match = pattern.match(line)
    if not match:
        continue
    matched = True
    indent, reg, suffix = match.groups()
    try:
        reg_index = int(reg[1:])
    except ValueError:
        reg_index = 0
    opcode = 'const/4' if reg_index <= 15 else 'const/16'
    replacement = f"{indent}{opcode} {reg}, 0x1{suffix}"
    if lines[idx] != replacement:
        lines[idx] = replacement
        changed = True

if not matched:
    sys.exit(3)

if changed:
    path.write_text("\n".join(lines) + "\n")
PY

    local status=$?
    case "$status" in
        0)
            log "Replaced IS_INTERNATIONAL_BUILD gates in $(basename "$file")"
            ;;
        3)
            warn "IS_INTERNATIONAL_BUILD not found in $(basename "$file")"
            ;;
        4)
            warn "File not found: $file"
            ;;
        *)
            err "Failed to replace IS_INTERNATIONAL_BUILD in $file (status $status)"
            return 1
            ;;
    esac

    return 0
}

# ----------------------------------------------
# Framework patches (Android 16)
# ----------------------------------------------

# Apply signature verification bypass patches to framework.jar (Android 16)
apply_framework_signature_patches() {
    local decompile_dir="$1"

    log "Applying signature verification patches to framework.jar (Android 16)..."

    local pkg_parser_file
    pkg_parser_file=$(find "$decompile_dir" -type f -path "*/android/content/pm/PackageParser.smali" | head -n1)
    if [ -n "$pkg_parser_file" ]; then
        insert_line_before_all "$pkg_parser_file" "ApkSignatureVerifier;->unsafeGetCertsWithoutVerification" "const/4 v1, 0x1"
        insert_const_before_condition_near_string "$pkg_parser_file" '<manifest> specifies bad sharedUserId name' "if-nez v14, :" "v14" "1"
    else
        warn "PackageParser.smali not found"
    fi

    local pkg_parser_exception_file
    pkg_parser_exception_file=$(find "$decompile_dir" -type f -path "*/android/content/pm/PackageParser\$PackageParserException.smali" | head -n1)
    if [ -n "$pkg_parser_exception_file" ]; then
        insert_line_before_all "$pkg_parser_exception_file" "iput p1, p0, Landroid/content/pm/PackageParser\$PackageParserException;->error:I" "const/4 p1, 0x0"
    else
        warn "PackageParser\$PackageParserException.smali not found"
    fi

    local pkg_signing_details_file
    pkg_signing_details_file=$(find "$decompile_dir" -type f -path "*/android/content/pm/PackageParser\$SigningDetails.smali" | head -n1)
    if [ -n "$pkg_signing_details_file" ]; then
        force_methods_return_const "$pkg_signing_details_file" "checkCapability" "1"
    else
        warn "PackageParser\$SigningDetails.smali not found"
    fi

    local signing_details_file
    signing_details_file=$(find "$decompile_dir" -type f -path "*/android/content/pm/SigningDetails.smali" | head -n1)
    if [ -n "$signing_details_file" ]; then
        force_methods_return_const "$signing_details_file" "checkCapability" "1"
        force_methods_return_const "$signing_details_file" "checkCapabilityRecover" "1"
        force_methods_return_const "$signing_details_file" "hasAncestorOrSelf" "1"
    else
        warn "SigningDetails.smali not found"
    fi

    local apk_sig_scheme_v2_file
    apk_sig_scheme_v2_file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSignatureSchemeV2Verifier.smali" | head -n1)
    if [ -n "$apk_sig_scheme_v2_file" ]; then
        replace_move_result_after_invoke "$apk_sig_scheme_v2_file" "invoke-static {v8, v4}, Ljava/security/MessageDigest;->isEqual([B[B)Z" "const/4 v0, 0x1"
    else
        warn "ApkSignatureSchemeV2Verifier.smali not found"
    fi

    local apk_sig_scheme_v3_file
    apk_sig_scheme_v3_file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSignatureSchemeV3Verifier.smali" | head -n1)
    if [ -n "$apk_sig_scheme_v3_file" ]; then
        replace_move_result_after_invoke "$apk_sig_scheme_v3_file" "invoke-static {v9, v3}, Ljava/security/MessageDigest;->isEqual([B[B)Z" "const/4 v0, 0x1"
    else
        warn "ApkSignatureSchemeV3Verifier.smali not found"
    fi

    local apk_signature_verifier_file
    apk_signature_verifier_file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSignatureVerifier.smali" | head -n1)
    if [ -n "$apk_signature_verifier_file" ]; then
        force_methods_return_const "$apk_signature_verifier_file" "getMinimumSignatureSchemeVersionForTargetSdk" "0"
        insert_line_before_all "$apk_signature_verifier_file" "ApkSignatureVerifier;->verifyV1Signature" "const p3, 0x0"
    else
        warn "ApkSignatureVerifier.smali not found"
    fi

    local apk_signing_block_utils_file
    apk_signing_block_utils_file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSigningBlockUtils.smali" | head -n1)
    if [ -n "$apk_signing_block_utils_file" ]; then
        replace_move_result_after_invoke "$apk_signing_block_utils_file" "invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z" "const/4 v7, 0x1"
    else
        warn "ApkSigningBlockUtils.smali not found"
    fi

    local strict_jar_verifier_file
    strict_jar_verifier_file=$(find "$decompile_dir" -type f -path "*/android/util/jar/StrictJarVerifier.smali" | head -n1)
    if [ -n "$strict_jar_verifier_file" ]; then
        force_methods_return_const "$strict_jar_verifier_file" "verifyMessageDigest" "1"
    else
        warn "StrictJarVerifier.smali not found"
    fi

    local strict_jar_file_file
    strict_jar_file_file=$(find "$decompile_dir" -type f -path "*/android/util/jar/StrictJarFile.smali" | head -n1)
    if [ -n "$strict_jar_file_file" ]; then
        replace_if_block_in_strict_jar_file "$strict_jar_file_file"
    else
        warn "StrictJarFile.smali not found"
    fi

    local parsing_package_utils_file
    parsing_package_utils_file=$(find "$decompile_dir" -type f -path "*/com/android/internal/pm/pkg/parsing/ParsingPackageUtils.smali" | head -n1)
    if [ -n "$parsing_package_utils_file" ]; then
        insert_const_before_condition_near_string "$parsing_package_utils_file" '<manifest> specifies bad sharedUserId name' "if-eqz v4, :" "v4" "0"
    else
        warn "ParsingPackageUtils.smali not found"
    fi

    log "Signature verification patches applied to framework.jar (Android 16)"
}

# Apply CN notification fix patches to framework.jar (Android 16)
apply_framework_cn_notification_fix() {
    local decompile_dir="$1"

    log "Applying CN notification fix to framework.jar (Android 16)..."

    # Note: For Android 16, CN notification fix only applies to miui-services.jar
    # No changes needed in framework.jar for this feature
    log "CN notification fix: No framework.jar patches required for Android 16"

    log "CN notification fix applied to framework.jar (Android 16)"
}

# Apply disable secure flag patches to framework.jar (Android 16)
apply_framework_disable_secure_flag() {
    local decompile_dir="$1"

    log "Applying disable secure flag patches to framework.jar (Android 16)..."

    # Note: For Android 16, disable secure flag does not require framework.jar patches
    # Only services.jar and miui-services.jar are affected
    log "Disable secure flag: No framework.jar patches required for Android 16"

    log "Disable secure flag patches applied to framework.jar (Android 16)"
}

# Main framework patching function (Android 16)
patch_framework() {
    local framework_path="${WORK_DIR}/framework.jar"

    if [ ! -f "$framework_path" ]; then
        err "framework.jar not found at $framework_path"
        return 1
    fi

    # Check if any framework features are enabled
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] &&
        [ $FEATURE_CN_NOTIFICATION_FIX -eq 0 ] &&
        [ $FEATURE_DISABLE_SECURE_FLAG -eq 0 ] &&
        [ $FEATURE_KAORIOS_TOOLBOX -eq 0 ]; then
        log "No framework features selected, skipping framework.jar"
        return 0
    fi

    log "Starting Android 16 framework.jar patch"
    local decompile_dir
    decompile_dir=$(decompile_jar "$framework_path") || return 1

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
        source "${SCRIPT_DIR}/core/kaorios_patches.sh"
        apply_kaorios_toolbox_patches "$decompile_dir"
    fi

    # Apply invoke-custom patches (common to all features)
    # modify_invoke_custom_methods "$decompile_dir"

    recompile_jar "$framework_path" >/dev/null
    d8_optimize_jar "framework_patched.jar"
    rm -rf "$decompile_dir" "$WORK_DIR/framework"

    if [ ! -f "framework_patched.jar" ]; then
        err "Critical Error: framework_patched.jar was not created."
        return 1
    fi
    log "Completed framework.jar patching"
}

# ----------------------------------------------
# Services patches (Android 16)
# ----------------------------------------------

# Apply signature verification bypass patches to services.jar (Android 16)
apply_services_signature_patches() {
    local decompile_dir="$1"

    log "Applying signature verification patches to services.jar (Android 16)..."

    # Resolve smali files across classes*/ to handle layout differences in CI
    resolve_smali_file() {
        # $1: relative path like com/android/server/pm/PackageManagerServiceUtils.smali
        local rel="$1"
        local cand
        for d in "$decompile_dir/classes" "$decompile_dir/classes2" "$decompile_dir/classes3" "$decompile_dir/classes4"; do
            cand="$d/$rel"
            [ -f "$cand" ] && {
                printf "%s\n" "$cand"
                return 0
            }
        done
        # fallback to find to be safe
        find "$decompile_dir" -type f -path "*/$rel" | head -n1
    }

    local pms_utils_file
    pms_utils_file=$(resolve_smali_file "com/android/server/pm/PackageManagerServiceUtils.smali")
    local install_package_helper_file
    install_package_helper_file=$(resolve_smali_file "com/android/server/pm/InstallPackageHelper.smali")
    local reconcile_package_utils_file
    reconcile_package_utils_file=$(resolve_smali_file "com/android/server/pm/ReconcilePackageUtils.smali")

    # checkDowngrade → return-void (all overloads)
    if [ -n "$pms_utils_file" ] && [ -f "$pms_utils_file" ]; then
        patch_return_void_methods_all "checkDowngrade" "$decompile_dir"
        force_methods_return_const "$pms_utils_file" "verifySignatures" "0"
        # force_methods_return_const "$pms_utils_file" "compareSignatures" "0"
        force_methods_return_const "$pms_utils_file" "matchSignaturesCompat" "1"
    else
        warn "PackageManagerServiceUtils.smali not found"
    fi

    # shouldCheckUpgradeKeySetLocked may live outside PMS utils on some builds – try to pin first, then fallback to search
    local should_check_file
    should_check_file=$(resolve_smali_file "com/android/server/pm/KeySetManagerService.smali")
    if [ -n "$should_check_file" ] && [ -f "$should_check_file" ]; then
        force_methods_return_const "$should_check_file" "shouldCheckUpgradeKeySetLocked" "0"
    else
        method_file=$(find_smali_method_file "$decompile_dir" "shouldCheckUpgradeKeySetLocked")
        if [ -n "$method_file" ]; then
            force_methods_return_const "$method_file" "shouldCheckUpgradeKeySetLocked" "0"
        else
            warn "shouldCheckUpgradeKeySetLocked not found"
        fi
    fi

    # Apply shared-user guard in known file path (InstallPackageHelper)
    local invoke_pattern="invoke-interface {p5}, Lcom/android/server/pm/pkg/AndroidPackage;->isLeavingSharedUser()Z"
    if [ -n "$install_package_helper_file" ] && [ -f "$install_package_helper_file" ]; then
        ensure_const_before_if_for_register "$install_package_helper_file" "$invoke_pattern" "if-eqz v3, :" "v3" "1"
    else
        # Fallback to repo-wide search if layout differs
        local fallback_file
        fallback_file=$(grep -s -rl --include='*.smali' "$invoke_pattern" "$decompile_dir" 2>/dev/null | head -n1)
        if [ -n "$fallback_file" ]; then
            ensure_const_before_if_for_register "$fallback_file" "$invoke_pattern" "if-eqz v3, :" "v3" "1"
        else
            warn "InstallPackageHelper.smali not found and pattern not located"
        fi
    fi

    if [ -n "$reconcile_package_utils_file" ] && [ -f "$reconcile_package_utils_file" ]; then
        patch_reconcile_clinit "$reconcile_package_utils_file"
    else
        warn "ReconcilePackageUtils.smali not found"
    fi

    # modify_invoke_custom_methods "$decompile_dir"

    # Emit robust verification logs for CI (avoid brittle hardcoded file paths)
    log "[VERIFY] services: locating isLeavingSharedUser invoke (context)"
    grep -s -R -n --include='*.smali' \
        'invoke-interface {p5}, Lcom/android/server/pm/pkg/AndroidPackage;->isLeavingSharedUser()Z' \
        "$decompile_dir" | head -n 1 || true

    log "[VERIFY] services: verifySignatures/compareSignatures/matchSignaturesCompat presence"
    grep -s -R -n --include='*.smali' '^[[:space:]]*\\.method.* verifySignatures' "$decompile_dir" | head -n 1 || true
    grep -s -R -n --include='*.smali' '^[[:space:]]*\\.method.* compareSignatures' "$decompile_dir" | head -n 1 || true
    grep -s -R -n --include='*.smali' '^[[:space:]]*\\.method.* matchSignaturesCompat' "$decompile_dir" | head -n 1 || true

    log "[VERIFY] services: checkDowngrade methods now return-void"
    grep -s -R -n --include='*.smali' '^[[:space:]]*\.method.*checkDowngrade' "$decompile_dir" | head -n 5 || true

    log "[VERIFY] services: ReconcilePackageUtils <clinit> toggle lines"
    local rpu_file
    rpu_file=$(find "$decompile_dir" -type f -path "*/com/android/server/pm/ReconcilePackageUtils.smali" | head -n1)
    if [ -n "$rpu_file" ]; then
        grep -n '^[[:space:]]*\\.method static constructor <clinit>()V' "$rpu_file" || true
        grep -n 'const/4 v0, 0x[01]' "$rpu_file" | head -n 5 || true
    fi

    log "Signature verification patches applied to services.jar (Android 16)"
}

# Apply CN notification fix patches to services.jar (Android 16)
apply_services_cn_notification_fix() {
    local decompile_dir="$1"

    log "Applying CN notification fix to services.jar (Android 16)..."

    # Note: For Android 16, CN notification fix only applies to miui-services.jar
    # No changes needed in services.jar for this feature
    log "CN notification fix: No services.jar patches required for Android 16"

    log "CN notification fix applied to services.jar (Android 16)"
}

# Apply disable secure flag patches to services.jar (Android 16)
apply_services_disable_secure_flag() {
    local decompile_dir="$1"

    log "Applying disable secure flag patches to services.jar (Android 16)..."

    # Android 16: Patch WindowState.isSecureLocked()
    log "Patching WindowState.isSecureLocked()..."
    local method_body="    .registers 6\n\n    const/4 v0, 0x0\n\n    return v0"
    replace_entire_method "isSecureLocked()Z" "$decompile_dir" "$method_body" "com/android/server/wm/WindowState"

    log "Disable secure flag patches applied to services.jar (Android 16)"
}

# Main services patching function (Android 16)
patch_services() {
    local services_path="${WORK_DIR}/services.jar"

    # Allow using a pre-existing decompile dir for verification/patching
    local external_dir_flag=0
    local external_dir=""
    if [ -n "${SERVICES_DECOMPILE_DIR:-}" ] && [ -d "${SERVICES_DECOMPILE_DIR}" ]; then
        external_dir_flag=1
        external_dir="${SERVICES_DECOMPILE_DIR}"
    elif [ -d "${WORK_DIR}/services_decompile" ]; then
        external_dir_flag=1
        external_dir="${WORK_DIR}/services_decompile"
    fi

    if [ $external_dir_flag -eq 0 ] && [ ! -f "$services_path" ]; then
        err "services.jar not found at $services_path and no SERVICES_DECOMPILE_DIR provided"
        return 1
    fi

    # Check if any services features are enabled
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] &&
        [ $FEATURE_CN_NOTIFICATION_FIX -eq 0 ] &&
        [ $FEATURE_DISABLE_SECURE_FLAG -eq 0 ]; then
        log "No services features selected, skipping services.jar"
        return 0
    fi

    log "Starting Android 16 services.jar patch"
    local decompile_dir
    if [ $external_dir_flag -eq 1 ]; then
        log "Using existing services decompile dir: $external_dir"
        decompile_dir="$external_dir"
    else
        decompile_dir=$(decompile_jar "$services_path") || return 1
    fi

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

    # Apply invoke-custom patches (common to all features)
    # modify_invoke_custom_methods "$decompile_dir"

    if [ $external_dir_flag -eq 0 ]; then
        recompile_jar "$services_path" >/dev/null
        d8_optimize_jar "services_patched.jar"
        rm -rf "$decompile_dir" "$WORK_DIR/services"
        log "Completed services.jar patching"
    else
        log "Verification completed on existing services decompile dir (no rebuild)"
    fi
}

# ----------------------------------------------
# MIUI services patches (Android 16)
# ----------------------------------------------

# Apply signature verification bypass patches to miui-services.jar (Android 16)
apply_miui_services_signature_patches() {
    local decompile_dir="$1"

    log "Applying signature verification patches to miui-services.jar (Android 16)..."

    # According to the miui-services guide: force specific methods to return-void
    patch_return_void_methods_all "verifyIsolationViolation" "$decompile_dir"
    patch_return_void_methods_all "canBeUpdate" "$decompile_dir"

    # Targeted verification that won't hang
    log "[VERIFY] miui-services: verifyIsolationViolation/canBeUpdate return-void"
    grep -s -R -n --include='*.smali' '^[[:space:]]*\.method.*verifyIsolationViolation' "$decompile_dir" | head -n 5 || true
    grep -s -R -n --include='*.smali' '^[[:space:]]*\.method.*canBeUpdate' "$decompile_dir" | head -n 5 || true

    log "Signature verification patches applied to miui-services.jar (Android 16)"
}

# Apply CN notification fix patches to miui-services.jar (Android 16)
apply_miui_services_cn_notification_fix() {
    local decompile_dir="$1"

    log "Applying CN notification fix to miui-services.jar (Android 16)..."

    local file

    # Broadcast queue gates (two occurrences, v0)
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/BroadcastQueueModernStubImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching BroadcastQueueModernStubImpl.smali..."
        replace_is_international_build_checks "$file"
    else
        warn "BroadcastQueueModernStubImpl.smali not found"
    fi

    # ActivityManagerService gates (p2 + v0)
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/ActivityManagerServiceImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching ActivityManagerServiceImpl.smali..."
        replace_is_international_build_checks "$file"
    else
        warn "ActivityManagerServiceImpl.smali not found"
    fi

    # Process cleanup gate
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/ProcessSceneCleaner.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching ProcessSceneCleaner.smali..."
        replace_is_international_build_checks "$file"
    else
        warn "ProcessSceneCleaner.smali not found"
    fi

    # Job and alarm gating
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/job/JobServiceContextImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching JobServiceContextImpl.smali..."
        replace_is_international_build_checks "$file"
    else
        warn "JobServiceContextImpl.smali not found"
    fi

    file=$(find "$decompile_dir" -type f -path "*/com/android/server/alarm/AlarmManagerServiceStubImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching AlarmManagerServiceStubImpl.smali..."
        replace_is_international_build_checks "$file"
    else
        warn "AlarmManagerServiceStubImpl.smali not found"
    fi

    # Notification full-screen gate
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/notification/NotificationManagerServiceImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching NotificationManagerServiceImpl.smali..."
        replace_is_international_build_checks "$file"
    else
        warn "NotificationManagerServiceImpl.smali not found"
    fi

    # AppOps gates (v0 + v1 occurrences)
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/AppOpsServiceStubImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching AppOpsServiceStubImpl.smali..."
        replace_is_international_build_checks "$file"
    else
        warn "AppOpsServiceStubImpl.smali not found"
    fi

    # ActivitySecurityHelper gate
    file=$(find "$decompile_dir" -type f -path "*/miui/app/ActivitySecurityHelper.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching ActivitySecurityHelper.smali..."
        replace_is_international_build_checks "$file"
    else
        warn "ActivitySecurityHelper.smali not found"
    fi

    # HyperOS 2.0 Greeze CN_MODEL (high impact)
    file=$(find "$decompile_dir" -type f -path "*/com/miui/server/greeze/PolicyManager.smali" | head -n 1)
    if [ -f "$file" ]; then
        log "Patching PolicyManager.smali (CN_MODEL)..."
        insert_line_before_all "$file" "sput-boolean v0, Lcom/miui/server/greeze/PolicyManager;->CN_MODEL:Z" "const/4 v0, 0x0"
        log "✓ Patched PolicyManager (CN_MODEL = false)"
    else
        warn "PolicyManager.smali not found"
    fi

    log "CN notification fix applied to miui-services.jar (Android 16)"
}

# Apply disable secure flag patches to miui-services.jar (Android 16)
apply_miui_services_disable_secure_flag() {
    local decompile_dir="$1"

    log "Applying disable secure flag patches to miui-services.jar (Android 16)..."

    # Android 16: Patch WindowManagerServiceImpl.notAllowCaptureDisplay()
    log "Patching WindowManagerServiceImpl.notAllowCaptureDisplay()..."
    local method_body="    .registers 9\n\n    const/4 v0, 0x0\n\n    return v0"
    replace_entire_method "notAllowCaptureDisplay(Lcom/android/server/wm/RootWindowContainer;I)Z" "$decompile_dir" "$method_body" "com/android/server/wm/WindowManagerServiceImpl"

    log "Disable secure flag patches applied to miui-services.jar (Android 16)"
}

# Apply Gboard support patches to miui-services.jar (replace Baidu input with Gboard)
apply_miui_services_gboard_support() {
    local decompile_dir="$1"
    local search_string="com.baidu.input_mi"
    local replace_string="com.google.android.inputmethod.latin"

    log "Applying Gboard support patches to miui-services.jar..."

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
            log "Replacing Baidu input with Gboard in $(basename "$file")..."
            sed -i "s/${search_string}/${replace_string}/g" "$file"
            log "✓ Patched $(basename "$file")"
        else
            warn "File not found: $class_file"
        fi
    done

    log "Gboard support patches applied to miui-services.jar"
}

# Main miui-services patching function (Android 16)
patch_miui_services() {
    local miui_services_path="${WORK_DIR}/miui-services.jar"

    # Support external decompile dir like services
    local external_dir_flag=0
    local external_dir=""
    if [ -n "${MIUI_SERVICES_DECOMPILE_DIR:-}" ] && [ -d "${MIUI_SERVICES_DECOMPILE_DIR}" ]; then
        external_dir_flag=1
        external_dir="${MIUI_SERVICES_DECOMPILE_DIR}"
    elif [ -d "${WORK_DIR}/miui-services_decompile" ]; then
        external_dir_flag=1
        external_dir="${WORK_DIR}/miui-services_decompile"
    fi

    if [ $external_dir_flag -eq 0 ] && [ ! -f "$miui_services_path" ]; then
        err "miui-services.jar not found at $miui_services_path and no MIUI_SERVICES_DECOMPILE_DIR provided"
        return 1
    fi

    # Check if any miui-services features are enabled
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] &&
        [ $FEATURE_CN_NOTIFICATION_FIX -eq 0 ] &&
        [ $FEATURE_DISABLE_SECURE_FLAG -eq 0 ] &&
        [ $FEATURE_ADD_GBOARD -eq 0 ]; then
        log "No miui-services features selected, skipping miui-services.jar"
        return 0
    fi

    log "Starting Android 16 miui-services.jar patch"
    local decompile_dir
    if [ $external_dir_flag -eq 1 ]; then
        log "Using existing miui-services decompile dir: $external_dir"
        decompile_dir="$external_dir"
    else
        decompile_dir=$(decompile_jar "$miui_services_path") || return 1
    fi

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

    # Apply invoke-custom patches (common to all features)
    # modify_invoke_custom_methods "$decompile_dir"

    if [ $external_dir_flag -eq 0 ]; then
        recompile_jar "$miui_services_path" >/dev/null
        d8_optimize_jar "miui-services_patched.jar"
        rm -rf "$decompile_dir" "$WORK_DIR/miui-services"
        log "Completed miui-services.jar patching"
    else
        log "Verification completed on existing miui-services decompile dir (no rebuild)"
    fi
}

# ============================================
# Feature-specific patch functions for miui-framework.jar
# ============================================

# Apply Gboard support patches to miui-framework.jar (replace Baidu input with Gboard)
apply_miui_framework_gboard_support() {
    local decompile_dir="$1"
    local search_string="com.baidu.input_mi"
    local replace_string="com.google.android.inputmethod.latin"

    log "Applying Gboard support patches to miui-framework.jar..."

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
            log "Replacing Baidu input with Gboard in $(basename "$file")..."
            sed -i "s/${search_string}/${replace_string}/g" "$file"
            log "✓ Patched $(basename "$file")"
        else
            warn "File not found: $class_file"
        fi
    done

    log "Gboard support patches applied to miui-framework.jar"
}

# Main miui-framework patching function (Android 16)
patch_miui_framework() {
    local miui_framework_path="${WORK_DIR}/miui-framework.jar"

    if [ ! -f "$miui_framework_path" ]; then
        warn "miui-framework.jar not found at $miui_framework_path"
        return 0
    fi

    # Check if any miui-framework features are enabled
    if [ $FEATURE_ADD_GBOARD -eq 0 ]; then
        log "No miui-framework features selected, skipping miui-framework.jar"
        return 0
    fi

    log "Starting Android 16 miui-framework.jar patch"
    local decompile_dir
    decompile_dir=$(decompile_jar "$miui_framework_path") || return 1

    # Apply feature-specific patches based on flags
    if [ $FEATURE_ADD_GBOARD -eq 1 ]; then
        apply_miui_framework_gboard_support "$decompile_dir"
    fi

    recompile_jar "$miui_framework_path" >/dev/null
    d8_optimize_jar "miui-framework_patched.jar"
    rm -rf "$decompile_dir" "$WORK_DIR/miui-framework"

    if [ ! -f "miui-framework_patched.jar" ]; then
        err "Critical Error: miui-framework_patched.jar was not created."
        return 1
    fi
    log "Completed miui-framework.jar patching"
}

# Source helper functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helper.sh"
source "$SCRIPT_DIR/core/version.sh"

# ----------------------------------------------
# Main entrypoint
# ----------------------------------------------

main() {
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

    local api_level="$1"
    local device_name="$2"
    local version_name="$3"
    shift 3

    local patch_framework_flag=0
    local patch_services_flag=0
    local patch_miui_services_flag=0
    local patch_miui_framework_flag=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --framework)
                patch_framework_flag=1
                ;;
            --services)
                patch_services_flag=1
                ;;
            --miui-services)
                patch_miui_services_flag=1
                ;;
            --miui-framework)
                patch_miui_framework_flag=1
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
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
        shift
    done

    # If no JAR specified, patch all
    if [ $patch_framework_flag -eq 0 ] && [ $patch_services_flag -eq 0 ] && [ $patch_miui_services_flag -eq 0 ] && [ $patch_miui_framework_flag -eq 0 ]; then
        patch_framework_flag=1
        patch_services_flag=1
        patch_miui_services_flag=1
        patch_miui_framework_flag=1
    fi

    # If no feature specified, default to signature verification (backward compatibility)
    if [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 0 ] &&
        [ $FEATURE_CN_NOTIFICATION_FIX -eq 0 ] &&
        [ $FEATURE_DISABLE_SECURE_FLAG -eq 0 ] &&
        [ $FEATURE_KAORIOS_TOOLBOX -eq 0 ] &&
        [ $FEATURE_ADD_GBOARD -eq 0 ]; then
        FEATURE_DISABLE_SIGNATURE_VERIFICATION=1
        log "No feature specified, defaulting to --disable-signature-verification"
    fi

    # Display selected features
    log "============================================"
    log "Framework Patcher Engine v${PATCH_ENGINE_VERSION:-unknown}"
    log "============================================"
    log "Selected Features:"
    [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ] && log "  ✓ Disable Signature Verification"
    [ $FEATURE_CN_NOTIFICATION_FIX -eq 1 ] && log "  ✓ CN Notification Fix"
    [ $FEATURE_DISABLE_SECURE_FLAG -eq 1 ] && log "  ✓ Disable Secure Flag"
    [ $FEATURE_KAORIOS_TOOLBOX -eq 1 ] && log "  ✓ Kaorios Toolbox (Play Integrity Fix)"
    [ $FEATURE_ADD_GBOARD -eq 1 ] && log "  ✓ Add Gboard Support"
    log "============================================"

    # Build features CSV for manifest
    local FEATURES_CSV=""
    [ $FEATURE_DISABLE_SIGNATURE_VERIFICATION -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}disable_signature_verification"
    [ $FEATURE_CN_NOTIFICATION_FIX -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}cn_notification_fix"
    [ $FEATURE_DISABLE_SECURE_FLAG -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}disable_secure_flag"
    [ $FEATURE_KAORIOS_TOOLBOX -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}kaorios_toolbox"
    [ $FEATURE_ADD_GBOARD -eq 1 ] && FEATURES_CSV="${FEATURES_CSV:+$FEATURES_CSV,}add_gboard"

    init_env
    ensure_tools || exit 1

    if [ $patch_framework_flag -eq 1 ]; then
        patch_framework
    fi

    if [ $patch_services_flag -eq 1 ]; then
        patch_services
    fi

    if [ $patch_miui_services_flag -eq 1 ]; then
        if [ ! -f "${WORK_DIR}/miui-services.jar" ] && [ -z "${MIUI_SERVICES_DECOMPILE_DIR:-}" ]; then
            warn "miui-services.jar not found at ${WORK_DIR}/miui-services.jar and no MIUI_SERVICES_DECOMPILE_DIR provided"
            log "Skipping miui-services.jar (not needed for non-MIUI devices)"
        else
            patch_miui_services
        fi
    fi

    if [ $patch_miui_framework_flag -eq 1 ]; then
        patch_miui_framework
    fi

    # Create module with manifest metadata
    log "Creating Magisk/KSU module..."
    create_module "$api_level" "$device_name" "$version_name" "$FEATURE_KAORIOS_TOOLBOX" \
        "16" "$FEATURES_CSV" "${WORKFLOW_RUN_ID:-local}" "${WORKFLOW_URL:-}" "${WORKFLOW_RELEASE_URL:-}"

    log "✓ All operations completed successfully!"
}

main "$@"
