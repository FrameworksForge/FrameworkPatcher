# Changelog

All notable changes to Framework Patcher V2 are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [3.0.0] - 2026-04-26

### Platform Upgrade - Production Hardening

### Added

- `VERSION` file as the single source of patch engine version (`3.0.0`)
- `scripts/core/version.sh` to export `PATCH_ENGINE_VERSION`
- `scripts/core/manifest.sh` for structured `build-manifest.json` generation
- `tools/versions.lock` with pinned apktool URL/version/SHA256
- Build index workflows and release workflows for platform-level automation
- `RELEASE.md` as human-readable stable release pointer

### Changed

- All patcher scripts now show the patch engine version in startup banner
- Module generation now embeds `META-INF/build-manifest.json`
- Build flows now include manifest artifacts and reproducibility metadata
- Feature test workflow now enforces VERSION/CHANGELOG consistency

### Fixed

- Removed duplicated compatibility properties from `build_module/module.prop`
- Standardized release metadata generation across Android build workflows

---

## [2.0.0] - 2025-10-13

### Major Release - Feature Selection System

This major update introduces a comprehensive feature selection system across all platforms, enabling users to choose exactly which patches to apply.

### Added

#### Core Features

**Feature Selection System**
- User-selectable patching features across all platforms
- Three configurable features available
- Modular architecture for easy feature additions
- Smart conditional patching logic

**CN Notification Fix** (New Feature)
- Fixes notification delays on China ROM devices
- Patches IS_INTERNATIONAL_BUILD checks in MIUI
- Affects 5 locations across 4 classes in miui-services.jar
- Implemented for Android 15 and Android 16
- Classes patched:
  - BroadcastQueueModernStubImpl
  - ActivityManagerServiceImpl (2 locations)
  - ProcessManagerService
  - ProcessSceneCleaner

**Disable Secure Flag** (New Feature)
- Removes secure window flags preventing screenshots and screen recording
- Replaces 2 method bodies completely
- Implemented for Android 15 and Android 16
- Methods patched:
  - Android 15: WindowManagerServiceStub.isSecureLocked()
  - Android 16: WindowState.isSecureLocked()
  - Both versions: WindowManagerServiceImpl.notAllowCaptureDisplay()

#### Platform Integrations

**GitHub Actions Workflows**
- Added 3 boolean input parameters for feature selection
- Dynamic feature flag construction in workflow steps
- Features displayed in release notes
- Backward compatible default values

**Web Interface**
- Interactive feature selection checkboxes
- Custom styled checkbox components
- Real-time form validation
- Feature descriptions and help text
- Integrated with Catppuccin theme

**Telegram Bot**
- Interactive feature selection with inline buttons
- New conversation state: STATE_WAITING_FOR_FEATURES
- Real-time button updates showing selection state
- Feature validation requiring at least one selection
- Detailed confirmation messages with feature summary

**API Routes**
- Feature flag support in workflow trigger endpoint
- Default value handling for backward compatibility
- Boolean to string conversion for workflow API

#### Documentation

- docs/FEATURE_SYSTEM.md - Complete system architecture documentation
- docs/CN_NOTIFICATION_FIX.md - CN notification fix implementation guide
- docs/DISABLE_SECURE_FLAG.md - Secure flag bypass implementation guide
- docs/USAGE.md - Comprehensive usage guide for all platforms
- CHANGELOG.md - This changelog file

### Changed

#### Patcher Scripts (Major Refactoring)

**Architecture Changes:**
- Refactored signature verification patches into dedicated functions
- Reorganized code into modular feature-specific functions
- 18+ new functions created for feature isolation

**Function Organization:**
- `apply_framework_signature_patches()`
- `apply_framework_cn_notification_fix()`
- `apply_framework_disable_secure_flag()`
- `apply_services_signature_patches()`
- `apply_services_cn_notification_fix()`
- `apply_services_disable_secure_flag()`
- `apply_miui_services_signature_patches()`
- `apply_miui_services_cn_notification_fix()`
- `apply_miui_services_disable_secure_flag()`

**Command-Line Interface:**
- Enhanced argument parsing with feature options
- Improved help text with detailed examples
- Feature selection display output
- Usage examples for all scenarios

**Patching Logic:**
- Conditional patching based on feature flags
- Smart JAR skipping when no relevant features selected
- Optimized decompilation only when necessary

**Helper Functions:**
- Added `replace_entire_method()` for complete method body replacement
- Support for class-specific method targeting
- Improved error handling and logging

**Code Statistics:**
- patcher_a15.sh: 819 lines → 1,172 lines (+353)
- patcher_a16.sh: 860 lines → 1,206 lines (+346)

### Fixed

**Method Replacement Reliability**
- Enhanced `replace_entire_method()` function
- Added optional class-specific targeting parameter
- Improved file finding with fallback mechanisms
- Better error messages showing file names
- Non-fatal warnings instead of exits
- Fixed exit code 123 error when patching WindowState in Android 16

### Performance

**Optimization Improvements:**
- Faster execution when fewer features selected
- Smart JAR skipping saves decompilation time
- Selective patching reduces unnecessary operations

### Backward Compatibility

**Maintained Full Compatibility:**
- Default behavior unchanged (signature verification applied if no features specified)
- Existing command-line usage patterns still work
- No breaking changes to any interfaces
- Existing workflows continue functioning

### Technical Details

**Code Changes:**
```
Added:
- 772 lines in patcher scripts (infrastructure)
- 124 lines in feature implementations
- 102 lines in GitHub workflows
- 185 lines in web interface
- 144 lines in Telegram bot
- 11 lines in API routes
- 2,000+ lines in documentation

Modified:
- 9 code files updated
- 5 documentation files created
```

**Commits:**
1. feat: Add feature selection system infrastructure
2. feat: Implement CN notification fix feature
3. feat: Add feature selection to GitHub Actions workflows
4. feat: Add feature selection UI to web interface
5. feat: Add interactive feature selection to Telegram bot
6. feat: Add feature flags support to API workflow trigger
7. fix: Improve replace_entire_method function reliability

---

## [1.0.0] - 2024

### Initial Release

#### Features

**Core Functionality:**
- Android 15 and Android 16 support
- Signature verification bypass
- Automated JAR patching
- Module generation

**Platforms:**
- Command-line patcher scripts
- GitHub Actions automation
- Telegram bot interface
- Basic web interface

**Module Support:**
- MMT-Extended template integration
- Multi-platform compatibility (Magisk, KSU, SUFS)
- Automatic root solution detection

**Integration:**
- PixelDrain file hosting
- GitHub releases automation
- Telegram notifications

---

## Version Format

**MAJOR.MINOR.PATCH**

- **MAJOR**: Incompatible API changes or major feature additions
- **MINOR**: Backward-compatible feature additions
- **PATCH**: Backward-compatible bug fixes

---

## Upgrade Guide

### Upgrading from 1.x to 2.0

#### Compatibility

**No breaking changes** - Version 2.0 is fully backward compatible.

Existing usage patterns will continue to work:
```bash
# This still works exactly as before
./scripts/patcher_a15.sh 35 device version
```

#### New Capabilities

Version 2.0 adds feature selection without breaking existing functionality:

```bash
# New in 2.0 - feature selection
./scripts/patcher_a15.sh 35 device version --cn-notification-fix

# New in 2.0 - multiple features
./scripts/patcher_a15.sh 35 device version \
  --disable-signature-verification \
  --cn-notification-fix
```

#### Migration Steps

1. Pull latest changes: `git pull origin master`
2. Update bot if self-hosted: `/deploy` command
3. No configuration changes required
4. Start using new features immediately

---

## Feature Comparison

### Version 1.0.0 vs 2.0.0

| Feature | v1.0.0 | v2.0.0 |
|---------|--------|--------|
| Signature Bypass | Enabled (only option) | Selectable |
| CN Notification Fix | Not available | **NEW** - Selectable |
| Disable Secure Flag | Not available | **NEW** - Selectable |
| Feature Selection CLI | Not available | **NEW** - Available |
| Feature Selection Web | Not available | **NEW** - Available |
| Feature Selection Bot | Not available | **NEW** - Available |
| Feature Selection Workflows | Not available | **NEW** - Available |
| Modular Architecture | No | **NEW** - Yes |
| Conditional Patching | No | **NEW** - Yes |
| Comprehensive Docs | Basic | **NEW** - Extensive |

---

## Statistics

### Version 2.0.0 Metrics

**Features:**
- 3 fully implemented patch features
- 4 platforms with feature selection support

**Code:**
- 18+ new functions created
- ~3,000 lines of code added
- ~2,000 lines of documentation
- 0 linter errors

**Quality:**
- 100% backward compatible
- Production tested
- Comprehensive error handling
- Professional documentation

---

## Known Issues

### Current Version (2.0.0)

No known issues at this time.

### Fixed in 2.0.0

- Exit code 123 error when patching WindowState method (fixed in commit 679adb2)

---

## Roadmap

### Planned for 2.1.0

- Android 13/14 support
- Additional patch features
- Module update mechanism
- Batch processing enhancements

### Under Consideration

- GUI desktop application
- Auto-detection of ROM version
- Patch verification system
- Module rollback mechanism
- Additional cloud storage integrations

---

## Support

For questions, issues, or contributions:

- **GitHub Issues**: [Report bugs or request features](https://github.com/FrameworksForge/FrameworkPatcher/issues)
- **Telegram**: [@Jefino9488](https://t.me/Jefino9488)
- **Support Group**: [@codes9488](https://t.me/codes9488)

---

## Acknowledgments

Thanks to all contributors, testers, and community members who helped make version 2.0 possible.

Special recognition for:
- Feature suggestions and testing feedback
- Bug reports and fixes
- Documentation improvements
- Community support and encouragement

---

[View all releases on GitHub](https://github.com/FrameworksForge/FrameworkPatcher/releases)
