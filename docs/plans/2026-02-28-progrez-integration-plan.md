# Progrez Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add progress bar display (via pmarreck/progrez) to bzip2z CLI compress/decompress/test operations.

**Architecture:** Add optional progress callback to Zig CompressOptions/DecompressOptions. The FFI layer translates C function pointers. The C CLI creates a progrez_ctx, passes a callback that calls progrez_update(), and finishes/destroys it after the FFI call returns.

**Tech Stack:** Zig (core + FFI), C (CLI), progrez (progress library via Zig package fetch)

---

### Task 1: Add progrez as a Zig build dependency

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`

**Step 1: Add progrez dependency to build.zig.zon**

Add a `.dependencies` section that fetches progrez from GitHub. Use the latest commit on `yolo` branch.

Run:
```bash
# Get the URL hash Zig needs (Zig 0.15+ can compute it):
zig fetch https://github.com/pmarreck/progrez/archive/yolo.tar.gz
```

The output gives you the hash. Add to `build.zig.zon`:

```zon
.dependencies = .{
    .progrez = .{
        .url = "https://github.com/pmarreck/progrez/archive/<commit-hash>.tar.gz",
        .hash = "<hash-from-zig-fetch>",
    },
},
```

**Step 2: Wire progrez into build.zig**

In `build.zig`, after creating `ffi_lib` and before creating the CLI executables:

```zig
const progrez_dep = b.dependency("progrez", .{
    .target = target,
    .optimize = optimize,
});
const progrez_lib = progrez_dep.artifact("progrez");
```

Then for each CLI executable (cli, bunzip2, bzcat), add:

```zig
cli.linkLibrary(progrez_lib);
cli.root_module.addIncludePath(progrez_dep.path("include"));
```

**Step 3: Verify the build compiles**

Run: `./build`
Expected: Clean build, no errors. The progrez library is linked but not yet used.

**Step 4: Commit**

```bash
git add build.zig.zon build.zig
git commit -m "Add progrez as Zig build dependency"
```

---

### Task 2: Add progress callback to Zig core options

**Files:**
- Modify: `src/bzip2.zig:109-144` (CompressOptions, DecompressOptions)

**Step 1: Write a failing test**

In `src/bzip2.zig`, add a test near the existing compress tests that verifies the callback fires:

```zig
test "compress calls on_progress callback" {
    const allocator = std.testing.allocator;
    const input = "Hello, world! This is a test of progress callbacks." ** 100;

    const State = struct {
        call_count: usize = 0,
        last_bytes: u64 = 0,
        total: u64 = 0,
    };
    var state = State{};

    const result = try compressWithOptions(allocator, input, .{
        .level = 1,
        .on_progress = struct {
            fn cb(bytes_processed: u64, bytes_total: u64, userdata: ?*anyopaque) void {
                const s: *State = @ptrCast(@alignCast(userdata));
                s.call_count += 1;
                s.last_bytes = bytes_processed;
                s.total = bytes_total;
            }
        }.cb,
        .progress_userdata = @ptrCast(&state),
        .progress_bytes_total = input.len,
    });
    defer allocator.free(result);

    try std.testing.expect(state.call_count > 0);
    try std.testing.expectEqual(@as(u64, input.len), state.total);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -20`
Expected: Compile error — `on_progress` field doesn't exist on CompressOptions.

**Step 3: Add callback fields to CompressOptions and DecompressOptions**

In `src/bzip2.zig`, modify `CompressOptions` (line 109):

```zig
pub const CompressOptions = struct {
    level: u8 = 9,
    threads: usize = 1,
    multi_stream: bool = false,
    on_progress: ?*const fn (u64, u64, ?*anyopaque) void = null,
    progress_userdata: ?*anyopaque = null,
    progress_bytes_total: u64 = 0,

    pub fn blockSizeBytes(self: CompressOptions) Error!usize { ... }
    pub fn resolvedThreads(self: CompressOptions) usize { ... }
};
```

And `DecompressOptions` (line 132):

```zig
pub const DecompressOptions = struct {
    threads: usize = 1,
    parallel: bool = false,
    on_progress: ?*const fn (u64, u64, ?*anyopaque) void = null,
    progress_userdata: ?*anyopaque = null,
    progress_bytes_total: u64 = 0,

    pub fn resolvedThreads(self: DecompressOptions) usize { ... }
};
```

**Step 4: Run test to verify it still fails (compiles but callback not fired)**

Run: `zig build test -Dtest-filter="compress calls on_progress" 2>&1`
Expected: Test fails because `state.call_count` is still 0 (callback not wired into block loop yet).

**Step 5: Commit**

```bash
git add src/bzip2.zig
git commit -m "Add progress callback fields to CompressOptions and DecompressOptions"
```

---

### Task 3: Fire progress callback in compression block loops

**Files:**
- Modify: `src/bzip2.zig` — `compressStreamWithOptions` (line 2513)

**Step 1: Wire callback into single-threaded compress loop**

In `compressStreamWithOptions`, at line ~2513, after the block_reader init, add a `bytes_processed` tracker. In the single-threaded loop (line 2529), after `writeBlock` and `updateStreamCrc`, fire the callback:

```zig
// At the top of compressStreamWithOptions, after block_reader init:
var bytes_processed: u64 = 0;

// In the single-threaded loop, after writeBlock + updateStreamCrc (line ~2540):
bytes_processed += data.len;
if (options.on_progress) |cb| {
    cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
}
```

Do the same in the multi-threaded loop (line ~2602, after writeBlock in the result drain):

```zig
// After writeBlock + updateStreamCrc in the pending drain (line ~2602):
bytes_processed += block.original_len; // Need to track this — see note below
if (options.on_progress) |cb| {
    cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
}
```

**Note on multi-threaded:** The `BlockPrepared` struct may not store the original data length. If not, add an `original_len: usize` field to `BlockPrepared` and populate it in `prepareBlock`. Alternatively, track it in `BlockTask` and pass through `BlockResult`. Choose whichever is simplest.

Also do the same for the multi-stream single-threaded loop (line ~2655) and multi-stream multi-threaded loop (line ~2670).

**Step 2: Run the test from Task 2**

Run: `zig build test -Dtest-filter="compress calls on_progress" 2>&1`
Expected: PASS — callback fires at least once, bytes_total matches input.len.

**Step 3: Commit**

```bash
git add src/bzip2.zig
git commit -m "Fire progress callback in compression block loops"
```

---

### Task 4: Fire progress callback in decompression

**Files:**
- Modify: `src/bzip2.zig` — `Decompressor.decompressInternal` (line 451), standalone `decompressInternal` (line 2803), `decompressWithOptions` (line 2785), `decompressParallel` (line 2964)

**Step 1: Write a failing test**

```zig
test "decompress calls on_progress callback" {
    const allocator = std.testing.allocator;
    const input = "Decompress progress test data string." ** 50;

    const compressed = try compressWithOptions(allocator, input, .{ .level = 1 });
    defer allocator.free(compressed);

    const State = struct {
        call_count: usize = 0,
        last_bytes: u64 = 0,
    };
    var state = State{};

    const result = try decompressWithOptions(allocator, compressed, .{
        .on_progress = struct {
            fn cb(bytes_processed: u64, bytes_total: u64, userdata: ?*anyopaque) void {
                _ = bytes_total;
                const s: *State = @ptrCast(@alignCast(userdata));
                s.call_count += 1;
                s.last_bytes = bytes_processed;
            }
        }.cb,
        .progress_userdata = @ptrCast(&state),
        .progress_bytes_total = compressed.len,
    });
    defer allocator.free(result);

    try std.testing.expect(state.call_count > 0);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter="decompress calls on_progress" 2>&1`
Expected: FAIL — callback not yet wired.

**Step 3: Thread callback into decompression pipeline**

The approach: modify the standalone `decompressInternal` (line 2803) and `decompressWithOptions` (line 2785) to pass callback info down.

Option A (simplest): Add callback fields to the `Decompressor` struct itself:

```zig
// In the Decompressor struct, add fields:
on_progress: ?*const fn (u64, u64, ?*anyopaque) void = null,
progress_userdata: ?*anyopaque = null,
progress_bytes_total: u64 = 0,
progress_bytes_read: u64 = 0,
```

In `Decompressor.decompressInternal` (line 451), after each block decode (line ~515, after `writer.write`):

```zig
// After the writer.write call:
self.progress_bytes_read += self.output_len;  // track decompressed bytes as proxy
if (self.on_progress) |cb| {
    cb(self.progress_bytes_read, self.progress_bytes_total, self.progress_userdata);
}
```

**Note:** `self.output_len` is the decompressed block size, not the compressed bytes consumed. For accurate compressed-byte tracking, you'd need to track the BitReader position. For a first pass, tracking decompressed bytes works — the progress bar just uses a different total (pass decompressed total estimate, or use indeterminate with throughput). ALTERNATIVELY: wrap the reader in a counting reader before passing to the decompressor.

**Recommended approach:** Use a `CountingReader` wrapper:

```zig
fn CountingReader(comptime Inner: type) type {
    return struct {
        inner: Inner,
        bytes_read: *u64,

        pub fn read(self: *@This(), buf: []u8) !usize {
            const n = try self.inner.read(buf);
            self.bytes_read.* += n;
            return n;
        }
    };
}
```

In the standalone `decompressInternal` (line 2803):

```zig
fn decompressInternal(allocator: Allocator, input: []const u8, check_crc: bool, options: DecompressOptions) ![]u8 {
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();
    // Copy callback info to decompressor
    decompressor.on_progress = options.on_progress;
    decompressor.progress_userdata = options.progress_userdata;
    decompressor.progress_bytes_total = options.progress_bytes_total;

    var input_stream = std.io.fixedBufferStream(input);
    var bytes_read: u64 = 0;
    decompressor.progress_bytes_read_ptr = &bytes_read;
    // Use a counting reader wrapper... or just check input_stream.pos after each block
    ...
}
```

The simplest approach for byte-accurate tracking in the buffer case: after each block in `Decompressor.decompressInternal`, fire callback with `input_stream.pos`. But `Decompressor.decompressInternal` doesn't have access to the fixedBufferStream. The BitReader wraps the reader.

**Pragmatic recommendation:** Store a `*u64` "position pointer" on the Decompressor. Before calling `decompressor.decompressInternal()`, point it at a counter that gets updated. Use a counting reader wrapper around the fixedBufferStream's reader. The Decompressor fires the callback after each block using `self.position_ptr.*`.

The implementation details are flexible — the key requirement is that the test passes: the callback fires at least once during decompression with increasing bytes_processed values.

**Step 4: Update callers**

Modify `decompressWithOptions` (line 2785), `decompressParallel` (line 2964), and the standalone `decompressInternal` (line 2803) to thread the options through. For `decompressParallel`, fire the callback from the main thread after each stream result is gathered (using cumulative stream offsets as bytes_processed — these are exact since `offsets[]` contains the compressed byte positions).

**Step 5: Run test**

Run: `zig build test -Dtest-filter="decompress calls on_progress" 2>&1`
Expected: PASS

**Step 6: Run full test suite**

Run: `zig build test 2>&1`
Expected: All tests pass. Existing tests unaffected since on_progress defaults to null.

**Step 7: Commit**

```bash
git add src/bzip2.zig
git commit -m "Fire progress callback in decompression pipeline"
```

---

### Task 5: Add progress callback to C FFI

**Files:**
- Modify: `c/include/bzip2z.h`
- Modify: `src/ffi.zig`

**Step 1: Update C header with callback type and fields**

In `c/include/bzip2z.h`, add the callback typedef and extend both options structs:

```c
typedef void (*bzip2z_progress_fn)(uint64_t bytes_processed, uint64_t bytes_total, void* userdata);

typedef struct bzip2z_compress_options {
    uint8_t level;
    size_t threads;
    uint8_t multi_stream;
    bzip2z_progress_fn on_progress;
    void* progress_userdata;
    uint64_t progress_bytes_total;
} bzip2z_compress_options_t;

typedef struct bzip2z_decompress_options {
    size_t threads;
    uint8_t parallel;
    uint8_t check_crc;
    bzip2z_progress_fn on_progress;
    void* progress_userdata;
    uint64_t progress_bytes_total;
} bzip2z_decompress_options_t;
```

**Step 2: Update Zig FFI structs and translation**

In `src/ffi.zig`, update `Bzip2zCompressOptions` and `Bzip2zDecompressOptions` extern structs to match the C header. Then update `compressOptionsFromC` and `decompressOptionsFromC` to translate the callback fields:

```zig
pub const Bzip2zProgressFn = ?*const fn (u64, u64, ?*anyopaque) callconv(.c) void;

pub const Bzip2zCompressOptions = extern struct {
    level: u8,
    threads: usize,
    multi_stream: u8,
    on_progress: Bzip2zProgressFn,
    progress_userdata: ?*anyopaque,
    progress_bytes_total: u64,
};

pub const Bzip2zDecompressOptions = extern struct {
    threads: usize,
    parallel: u8,
    check_crc: u8,
    on_progress: Bzip2zProgressFn,
    progress_userdata: ?*anyopaque,
    progress_bytes_total: u64,
};
```

In `compressOptionsFromC`:

```zig
fn compressOptionsFromC(options: ?*const Bzip2zCompressOptions) core.CompressOptions {
    if (options) |opt| {
        return .{
            .level = if (opt.level == 0) 9 else opt.level,
            .threads = opt.threads,
            .multi_stream = opt.multi_stream != 0,
            .on_progress = @ptrCast(opt.on_progress),
            .progress_userdata = opt.progress_userdata,
            .progress_bytes_total = opt.progress_bytes_total,
        };
    }
    return .{};
}
```

Same pattern for `decompressOptionsFromC`.

**Important:** The C callback uses `callconv(.c)` while the Zig callback is the default Zig calling convention. You may need a thin wrapper function in the FFI layer that converts between calling conventions, OR make the Zig callback type also use `.c` calling convention. The simplest approach: make the Zig core callback type `callconv(.c)` too (it's just a function pointer, the convention doesn't matter for the logic).

**Step 3: Verify build**

Run: `./build`
Expected: Clean compile. The FFI now passes callback pointers through but the CLI doesn't set them yet.

**Step 4: Commit**

```bash
git add c/include/bzip2z.h src/ffi.zig
git commit -m "Add progress callback to C FFI options structs"
```

---

### Task 6: Wire progrez into the C CLI

**Files:**
- Modify: `c/cli.c`

**Step 1: Add progrez include and callback**

At the top of `c/cli.c`, add:

```c
#include "progrez.h"
#include <unistd.h>  // for isatty, STDERR_FILENO
```

Add the progress callback function:

```c
static void progress_callback(uint64_t bytes_done, uint64_t bytes_total, void* userdata) {
    progrez_ctx* ctx = (progrez_ctx*)userdata;
    (void)bytes_total;
    progrez_update(ctx, 0, bytes_done);
}
```

**Step 2: Add --size flag and BZIP2Z_SIZE env var to CLI parsing**

In the `cli_options_t` struct, add:

```c
uint64_t stdin_size;  // 0 = unknown
```

In `parse_args`, add handling for `--size N`:

```c
if (strcmp(arg, "--size") == 0) {
    if (i + 1 >= argc) return -1;
    size_t val;
    if (!parse_size(argv[i + 1], &val)) return -1;
    opts->stdin_size = (uint64_t)val;
    i++;
    continue;
}
```

In `main()`, after parse_args, check env var:

```c
if (opts.stdin_size == 0) {
    const char* env_size = getenv("BZIP2Z_SIZE");
    if (env_size != NULL) {
        size_t val;
        if (parse_size(env_size, &val)) {
            opts.stdin_size = (uint64_t)val;
        }
    }
}
```

Also update the usage string to document `--size`.

**Step 3: Add progress helper functions**

```c
static progrez_ctx* progress_start(const char* label, const char* path,
                                   uint64_t bytes_total, const cli_options_t* opts) {
    if (opts->quiet) return NULL;
    if (!isatty(STDERR_FILENO)) return NULL;

    progrez_ctx* ctx = progrez_create(label);
    if (ctx == NULL) return NULL;

    progrez_set_identity(ctx, "bzip2z", path ? path : "stdin");
    if (bytes_total > 0) {
        progrez_set_determinate(ctx, 0, bytes_total);
    } else {
        progrez_set_indeterminate(ctx);
    }
    return ctx;
}

static void progress_end(progrez_ctx* ctx) {
    if (ctx == NULL) return;
    progrez_finish(ctx);
    progrez_destroy(ctx);
}
```

**Step 4: Wire progress into compress_file**

In `compress_file()`, after `read_file` succeeds and before `run_compress_bytes`:

```c
progrez_ctx* pctx = progress_start("Compressing", path, (uint64_t)input_len, opts);
copt.on_progress = pctx ? progress_callback : NULL;
copt.progress_userdata = pctx;
copt.progress_bytes_total = (uint64_t)input_len;
```

After the compress call (before any return):

```c
progress_end(pctx);
```

Make sure `progress_end` is called on ALL exit paths (success, error, output-exists).

**Step 5: Wire progress into decompress_file**

Same pattern as compress_file, but label is "Decompressing" and bytes_total is the compressed file size (`input_len`).

**Step 6: Wire progress into test_file**

Same pattern, label is "Testing", bytes_total is `input_len`.

**Step 7: Wire progress into process_stdin**

```c
progrez_ctx* pctx = progress_start(
    opts->mode == MODE_COMPRESS ? "Compressing" : "Decompressing",
    NULL,
    opts->stdin_size,  // 0 = indeterminate, >0 = determinate
    opts
);
```

Wire callback into the compress/decompress options, call `progress_end(pctx)` after.

**Step 8: Initialize new fields in options structs**

In `run_compress_bytes` and `run_decompress_bytes`, make sure the new fields are zero-initialized when not using progress. The simplest way: initialize the entire struct to zero before populating:

```c
bzip2z_compress_options_t copt = {0};
copt.level = opts->level;
copt.threads = opts->threads;
copt.multi_stream = opts->pbzip2 ? 1 : 0;
```

Or keep the existing pattern and explicitly set the new fields.

**Step 9: Build and manually test**

Run: `./build`

Test manually:
```bash
# Create a test file
head -c 10000000 /dev/urandom > /tmp/test.bin

# Compress with progress
./zig-out/bin/bzip2z -k /tmp/test.bin

# Decompress with progress
./zig-out/bin/bzip2z -dk /tmp/test.bin.bz2

# Test with progress
./zig-out/bin/bzip2z -t /tmp/test.bin.bz2

# Verify quiet suppresses progress
./zig-out/bin/bzip2z -qk /tmp/test.bin

# Verify no progress when stderr is piped
./zig-out/bin/bzip2z -k /tmp/test.bin 2>/dev/null

# Stdin with --size
cat /tmp/test.bin | ./zig-out/bin/bzip2z --size 10000000 > /tmp/test.bin.bz2

# Stdin without --size (indeterminate spinner)
cat /tmp/test.bin | ./zig-out/bin/bzip2z > /tmp/test.bin.bz2

# PROGRESS=false disables
PROGRESS=false ./zig-out/bin/bzip2z -k /tmp/test.bin
```

**Step 10: Run automated tests**

Run: `zig build test && bash tests/cli_test`
Expected: All pass. CLI tests don't check stderr so progress output doesn't interfere.

**Step 11: Commit**

```bash
git add c/cli.c
git commit -m "Wire progrez progress bar into CLI operations"
```

---

### Task 7: Update flake.nix for CI compatibility

**Files:**
- Modify: `flake.nix` (if needed)

**Step 1: Verify Nix build works**

The Zig build system fetches progrez from GitHub automatically, so `flake.nix` shouldn't need changes for the dependency itself. However, the Nix sandbox blocks network access during builds. Zig's package fetch needs network.

Check if `zig fetch` works in Nix sandbox. If not, you'll need to add progrez as a Nix flake input and override the Zig dependency resolution, OR use `nativeBuildInputs` to provide the progrez source.

Run: `nix build .#ci-tests --print-build-logs 2>&1 | tail -30`

If it fails due to network access, add to `flake.nix`:

```nix
nativeBuildInputs = [
    pkgs.bash
    pkgs.coreutils
    pkgs.zig
    pkgs.bzip2
    pkgs.pbzip2
];

# Add network access for zig fetch:
__noChroot = true;  # Last resort
# OR: vendor the dependency
```

The preferred fix: use `zig fetch --global-cache-dir` during the build phase to pre-populate the dependency. This requires network access.

**Alternative:** If Nix sandboxing is a problem, vendor progrez as a git submodule or use Nix's `fetchFromGitHub` and point Zig at it via `--system` or overlay.

**Step 2: Verify all CI targets build**

Run: `nix build .#ci-linux-x86_64 --print-build-logs 2>&1 | tail -10`

**Step 3: Commit if changes needed**

```bash
git add flake.nix
git commit -m "Update flake.nix for progrez dependency in CI"
```

---

### Task 8: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `c/cli.c` (usage string, already done in Task 6)

**Step 1: Update README CLI usage section**

Add a note about progress display:

```markdown
## Progress display

bzip2z shows a progress bar on stderr when the terminal is interactive. Features include:
- Determinate progress with ETA for file operations
- Throughput display (MB/s)
- Indeterminate spinner for stdin (use `--size N` or `BZIP2Z_SIZE=N` for determinate)
- Suppressed with `-q`/`--quiet` or `PROGRESS=false`
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "Document progress bar in README"
```

---

### Task 9: Final integration test and push

**Step 1: Full test suite**

Run:
```bash
zig build test && bash tests/cli_test
```
Expected: All pass.

**Step 2: Cross-compile check**

Run:
```bash
./build -Dtarget=x86_64-windows-gnu
```
Expected: Builds (progrez should cross-compile since it's pure Zig + libc).

**Step 3: Push**

```bash
git push
```

**Step 4: Monitor CI**

```bash
gh run watch --exit-status
```

Wait for both GitHub Actions and Garnix to go green.
