# Bug: Two bzip2z issues on multi-block streams

## Bug 1: Decompression OutputOverflow on multi-block streams

`bzip2.decompress()` fails with `OutputOverflow` when the input data exceeds one bzip2 block (~900,000 bytes at level 9). Single-block streams decompress correctly. The bug is data-pattern-dependent — some multi-block inputs succeed while others fail.

### Reproduction

```zig
const std = @import("std");
const bzip2z = @import("bzip2z");

test "multi-block decompress fails with OutputOverflow" {
    const allocator = std.testing.allocator;

    // 900KB of data with specific pattern — exceeds one bzip2 block at level 9
    const size = 900_000;
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| {
        byte.* = @truncate(i *% 7 +% (i >> 16));
    }

    // Prepend ~200 bytes to push total past the block boundary
    const total_size = size + 200;
    const full_data = try allocator.alloc(u8, total_size);
    defer allocator.free(full_data);
    for (full_data[0..200]) |*b| b.* = 0x81;
    @memcpy(full_data[200..], data);

    const compressed = try bzip2z.bzip2.compress(allocator, full_data);
    defer allocator.free(compressed);

    // This fails with OutputOverflow:
    const decompressed = try bzip2z.bzip2.decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, full_data, decompressed);
}
```

### Key observations

- **Single-block OK**: Data < 900,000 bytes always round-trips correctly.
- **Multi-block FAILS**: Data > 900,000 bytes (2+ bzip2 blocks at level 9) fails on decompression with `OutputOverflow`.
- **Pattern-dependent**: Some multi-block inputs work (e.g., `i *% 7 +% (i >> 16)` directly at 950KB succeeds, but the same pattern preceded by 200 bytes of `0x81` at 900KB+ fails). Suggests the bug is in block-boundary handling with certain data patterns.

## Bug 2: Compression SIGBUS on large data with page_allocator

When compressing ~232MB of real-world data (game assets: TGA textures, save files) through Zig's `page_allocator` (mmap-backed), `bzip2.compress()` crashes with SIGBUS (Bus error, signal 10).

With `testing.allocator` (debug allocator wrapping page_allocator), the same code path does not crash — compression succeeds, but the subsequent decompression fails with OutputOverflow (Bug 1 above). This suggests an out-of-bounds memory access during compression that `testing.allocator`'s safety checks catch/handle, while `page_allocator`'s mmap regions trigger SIGBUS.

### Reproduction

```bash
# In the BLIP project — any ~232MB directory of mixed binary files will do
blar create -z bzip2 -o /tmp/test.blar ~/some/large/directory
# -> Bus error: 10
```

These two bugs may share a root cause in multi-block buffer management.

## Impact on BLIP

BLIP has temporarily excluded bzip2 from large-payload tests and added skipped regression tests until these are fixed upstream.

## Discovered

2026-03-02 during BLIP bzip2 integration testing.
