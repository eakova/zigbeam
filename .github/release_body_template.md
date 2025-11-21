<!-- Fallback template for manual releases (if the Action is not used). -->

# Zig‑Beam {{TAG}}

Date: {{DATE}}

This is a draft release for tag {{TAG}}.

## Quick Start (pin by tag)
```bash
zig fetch --save https://github.com/eakova/zig-beam/archive/refs/tags/{{TAG}}.tar.gz
```

In build.zig:
```zig
const dep = b.dependency("zigbeam", .{});
const beam = dep.module("zigbeam");
exe.root_module.addImport("zigbeam", beam);
```

In code:
```zig
const beam = @import("zigbeam");
```
