---
description: "The compressor limits a block by its RLE1-encoded size, so a decoded block can expand past MAX_BLOCK_SIZE; decode buffers must be sized from the computed RLE-expanded length, not the fixed constant."
datetime: 2026-03-02T12:00:00-05:00 # EST
tags: [bzip2, rle, rle1, run-length, decompression, multi-block, buffer-sizing, overflow, max-block-size, decoder]
---
Fixed 2026-03-02. Multi-block decompression overflowed because
`expandInitialRle` checked output against the fixed `MAX_BLOCK_SIZE`, while
the compressor limits blocks by their RLE-encoded size. A block of long runs
legitimately expands well past that constant.

The fix was `computeRleExpandedSize()` plus reallocating the block and output
buffers to fit. The RLE1 expansion was later changed to stream through fixed
scratch space (peak memory for 32 MiB of zeros went from 70.7 MB to 5.7 MB).
Keep the invariant either way: never assume decoded size <= block-size
constant.
