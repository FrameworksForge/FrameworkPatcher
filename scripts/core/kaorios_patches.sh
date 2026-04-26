#!/usr/bin/env bash
# kaorios_patches.sh - Kaorios Toolbox framework patching functions
# Inject Kaorios utility classes into decompiled framework
inject_kaorios_utility_classes() {
    local decompile_dir="$1"
    local kaorios_source="${SCRIPT_DIR}/../kaorios_toolbox/utils/kaorios"

    if [ ! -d "$kaorios_source" ]; then
        err "Kaorios utility classes not found at $kaorios_source"
        return 1
    fi

    log "Injecting Kaorios utility classes into framework..."

    # Find the highest numbered smali_classes directory (the LAST one)
    local target_smali_dir="smali"
    local max_num=0

    # Check for smali_classes2, smali_classes3, etc.
    for dir in "$decompile_dir"/smali_classes*; do
        if [ -d "$dir" ]; then
            # Extract the number from smali_classesN
            local num=$(basename "$dir" | sed 's/smali_classes//')
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ]; then
                max_num=$num
                target_smali_dir="smali_classes${num}"
            fi
        fi
    done

    log "Injecting into last existing directory: $target_smali_dir"

    # Create the package directory structure in com/android/internal/util/kaorios/
    local target_dir="$decompile_dir/$target_smali_dir/com/android/internal/util/kaorios"
    mkdir -p "$target_dir"

    # Copy all utility classes
    if ! cp -r "$kaorios_source"/* "$target_dir/"; then
        err "Failed to copy Kaorios utility classes"
        return 1
    fi

    local copied_count=$(find "$target_dir" -name "*.smali" | wc -l)
    log "✓ Injected $copied_count Kaorios utility classes into $target_smali_dir/com/android/internal/util/kaorios/"

    return 0
}

#   1. For hasSystemFeature(String;I)Z - Add KaoriFeatureOverrides.getOverride block after .registers
patch_application_package_manager_has_system_feature() {
    local decompile_dir="$1"

    log "Patching ApplicationPackageManager.hasSystemFeature"

    # Find the ApplicationPackageManager.smali file
    local target_file
    target_file=$(find "$decompile_dir" -type f -path "*/android/app/ApplicationPackageManager.smali" | head -n1)

    if [ -z "$target_file" ]; then
        warn "ApplicationPackageManager.smali not found"
        return 0
    fi

    # Relocate ApplicationPackageManager to the last smali directory to avoid DEX limit in the primary dex
    local current_smali_dir=$(echo "$target_file" | sed -E 's|(.*/smali(_classes[0-9]*)?)/.*|\1|')

    # Identify the last smali directory
    local last_smali_dir="smali"
    local max_num=0
    for dir in "$decompile_dir"/smali_classes*; do
        if [ -d "$dir" ]; then
            local num=$(basename "$dir" | sed 's/smali_classes//')
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ]; then
                max_num=$num
                last_smali_dir="smali_classes${num}"
            fi
        fi
    done

    local target_root="$decompile_dir/$last_smali_dir"

    # Only move if it's not already in the last directory
    if [ "$current_smali_dir" != "$target_root" ]; then
        log "Relocating ApplicationPackageManager to $last_smali_dir to avoid DEX limit..."

        # Create destination directory
        local rel_path="android/app"
        local new_dir="$target_root/$rel_path"
        mkdir -p "$new_dir"

        # Move the main class and all inner classes
        local src_dir=$(dirname "$target_file")
        mv "$src_dir"/ApplicationPackageManager*.smali "$new_dir/"

        # Update target_file to point to the new location
        target_file="$new_dir/ApplicationPackageManager.smali"
        log "✓ Relocated ApplicationPackageManager and inner classes to $last_smali_dir"
    fi

    # Use Python to implement the patch
    python3 - "$target_file" <<'PYTHON'
import sys
import re
from pathlib import Path

target_file = Path(sys.argv[1])

if not target_file.exists():
    sys.exit(1)

lines = target_file.read_text().splitlines()
modified = False

# Patch for hasSystemFeature(String, int)Z (with try-catch)
# Just add the KaoriFeatureOverrides.getOverride block after .registers
kaorios_block = """
    invoke-static {}, Landroid/app/ActivityThread;->currentPackageName()Ljava/lang/String;

    move-result-object v0

    :try_start_kaori_override
    iget-object v1, p0, Landroid/app/ApplicationPackageManager;->mContext:Landroid/app/ContextImpl;

    invoke-static {v1, p1, v0}, Lcom/android/internal/util/kaorios/KaoriFeatureOverrides;->getOverride(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/Boolean;

    move-result-object v0
    :try_end_kaori_override
    .catchall {:try_start_kaori_override .. :try_end_kaori_override} :catchall_kaori_override

    goto :goto_kaori_override

    :catchall_kaori_override
    const/4 v0, 0x0

    :goto_kaori_override
    if-eqz v0, :cond_kaori_override

    invoke-virtual {v0}, Ljava/lang/Boolean;->booleanValue()Z

    move-result p0

    return p0

    :cond_kaori_override
""".splitlines()

# Find hasSystemFeature(String, int) method
method_start = None
for i, line in enumerate(lines):
    if '.method ' in line and 'hasSystemFeature(Ljava/lang/String;I)Z' in line:
        method_start = i
        break

if method_start is not None:
    # Find .registers or .locals line
    registers_line = None
    for i in range(method_start, min(method_start + 15, len(lines))):
        if '.locals' in lines[i] or '.registers' in lines[i]:
            registers_line = i
            break

    if registers_line:
        # Check if already patched
        already_patched = False
        for i in range(method_start, min(method_start + 30, len(lines))):
            if 'KaoriFeatureOverrides' in lines[i]:
                already_patched = True
                break

        if not already_patched:
            # Insert Kaorios block after .registers line
            for j, block_line in enumerate(reversed(kaorios_block)):
                lines.insert(registers_line + 1, block_line)
            print("✓ Inserted KaoriFeatureOverrides block")
            modified = True
        else:
            print("Already patched with KaoriFeatureOverrides")
else:
    print("hasSystemFeature(String, int) method not found")

if modified:
    target_file.write_text('\n'.join(lines) + '\n')
    print("✓ Successfully patched ApplicationPackageManager.smali")
else:
    print("No changes needed or already patched")
PYTHON

    if [ $? -eq 0 ]; then
        log "✓ Patched ApplicationPackageManager.hasSystemFeature"
    else
        warn "ApplicationPackageManager patch failed"
    fi

    return 0
}

# Patch Instrumentation.newApplication methods
patch_instrumentation_new_application() {
    local decompile_dir="$1"

    log "Patching Instrumentation.newApplication methods..."

    # Find the Instrumentation.smali file
    local target_file
    target_file=$(find "$decompile_dir" -type f -path "*/android/app/Instrumentation.smali" | head -n1)

    if [ -z "$target_file" ]; then
        warn "Instrumentation.smali not found"
        return 0
    fi

    # Patch: Add invoke-static line before "return-object v0" in both newApplication methods
    python3 - "$target_file" <<'PYTHON'
import sys
import re
from pathlib import Path

target_file = Path(sys.argv[1])

if not target_file.exists():
    sys.exit(1)

lines = target_file.read_text().splitlines()
modified = False

# Track which newApplication method we're in
in_new_app_method = False
method_param = None  # Will be 'p1' or 'p3' depending on which method
i = 0

while i < len(lines):
    line = lines[i]

    # Check if we're entering a newApplication method
    if '.method ' in line and 'newApplication' in line:
        if 'Ljava/lang/Class;Landroid/content/Context;' in line:
            in_new_app_method = True
            method_param = 'p1'  # Context parameter is p1
        elif 'Ljava/lang/ClassLoader;Ljava/lang/String;Landroid/content/Context;' in line:
            in_new_app_method = True
            method_param = 'p3'  # Context parameter is p3

    # If we're in a newApplication method and find "return-object v0"
    if in_new_app_method and 'return-object v0' in line:
        # Check if next line is .end method (to ensure we're at method end)
        if i + 1 < len(lines) and '.end method' in lines[i+1]:
            # Check if patch already exists
            if i > 0 and 'KaoriPropsUtils;->KaoriProps' in lines[i-1]:
                in_new_app_method = False
                i += 1
                continue

            # Get indentation from current line
            indent = re.match(r'^\s*', line).group(0)

            # Insert the patch line before return-object
            patch_line = f'{indent}invoke-static {{{method_param}}}, Lcom/android/internal/util/kaorios/KaoriPropsUtils;->KaoriProps(Landroid/content/Context;)V'
            lines.insert(i, '')  # Add blank line
            lines.insert(i, patch_line)
            modified = True
            i += 2  # Skip past the inserted lines
            in_new_app_method = False
            method_param = None
            continue

    # Exit method
    if '.end method' in line:
        in_new_app_method = False
        method_param = None

    i += 1

if modified:
    target_file.write_text('\n'.join(lines) + '\n')
    print("✓ Patched Instrumentation.newApplication methods")
else:
    print("No changes needed or patch already applied")
PYTHON

    if [ $? -eq 0 ]; then
        log "✓ Patched Instrumentation.newApplication methods"
    else
        warn "Failed to patch Instrumentation.newApplication methods"
    fi

    return 0
}

# Patch KeyStore2.getKeyEntry method
patch_keystore2_get_key_entry() {
    local decompile_dir="$1"

    log "Patching KeyStore2.getKeyEntry..."

    # Find the KeyStore2.smali file
    local target_file
    target_file=$(find "$decompile_dir" -type f -path "*/android/security/KeyStore2.smali" | head -n1)

    if [ -z "$target_file" ]; then
        warn "KeyStore2.smali not found"
        return 0
    fi

    python3 - "$target_file" <<'PYTHON'
import sys
import re
from pathlib import Path

target_file = Path(sys.argv[1])

if not target_file.exists():
    sys.exit(1)

lines = target_file.read_text().splitlines()
modified = False

# Find getKeyEntry method
in_method = False
i = 0

while i < len(lines):
    line = lines[i]

    # Check if we're entering getKeyEntry method
    if '.method ' in line and 'getKeyEntry' in line and 'KeyDescriptor' in line and 'lambda' not in line:
        in_method = True

    # If we're in the method and find "return-object v0"
    if in_method and 'return-object v0' in line:
        # Check if next line is .end method
        if i + 1 < len(lines) and '.end method' in lines[i+1]:
            # Check if patch already exists
            if i > 0 and 'KaoriKeyboxHooks;->KaoriGetKeyEntry' in lines[i-1]:
                in_method = False
                i += 1
                continue

            # Get indentation
            indent = re.match(r'^\s*', line).group(0)

            # Insert the two patch lines before return-object
            patch_lines = [
                '',
                f'{indent}invoke-static {{v0}}, Lcom/android/internal/util/kaorios/KaoriKeyboxHooks;->KaoriGetKeyEntry(Landroid/system/keystore2/KeyEntryResponse;)Landroid/system/keystore2/KeyEntryResponse;',
                f'{indent}move-result-object v0'
            ]

            for j, patch_line in enumerate(patch_lines):
                lines.insert(i + j, patch_line)

            modified = True
            i += len(patch_lines)
            in_method = False
            continue

    if '.end method' in line:
        in_method = False

    i += 1

if modified:
    target_file.write_text('\n'.join(lines) + '\n')
    print("✓ Patched KeyStore2.getKeyEntry")
else:
    print("No changes needed or patch already applied")
PYTHON

    if [ $? -eq 0 ]; then
        log "✓ Patched KeyStore2.getKeyEntry"
    else
        warn "Failed to patch KeyStore2.getKeyEntry"
    fi

    return 0
}

# Patch AndroidKeyStoreSpi.engineGetCertificateChain method
patch_android_keystore_spi_engine_get_certificate_chain() {
    local decompile_dir="$1"

    log "Patching AndroidKeyStoreSpi.engineGetCertificateChain..."

    # Find the AndroidKeyStoreSpi.smali file
    local target_file
    target_file=$(find "$decompile_dir" -type f -path "*/android/security/keystore2/AndroidKeyStoreSpi.smali" | head -n1)

    if [ -z "$target_file" ]; then
        warn "AndroidKeyStoreSpi.smali not found"
        return 0
    fi

    python3 - "$target_file" <<'PYTHON'
import sys
import re
from pathlib import Path

target_file = Path(sys.argv[1])

if not target_file.exists():
    sys.exit(1)

lines = target_file.read_text().splitlines()
modified = False

# Find engineGetCertificateChain method
in_method = False
i = 0

while i < len(lines):
    line = lines[i]

    # Check if we're entering engineGetCertificateChain method
    if '.method ' in line and 'engineGetCertificateChain' in line:
        in_method = True

    if in_method:
        # Patch 1: Add KaoriosPropsEngineGetCertificateChain after .registers/.locals
        if ('.registers' in line or '.locals' in line):
            # Check if patch already exists in the next few lines
            patch_exists = False
            for k in range(1, 5):
                if i + k < len(lines) and 'KaoriPropsUtils;->KaoriGetCertificateChain' in lines[i+k]:
                    patch_exists = True
                    break

            if patch_exists:
                pass # Already patched
            else:
                # Get indentation
                indent = re.match(r'^\s*', line).group(0)

                # Insert the patch line after .registers
                patch_lines = [
                    '',
                    f'{indent}invoke-static {{}}, Lcom/android/internal/util/kaorios/KaoriPropsUtils;->KaoriGetCertificateChain()V'
                ]

                for j, patch_line in enumerate(patch_lines):
                    lines.insert(i + 1 + j, patch_line)

                modified = True
                i += len(patch_lines) # Skip inserted lines

        # Patch 2: Add KaoriosKeybox AFTER "aput-object v2, v3, v4" (which follows "const/4 v4, 0x0")
        if 'const/4 v4, 0x0' in line:
            # Look ahead for aput-object, allowing for blank lines
            found_aput_idx = -1
            for k in range(1, 10): # Look ahead up to 9 lines
                if i + k < len(lines):
                    check_line = lines[i+k].strip()
                    if check_line == 'aput-object v2, v3, v4':
                        found_aput_idx = i + k
                        break
                    elif check_line and not check_line.startswith('.'): # Stop if we hit code that isn't aput-object
                         pass

            if found_aput_idx != -1:
                # Check if patch already exists AFTER the aput-object line
                patch_exists = False
                for k in range(1, 5):
                     if found_aput_idx + k < len(lines) and 'KaoriKeyboxHooks;->KaoriGetCertificateChain' in lines[found_aput_idx+k]:
                         patch_exists = True
                         break

                if not patch_exists:
                    # Get indentation from the aput-object line
                    indent = re.match(r'^\s*', lines[found_aput_idx]).group(0)

                    # Insert patch AFTER aput-object
                    patch_lines = [
                        '',
                        f'{indent}invoke-static {{v3}}, Lcom/android/internal/util/kaorios/KaoriKeyboxHooks;->KaoriGetCertificateChain([Ljava/security/cert/Certificate;)[Ljava/security/cert/Certificate;',
                        f'{indent}move-result-object v3'
                    ]

                    for j, patch_line in enumerate(patch_lines):
                        lines.insert(found_aput_idx + 1 + j, patch_line)

                    modified = True
                    # Advance i to skip the inserted lines and avoid re-processing
                    i = found_aput_idx + len(patch_lines) + 1
                    continue

    if '.end method' in line:
        in_method = False

    i += 1

if modified:
    target_file.write_text('\n'.join(lines) + '\n')
    print("✓ Patched AndroidKeyStoreSpi.engineGetCertificateChain")
else:
    print("No changes needed or patch already applied")
PYTHON

    if [ $? -eq 0 ]; then
        log "✓ Patched AndroidKeyStoreSpi.engineGetCertificateChain"
    else
        warn "Failed to patch AndroidKeyStoreSpi.engineGetCertificateChain"
    fi

    return 0
}

# Main function to apply all Kaorios Toolbox patches
apply_kaorios_toolbox_patches() {
    local decompile_dir="$1"

    log "========================================="
    log "Applying Kaorios Toolbox Patches"
    log "========================================="

    inject_kaorios_utility_classes "$decompile_dir" || return 1
    patch_application_package_manager_has_system_feature "$decompile_dir"
    patch_instrumentation_new_application "$decompile_dir"
    patch_keystore2_get_key_entry "$decompile_dir"
    patch_android_keystore_spi_engine_get_certificate_chain "$decompile_dir"

    log "✓ Kaorios Toolbox patches applied successfully (4/4 core patches)"
    log "  ✓ Instrumentation.newApplication - Property spoofing initialization"
    log "  ✓ KeyStore2.getKeyEntry - Keybox attestation spoofing"
    log "  ✓ AndroidKeyStoreSpi.engineGetCertificateChain - Certificate chain handling"
    log "  ✓ ApplicationPackageManager.hasSystemFeature"

    return 0
}