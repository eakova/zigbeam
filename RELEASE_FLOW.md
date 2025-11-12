## Release Flow

This document describes how we cut and publish releases for the repository.

### Model
- Single repo versioning using SemVer tags: `v0.x.y`.
- Long‑lived maintenance branches per minor: `release/v0.x`.
- Patches are cut from the minor branch, tagged (e.g. `v0.x.y`), and merged back to `main`.

### Freeze and Verify
1) Freeze `main` for release preparation (accept only release‑related changes).
2) Ensure docs and reports are up to date under `utils/docs/`.
3) Run tests and benches in ReleaseFast:
   - `cd utils`
   - `ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global-cache ZIG_LOCAL_CACHE_DIR=$PWD/.zig-local-cache zig build -Doptimize=ReleaseFast test`
   - `ARC_BENCH_RUN_MT=1 ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global-cache ZIG_LOCAL_CACHE_DIR=$PWD/.zig-local-cache zig build -Doptimize=ReleaseFast bench-arc`
   - `zig run src/thread-local-cache/_thread_local_cache_benchmarks.zig -OReleaseFast`

### Branch and Tag
1) Create or update the maintenance branch for the minor:
   - `git checkout -b release/v0.3` (first time)
   - `git push -u origin release/v0.3`
2) Tag the release:
   - `git tag v0.3.0`
   - `git push origin v0.3.0`

Pushing a `v*` tag triggers the GitHub Action at `.github/workflows/release-draft.yml`, which creates a draft GitHub Release and attaches benchmark reports from `utils/docs/*.md`.

### Hotfixes
1) Fix on the maintenance branch:
   - `git checkout release/v0.3`
   - Apply patch → `git commit`
   - `git tag v0.3.1 && git push origin release/v0.3 --tags`
2) Merge the same fix into `main` (forward‑port):
   - `git checkout main && git merge --no-ff release/v0.3`

### How Consumers Pin a Version
```bash
zig fetch --save https://github.com/eakova/zig-beam/archive/refs/tags/v0.3.0.tar.gz
```

In `build.zig`:
```zig
const beam = b.dependency("zig-beam", .{});
const utils = beam.module("utils");
exe.root_module.addImport("utils", utils);
```

In code:
```zig
const utils = @import("utils");
```

### Notes
- Benchmarks are expected to finish under one minute in `-Doptimize=ReleaseFast`.
- Keep Zig caches out of Git: `.gitignore` already excludes zig caches at any depth.

