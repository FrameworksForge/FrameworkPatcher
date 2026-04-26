#!/usr/bin/env bash
# scripts/core/module.sh
# Module creation functions

create_module() {
    # local api_level="$1"  # Currently unused but kept for future use
    local device_name="$2"
    local version_name="$3"
    local kaorios_enabled="${4:-0}"

    log "Creating module using FrameworkPatcherModule for $device_name (v$version_name)"

    local build_dir="build_module"
    rm -rf "$build_dir"

    # Copy FrameworkPatcherModule template
    cp -r "templates/framework-patcher-module" "$build_dir" || {
        err "FrameworkPatcherModule template not found: templates/framework-patcher-module"
        return 1
    }

    # Clean up unnecessary files from FrameworkPatcherModule template
    rm -f "$build_dir/.git" "$build_dir/.gitignore" "$build_dir/.gitattributes"
    rm -f "$build_dir/README.md" "$build_dir/changelog.md" "$build_dir/LICENSE"
    rm -f "$build_dir/update.json" "$build_dir/install.zip"
    rm -rf "$build_dir/common/addon" "$build_dir/zygisk"
    rm -f "$build_dir/system/placeholder" "$build_dir/common/addon/placeholder" "$build_dir/zygisk/placeholder"

    # Update module.prop for universal compatibility
    local module_prop="$build_dir/module.prop"
    if [ -f "$module_prop" ]; then
        # Update basic properties
        sed -i "s/^id=.*/id=mod_frameworks/" "$module_prop"
        sed -i "s/^name=.*/name=Framework Patch V2/" "$module_prop"
        sed -i "s/^version=.*/version=$version_name/" "$module_prop"
        sed -i "s/^versionCode=.*/versionCode=$version_name/" "$module_prop"
        sed -i "s/^author=.*/author=Jᴇғɪɴᴏ ⚝/" "$module_prop"
        sed -i "s/^description=.*/description=Framework patcher compatible with Magisk, KernelSU (KSU), and SUFS. Patched using frameworksforge.github.io\/FrameworkPatcher/" "$module_prop"

        # Remove updateJson line
        sed -i "/^updateJson=/d" "$module_prop"

        # Add universal compatibility properties
        {
            echo "minMagisk=20400"
            echo "ksu=1"
            echo "minKsu=10904"
            echo "sufs=1"
            echo "minSufs=10000"
            echo "minApi=34"
            echo "maxApi=34"
            echo "requireReboot=true"
            echo "support=https://t.me/Jefino9488"
        } >>"$module_prop"
    fi

    # Update customize.sh with framework replacements
    # Update customize.sh with framework replacements
    local customize_sh="$build_dir/customize.sh"
    if [ -f "$customize_sh" ]; then
        # Construct dynamic REPLACE list
        local replace_list=""
        
        # Create required directories and copy patched files
        mkdir -p "$build_dir/system/framework"
        mkdir -p "$build_dir/system/system_ext/framework"

        # copy patched files (if present in cwd) and add to REPLACE list
        if [ -f "framework_patched.jar" ]; then
            cp "framework_patched.jar" "$build_dir/system/framework/framework.jar"
            replace_list="${replace_list}/system/framework/framework.jar\n"
        fi
        
        if [ -f "services_patched.jar" ]; then
            cp "services_patched.jar" "$build_dir/system/framework/services.jar"
            replace_list="${replace_list}/system/framework/services.jar\n"
        fi
        
        if [ -f "miui-services_patched.jar" ]; then
            cp "miui-services_patched.jar" "$build_dir/system/system_ext/framework/miui-services.jar"
            replace_list="${replace_list}/system/system_ext/framework/miui-services.jar\n"
        fi

        # Replace the empty REPLACE section with our dynamic list
        # We use a temporary file to avoid complex sed escaping issues with newlines
        awk -v r="$replace_list" '{
            if ($0 ~ /^REPLACE="/) {
                print "REPLACE=\""
                printf "%s", r
                print "\""
                # Skip lines until the closing quote
                while (getline > 0 && $0 !~ /^"/) {}
            } else {
                print
            }
        }' "$customize_sh" > "${customize_sh}.tmp" && mv "${customize_sh}.tmp" "$customize_sh"
    fi

    # Copy Kaorios Toolbox files if present (only if enabled)
    if [ "$kaorios_enabled" -eq 1 ] && [ -d "kaorios_toolbox" ]; then
        log "Including Kaorios Toolbox components in module"
        
        # 1. Install APK as system app (priv-app)
        if [ -f "kaorios_toolbox/KaoriosToolbox.apk" ]; then
            mkdir -p "$build_dir/system/priv-app/KaoriosToolbox"
            cp "kaorios_toolbox/KaoriosToolbox.apk" "$build_dir/system/priv-app/KaoriosToolbox/KaoriosToolbox.apk"
            
            # Extract native libraries
            log "  • Extracting native libraries from APK..."
            mkdir -p "$build_dir/system/priv-app/KaoriosToolbox/lib"
            # Extract lib/arm64-v8a or lib/armeabi-v7a to lib/
            unzip -q "kaorios_toolbox/KaoriosToolbox.apk" "lib/*" -d "$build_dir/system/priv-app/KaoriosToolbox/" || true
        fi

        # 2. Install permissions
        if [ -f "kaorios_toolbox/privapp_whitelist_com.kousei.kaorios.xml" ]; then
            mkdir -p "$build_dir/system/etc/permissions"
            cp "kaorios_toolbox/privapp_whitelist_com.kousei.kaorios.xml" "$build_dir/system/etc/permissions/"
        fi
        
        # 3. Configure system properties
        {
            echo ""
            echo "# Kaorios Toolbox"
            echo "persist.sys.kaorios=kousei"
            echo "ro.control_privapp_permissions="
        } >> "$build_dir/system.prop"

        # 4. Add service script for user app update
        # service.sh is already in the template, but we ensure it's executable
        if [ -f "$build_dir/service.sh" ]; then
            chmod +x "$build_dir/service.sh"
        fi
        
        # Version info for tracking (optional, maybe in module.prop description or just log)
        if [ -f "kaorios_toolbox/version.txt" ]; then
             local k_ver=$(cat "kaorios_toolbox/version.txt")
             log "  • Kaorios Version: $k_ver"
        fi
        
        log "✓ Kaorios Toolbox files added to module"
    fi

    local safe_version
    safe_version=$(printf "%s" "$version_name" | sed 's/[. ]/-/g')
    local zip_name="Framework-Patcher-${device_name}-${safe_version}.zip"

    if command -v 7z >/dev/null 2>&1; then
        (cd "$build_dir" && 7z a -tzip "../$zip_name" "*" >/dev/null) || {
            err "7z failed to create $zip_name"
            return 1
        }
    elif command -v zip >/dev/null 2>&1; then
        (cd "$build_dir" && zip -r "../$zip_name" . >/dev/null) || {
            err "zip failed to create $zip_name"
            return 1
        }
    else
        err "No archiver found (7z or zip). Install one to create module archive."
        return 1
    fi

    log "Created module: $zip_name"
    echo "$zip_name"
}

# Legacy function for backward compatibility
create_magisk_module() {
    create_module "$1" "$2" "$3" "magisk"
}
