---
description: "In src/sais.zig the sentinel is 0 and bytes map to byte+1; type classification, lmsEqual and bucket sorting must all use that same mapping (getChar), or input containing 0x00 bytes is confused with the sentinel."
datetime: 2026-03-02T12:00:00-05:00 # EST
tags: [sa-is, sais, suffix-array, induced-sorting, bwt, burrows-wheeler, sentinel, alphabet-mapping, getchar, lmsequal, zero-bytes, binary-data]
---
Fixed 2026-03-02. `buildSuffixArraySAIS` classified suffix types and compared
LMS substrings (`lmsEqual`) with raw byte values 0..255, while bucket sorting
used byte+1 (1..256) with sentinel 0. Binary input with 0x00 bytes then
collided with the sentinel.

Symptoms: "integer does not fit in destination type" at `saisRecurse` step 8,
and SIGBUS with page_allocator on large binary data.

Invariants worth keeping in mind when touching SA-IS (now `src/sais.zig`,
re-exported from `bzip2.zig`; its tests still live in `bzip2.zig`):

- The sentinel must be the unique smallest character. This is critical for
  correct recursion.
- `saisRecurse` (integer alphabet) assumes its text ends with the unique value
  0, which the parent's naming step sets.
- The BWT builds the suffix array of input++input and keeps only positions
  < n (string doubling for rotations).
