<!-- Fallback template for manual releases (if the Action is not used). -->

# Zig‑Beam {{TAG}}

Date: {{DATE}}

This is a draft release for tag {{TAG}}.

## Reports
- Arc benchmarks: utils/docs/arc_benchmark_results.md
- Thread‑Local Cache benchmarks: utils/docs/thread_local_cache_benchmark_results.md
- Dependency graph: utils/docs/dependency_graph.md

## Quick Start (pin by tag)
```bash
zig fetch --save https://github.com/eakova/zig-beam/archive/refs/tags/{{TAG}}.tar.gz
```

In build.zig:
```zig
const beam = b.dependency("zig-beam", .{});
const utils = beam.module("utils");
exe.root_module.addImport("utils", utils);
```

In code:
```zig
const utils = @import("utils");
```

