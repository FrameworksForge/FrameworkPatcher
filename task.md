# Platform Upgrade — Task Tracker

## Phase 1: Foundation (non-breaking)
- [x] Create `VERSION` file (3.0.0)
- [x] Create `scripts/core/version.sh`
- [x] Create `tools/versions.lock` with apktool SHA256
- [x] Create `scripts/core/manifest.sh`
- [x] Fix `build_module/module.prop` duplication

## Phase 2: Integration (backward-compatible)
- [x] Update `scripts/core/module.sh` — embed manifest in ZIP
- [x] Update patcher scripts (a13/a14/a15/a16) — source version.sh, pass metadata
- [x] Update `CHANGELOG.md` — add 3.0.0 entry

## Phase 3: CI Restructuring (behavioral change)
- [x] Update all 4 patcher workflows — deferred tag cleanup, manifest upload, structured release body
- [x] Add version-check job to `feature-test-suite.yml`

## Phase 4: Platform Infrastructure
- [x] Create `update-build-index.yml` — gh-pages index with concurrency control, JSON validation, per-device split
- [x] Create `release-engine.yml` — SemVer engine releases
- [x] Create `cleanup-tags.yml` — scheduled batch tag cleanup (old + build-tmp)
- [x] Create `RELEASE.md`

## Phase 5: Verification
- [x] Validate all YAML files parse correctly
- [x] Verify VERSION/CHANGELOG consistency check works
- [x] Lint shell scripts
