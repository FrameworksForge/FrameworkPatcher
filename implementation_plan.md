# Production-Grade Platform Upgrade — v2 (Revised)

Addresses all 5 critical gaps identified in review.

---

## Changes from v1

| Issue | v1 (broken) | v2 (fixed) |
|-------|-------------|------------|
| Per-build tags | Renamed but still created | **Deleted after release creation** — zero tag accumulation |
| Build index | None | **`gh-pages` JSON index** — queryable by device/ROM |
| Reproducibility | Manifest = docs only | **Pinned deps + SHA256 checksums** |
| VERSION sync | Manual | **CI-enforced** — build fails on mismatch |
| Latest stable API | Human-only RELEASE.md | **Machine-readable JSON endpoint** |

---

## Open Questions

1. **Tag cleanup**: Keep existing 3,087 tags, delete them, or archive to a file then delete?
2. **Android 13**: Include in upgrades or treat as frozen/legacy?
3. **GitHub Pages**: Is `gh-pages` branch acceptable for hosting the build index, or prefer a different hosting?

---

## Component 1: VERSION File + version.sh

#### [NEW] `VERSION`
```
3.0.0
```

#### [NEW] `scripts/core/version.sh`
Reads VERSION file, exports `PATCH_ENGINE_VERSION`. Sourced by all patcher scripts.

---

## Component 2: Build Manifest System

#### [NEW] `scripts/core/manifest.sh`

`generate_manifest()` function that produces `build-manifest.json`:

```json
{
  "schema_version": "1.0",
  "patch_engine_version": "3.0.0",
  "git_commit": "ebbf4e1",
  "device": "vermeer",
  "base_rom": "OS3.0.7.0",
  "android_version": "15",
  "api_level": "35",
  "features": ["disable_signature_verification"],
  "build_time": "2026-04-26T12:00:00Z",
  "checksums": {
    "module_zip": "sha256:abc123...",
    "framework_patched": "sha256:def456..."
  },
  "tool_versions": {
    "apktool": "2.9.3"
  },
  "workflow_run_id": "12345678"
}
```

Key additions vs v1: **SHA256 checksums** of all outputs + **tool version pins**.

#### [MODIFY] `scripts/core/module.sh`
- Import `manifest.sh`
- Call `generate_manifest()` in `create_module()`
- Embed manifest at `META-INF/build-manifest.json` inside module ZIP
- Compute SHA256 of module ZIP after creation, update manifest

#### [MODIFY] All 4 patcher scripts
- Source `version.sh` at top
- Print engine version in startup banner
- Pass metadata through to `create_module()`

---

## Component 3: Reproducibility

#### [NEW] `tools/versions.lock`
```json
{
  "apktool": {
    "version": "2.9.3",
    "url": "https://github.com/iBotPeaches/Apktool/releases/download/v2.9.3/apktool_2.9.3.jar",
    "sha256": "<actual hash>"
  }
}
```

#### [MODIFY] All 4 CI workflows — "Prepare tools" step
- Read tool URL + hash from `tools/versions.lock`
- Verify SHA256 after download (fail build if mismatch)
- Pin `actions/checkout@v4`, `actions/upload-artifact@v4` (already pinned ✓)

#### [MODIFY] `.gitmodules`
- Pin kaorios_toolbox submodule to a specific commit

---

## Component 4: Zero Per-Build Git Tags

#### [MODIFY] All 4 CI workflows — Release steps

**Pattern: create tag → create release → delete tag.**

The release persists after tag deletion. No tag accumulation.

```yaml
- name: Set Release Info
  id: release_info
  run: |
    RELEASE_TAG="build-tmp-${{ github.run_id }}"
    RELEASE_NAME="Android 15 | ${{ steps.set_codename.outputs.codename }} | ${{ github.event.inputs.version_name }}"
    echo "tag=${RELEASE_TAG}" >> $GITHUB_OUTPUT
    echo "name=${RELEASE_NAME}" >> $GITHUB_OUTPUT

- name: Create Release
  uses: softprops/action-gh-release@v2
  with:
    tag_name: ${{ steps.release_info.outputs.tag }}
    name: ${{ steps.release_info.outputs.name }}
    files: |
      ${{ steps.find_zip.outputs.file_path }}
      build-manifest.json

- name: Delete temporary tag
  if: success()
  run: git push --delete origin "${{ steps.release_info.outputs.tag }}" || true
```

Result: releases exist with assets, **zero new tags in the repo**.

---

## Component 5: Build Index (gh-pages)

#### [NEW] `.github/workflows/update-build-index.yml`

Triggered after each build workflow completes (via `workflow_run`). Updates `builds/index.json` on the `gh-pages` branch.

**Index structure:**
```json
{
  "schema_version": "1.0",
  "last_updated": "2026-04-26T12:00:00Z",
  "engine_version": "3.0.0",
  "builds": {
    "vermeer": {
      "OS3.0.7.0": {
        "android_version": "15",
        "release_url": "https://github.com/.../releases/12345",
        "download_url": "https://github.com/.../download/...",
        "patch_version": "3.0.0",
        "features": ["disable_signature_verification"],
        "build_time": "2026-04-26T12:00:00Z",
        "checksum": "sha256:abc123..."
      }
    }
  }
}
```

**Queryable at:** `https://frameworksforge.github.io/FrameworkPatcher/builds/index.json`

This workflow:
1. Checks out `gh-pages`
2. Downloads manifest artifact from the triggering run
3. Merges into `index.json` (upsert by device+ROM key)
4. Commits and pushes

---

## Component 6: Latest Stable API

#### [NEW] `builds/latest.json` (on gh-pages)

```json
{
  "engine_version": "3.0.0",
  "release_url": "https://github.com/FrameworksForge/FrameworkPatcher/releases/tag/v3.0.0",
  "release_date": "2026-04-26",
  "supported_android": ["13", "14", "15", "16"]
}
```

Updated by the engine release workflow (Component 7). Machine-readable endpoint at:
`https://frameworksforge.github.io/FrameworkPatcher/builds/latest.json`

#### [NEW] `RELEASE.md`
Human-readable pointer to current stable, features, and how to get builds.

---

## Component 7: Engine Release Workflow

#### [NEW] `.github/workflows/release-engine.yml`

- Manual trigger with `version` input
- Validates `VERSION` file matches input
- Creates SemVer Git tag (`v3.0.0`) — these are the **only** tags
- Creates GitHub Release marked as "Latest"
- Updates `builds/latest.json` on `gh-pages`

---

## Component 8: CI-Enforced Version Sync

#### [MODIFY] `.github/workflows/feature-test-suite.yml`

Add a new job `version-check` that runs on every push/PR:

```yaml
version-check:
  name: Version consistency check
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Validate VERSION matches CHANGELOG
      run: |
        VERSION=$(cat VERSION)
        if ! grep -q "## \[${VERSION}\]" CHANGELOG.md; then
          echo "❌ VERSION file ($VERSION) has no matching entry in CHANGELOG.md"
          exit 1
        fi
        echo "✅ VERSION $VERSION matches CHANGELOG.md"
```

Fails the build if `VERSION` and `CHANGELOG.md` drift.

---

## Component 9: CHANGELOG + module.prop Fixes

#### [MODIFY] `CHANGELOG.md`
Add `[3.0.0]` section documenting the platform upgrade.

#### [MODIFY] `build_module/module.prop`
Remove duplicated properties (lines 16-24 are exact copies of 7-15).

---

## Implementation Order

```
1. VERSION + version.sh              (pure additive)
2. tools/versions.lock               (pure additive)
3. manifest.sh                       (pure additive)
4. Update module.sh                  (backward compatible)
5. Update patcher scripts            (backward compatible)
6. Update CI workflows               (⚡ behavioral change — tags)
7. Build index workflow              (new workflow)
8. Engine release workflow            (new workflow)
9. Version check in test suite       (CI guard)
10. CHANGELOG + module.prop fixes    (cleanup)
```

Steps 1-5 are safe and non-breaking. Step 6 is the critical behavioral change.

---

## Verification Plan

1. **YAML validation** — parse all workflow files
2. **Local patcher test** — run with test JARs, verify manifest in ZIP
3. **Version check** — verify CI catches VERSION/CHANGELOG mismatch
4. **Workflow dry-run** — trigger a test build, verify:
   - No new Git tag persists after release
   - Release has manifest + ZIP attached
   - Build index updates on gh-pages
5. **Feature test suite** — existing tests still pass
