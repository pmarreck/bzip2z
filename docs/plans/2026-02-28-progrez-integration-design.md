# Progrez Integration Design

## Goal

Wire pmarreck/progrez as the progress indication library for bzip2z CLI compression, decompression, and test operations.

## Architecture

```
C CLI (c/cli.c)
  |-- Creates progrez_ctx via progrez C API
  |-- Sets determinate(0, input_len) for file ops, indeterminate for stdin
  |-- Passes C callback + progrez_ctx as userdata in FFI options
  |-- Calls bzip2z_compress() / bzip2z_decompress()
  |-- FFI fires callback at block boundaries -> callback calls progrez_update()
  |-- On return: progrez_finish() + progrez_destroy()
```

## Decisions

- **When to show**: Whenever stderr is a TTY (and not `--quiet`). Shown even during stdout piping.
- **FFI mechanism**: Optional callback function pointer + userdata in options structs. NULL = no callback, zero overhead.
- **Dependency**: Zig package fetched from GitHub via `build.zig.zon`. No local path dependency.
- **Linking**: CLI executables statically link `libprogrez`.

## FFI Changes

### C Header (c/include/bzip2z.h)

```c
typedef void (*bzip2z_progress_fn)(uint64_t bytes_processed, uint64_t bytes_total, void* userdata);

typedef struct bzip2z_compress_options {
    uint8_t level;
    size_t threads;
    uint8_t multi_stream;
    bzip2z_progress_fn on_progress;    // NULL = no callback
    void* progress_userdata;
} bzip2z_compress_options_t;

typedef struct bzip2z_decompress_options {
    size_t threads;
    uint8_t parallel;
    uint8_t check_crc;
    bzip2z_progress_fn on_progress;    // NULL = no callback
    void* progress_userdata;
} bzip2z_decompress_options_t;
```

### Zig FFI (src/ffi.zig)

Translate C callback into a Zig callback passed to the core compress/decompress functions. The core calls it after each block is processed.

### Zig Core (src/bzip2.zig)

Add optional `on_progress` callback to `CompressOptions` and `DecompressOptions`. Fire after each block read (compression) or block decoded (decompression) with cumulative bytes processed.

## CLI Integration

### Progress callback

```c
static void progress_callback(uint64_t bytes_done, uint64_t bytes_total, void* userdata) {
    progrez_ctx* ctx = (progrez_ctx*)userdata;
    progrez_update(ctx, 0, bytes_done);
}
```

### File operations

For `compress_file()`, `decompress_file()`, `test_file()`:
- Create `progrez_ctx` if `isatty(STDERR_FILENO) && !opts->quiet`
- Set determinate mode with `input_len` as total bytes
- Set identity to `"bzip2z"` + file path
- Set label to `"Compressing"` / `"Decompressing"` / `"Testing"`
- Wire callback into FFI options
- After FFI call: `progrez_finish()` + `progrez_destroy()`

### Stdin operations

For `process_stdin()`:
- Default: indeterminate mode (total unknown until EOF)
- If `--size N` CLI flag or `BZIP2Z_SIZE=N` env var is set, use determinate mode with that as the total
- Same callback pattern, just switches between `progrez_set_indeterminate()` and `progrez_set_determinate()`

## Progress Behavior Matrix

| Operation | Mode | Total known? | Label |
|-----------|------|-------------|-------|
| File compress | Determinate | input file size | "Compressing" |
| File decompress | Determinate | compressed file size | "Decompressing" |
| File test | Determinate | compressed file size | "Testing" |
| Stdin compress | Indeterminate* | No | "Compressing" |
| Stdin decompress | Indeterminate* | No | "Decompressing" |

\* Becomes determinate if `--size N` or `BZIP2Z_SIZE=N` is provided.
| Any + `-q` | None | N/A | N/A |

## Build Changes

### build.zig.zon

Add progrez as a dependency fetched from GitHub:
```zon
.dependencies = .{
    .progrez = .{
        .url = "https://github.com/pmarreck/progrez/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

### build.zig

- Get progrez dependency: `b.dependency("progrez", .{ .target = target, .optimize = optimize })`
- Get its static library artifact and include path
- Link progrez to all three CLI executables (bzip2z, bunzip2z, bzcatz)
- Add progrez include path to CLI modules

### flake.nix

No changes needed - Zig handles the dependency fetch.

## Thread Safety

progrez_update() is thread-safe (internal seqlock). In multi-threaded mode (-j N), callbacks fire from worker threads. This is safe because:
1. progrez uses a seqlock for snapshot passing
2. Multiple writers are serialized by the seqlock's generation counter
3. The render thread reads independently on a timer

## Testing

- Existing CLI tests continue to work (progress is stderr-only, tests don't check stderr)
- Manual verification: compress/decompress large files and observe progress bar
- PROGRESS=false env var suppresses output (progrez built-in)
