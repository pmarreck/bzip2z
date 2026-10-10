# bzip2 decoder integrity evidence

A retraceable record of which corruption checks bzip2z's decoder applies, how
each was confirmed, what was tried and rejected, and what remains undetectable.
It supports downstream integrity checkers (for example `validate`) that report
how deeply a bzip2 payload was verified.

Terminology follows validate's glossary (`TERMINOLOGY.md` in the validate
repository). There, **MKTP** ("Maximum Known Technically Possible") is a
per-variant status that requires all six of its listed criteria, including an
analytically derived ceiling, mutation coverage against a pristine control,
independent replay, and a row in validate's committed MKTP ledger (a
blessed-hash control file). End-to-end consumption plus an invariant
inventory is not sufficient. This record is supporting evidence for such a
decision; it is not a ledger row and does not by itself establish MKTP for any
bzip2 variant. bzip2 carries a mandatory CRC32 over every block's decoded bytes
and a combined CRC per stream, so most damage is detectable; the residual
blind class below is small but real.

**Authority of reference evidence.** bzip2 has no official normative
specification; its reference implementation serves as the de facto
definition. A reference verdict shows
decodability and interoperability for that input; it is not proof that a
bitstream constraint is required or forbidden by the format.

## Provenance

bzip2z is a clean-room implementation. No reference bzip2 source was read for
this work. Candidate invariants come from published descriptions of the bzip2
bitstream format, and every claim about reference behavior below was confirmed
only through the reference `bzip2` binary's exit status on crafted or mutated
inputs (black-box oracle). The language model that assisted with this work may
have seen the reference implementation in its training data; that prior can
influence which hypotheses were tested, but it cannot confirm them.
Confirmation rests on the oracle runs and tests recorded here.

## Which tree produced each result

Every result in this record was produced in an isolated git worktree checked
out from a pushed commit, never from a working copy with unrelated
uncommitted changes:

- Crafted differential, unit tests and all three build modes: worktree at
  `e3a0773`, then `75e24cc`, then the tree committed as `cfd3b7c`, with each
  suite run immediately before its commit and no other edits in between.
- Sniper sweep binary `5d38bf33…`: built in that worktree at `75e24cc` (the
  sweep script itself was uncommitted at the time and is not part of the
  binary). Replay binary `ccd7ddfd…`: built from the `cfd3b7c` sources.
- Exact-commit replays in a clean detached worktree (zero dirty files
  before and after): `./test` at `fa2ceb3` passed (direct run, bounded only
  by a timeout), and `./test`, a ReleaseSafe build and one classifier/v2
  sweep at `08b0fcb` ran as a single job under the shared build budget
  (2 slots, 16 GiB cap, no swap). See "classifier/v2 replay" below.

A separate check ran the suite on a developer working copy that also held
unrelated uncommitted work. It is not evidence for any commit and is not
cited here.

## Pins (2026-10-09/10)

| Item | Value |
|---|---|
| bzip2z source | `yolo` after `75e24cc` (evidence commits `e3a0773`, `75e24cc` and the commit adding this file) |
| Zig | 0.16.0, `/nix/store/scvi7gqki0dfc2d602938xrcy0ilv8d9-zig-0.16.0` |
| nixpkgs / zig-overlay | `39ad350a0602fa0a58a544344e3e9187526ea45c` / `7230e5bc95c5e1698d51cdebbfca9752b06b0903` |
| Reference oracle | bzip2 1.0.8 (13-Jul-2019), `/nix/store/gz6baw96bf48pxs93kc7rxmnr1ra7g4m-bzip2-1.0.8-bin/bin/bzip2` |
| Sweep driver | LuaJIT 2.1.1785763465 (from the flake dev shell) |
| Sweep binary | `bzip2z` CLI, `zig build -Doptimize=ReleaseSafe`, x86_64-linux. Runs used sha256 `5d38bf33222c81118ae460bb548a783429d4d2cda28f98ef6d0d93ba4e403c96` (at `75e24cc`) and, for the replay, `ccd7ddfdad7ab510025a889ff4b40bfe8411b240431536b552c1b131ac2e8c92` (after a test was added to `src/bzip2.zig`; the decoder code was unchanged, and shifted source line numbers in ReleaseSafe safety metadata are the likely cause, not verified). Rebuild to replay. |

## Invariant inventory

"Indirect" means the check is in the code path every sniper trial runs, but
no test isolates it: the sweep records only accept, reject or crash, not which
check rejected.

| Invariant | Where enforced | Evidence |
|---|---|---|
| Stream magic `BZh` and level digit `1`-`9` | `decodeStreams` | crafted test "bad magic on second stream"; indirect |
| Block or footer 48-bit magic | `decodeStreams` | indirect |
| Symbol map has at least one byte value | `readSymbolMap` | crafted differential (fixed 2026-10-09) |
| Huffman group count 2-6; selector count >= 1 | `readBlock` | indirect |
| Selector count up to 32767 accepted, first 18002 kept | `readSelectors` | crafted differential (fixed 2026-10-09; previously a false positive). Authority: the selector-count field is 15 bits wide in the format description, and the reference binary decodes an 18010-selector stream; that is interoperability evidence, not a normative statement |
| Selector MTF index < group count | `readSelectors` | indirect |
| Code lengths 1-20 throughout delta coding | `readHuffmanTrees` | indirect |
| Huffman decode terminates within 20 bits | `HuffmanTable.decode` | indirect; no-panic sweeps in Debug and ReleaseSafe |
| RUNA/RUNB run weight < 2^21 | `readCompressedData` | crafted tests (40 RUNB, 64 RUNA), Debug and ReleaseSafe |
| MTF symbol index < symbols in use | `readCompressedData` | indirect |
| Block symbols <= level digit x 100000 | `readCompressedData` | crafted differential (level `1` over a >100k block); per-digit test |
| Block decodes to >= 1 symbol; origin pointer < block length | `inverseBwt` | crafted differential (empty block fixed 2026-10-09; out-of-range pointer) |
| Initial-RLE run has its count byte | `emitInitialRle` | unit test |
| Block CRC32 over decoded bytes | `decodeBlockInternal` | Diagnostics test (stored-CRC flip) |
| Combined stream CRC | `decodeStreams` | Diagnostics test (footer-CRC flip) |
| Concatenated streams decoded in order | `decodeStreams` | round-trip and pbzip2 interop tests |
| EOF only at a stream boundary (1-3 header bytes is an error) | `decodeStreams` | per-tail classifier test |
| Data after a complete stream is reported | `decodeStreams` | intentional divergence, see below |
| Memory bounded by block, not stream or run length | decoder structure | peak-allocation metamorphic tests |

## Experiments

### Crafted structural differential (in `./test`)

Test "differential: crafted structural cases agree with reference bzip2" in
`src/bzip2.zig` builds single-block streams with chosen fields
(`craftStream`) and compares bzip2z's verdict with `bzip2 -tq`. Before the
2026-10-09 fixes it reported three disagreements; after them, none:

| Case | bzip2z before | Reference | bzip2z after |
|---|---|---|---|
| Pristine controls (encoder block, compressed text) | accept | accept | accept |
| Selector count exactly 18002 | accept | accept | accept |
| Selector count 18010 | reject | accept | accept |
| Block with only end-of-block | accept | reject | reject (InvalidBwtIndex) |
| Empty symbol map, only end-of-block | accept | reject | reject (CorruptData) |
| Origin pointer beyond block length | reject | reject | reject |
| Level digit `1` over a >100k-symbol block | reject | reject | reject |
| Padding bits after the footer set to 1 | accept | accept | accept |

### Randomized blocks and degenerate Huffman tables (in `./test`)

Test "differential: randomized blocks and degenerate Huffman tables" in
`src/bzip2.zig` decodes crafted streams with both bzip2z and `bzip2 -dc`.
For each case it checks the verdict and the exact output bytes of each
decoder against an expected result, and the SHA-256 of the crafted stream
against a pinned value. A reference exit other than 0 or 2 is an experiment
error, never a verdict.

The expected verdicts come from the format description, not from either
decoder. In the dsnet/compress `doc/bzip2-format.pdf` (sections 2.2.3.2.3 and
appendix B examples), code lengths are 1 to 20 and assigned canonically. An
incomplete or over-subscribed table is technically invalid, but a decoder
fails only when the data uses a code the table leaves unassigned. Its
worked examples assign the same codes as bzip2z's canonical construction.
The document's appendix containing ported reference code was not read.

| Case (alphabet RUNA, RUNB, MTF1, EOB; data "ab") | Expected | bzip2z | Reference |
|---|---|---|---|
| Encoder tables (control) | "ab" | "ab" | "ab" |
| Lengths {3,3,1,2}, Kraft sum 1 | "ab" | "ab" | "ab" |
| Lengths {2,2,1,1}, over-subscribed, used codes assigned | "ab" | "ab" | "ab" |
| Lengths {3,3,1,3}, incomplete, used codes assigned | "ab" | "ab" | "ab" |
| All lengths 20, incomplete | "ab" | "ab" | "ab" |
| Lengths {3,3,1,3}, EOB sent as unassigned code 111 | reject | reject (HuffmanOverflow, phase symbol_data) | reject |
| Randomized block, 2000 bytes | original bytes | wrong before fix | original bytes |
| Randomized block, 300000 bytes (past the 512-entry table wrap) | original bytes | wrong before fix | original bytes |

The Huffman cases found no disagreement. The randomized cases found a decoder
bug. bzip2z toggled the first byte one position late, at index 618 instead
of 617, and every later toggle inherited the offset. The bug went unnoticed
because the only earlier test checked `derandomize` against positions derived
from its own loop. Single-toggle black-box probes against the reference
located its first two toggles at indexes 617 and 1337. Starting the counter
at 1 fixes it. The 300000-byte case passes every toggle in the 512-entry table
(sum 277732), and its block CRC checks each position against the reference.
Before the fix the reference rejected both crafted streams (exit 2, CRC
error) while bzip2z accepted them. A randomized stream from an old encoder
would have decoded to wrong bytes and then failed bzip2z's block CRC check,
so it was reported as corrupt (inferred from the CRC check; no real legacy
randomized stream was tested).


### Sniper sweep against the reference (bounded campaign)

`tests/differential/sniper-vs-reference BZIP2Z_BIN [REFERENCE_BIN]` flips one
bit per trial (sniper/v1: one bit XOR 1) of a deterministic corpus encoded by
the reference encoder, then compares exit statuses. Crashes (exit >= 128) are
counted separately from rejections. Run time was about 130 s on an x86_64-linux
host under other load. Replay:

```
nix develop -c zig build -Doptimize=ReleaseSafe
nix develop -c bash -c 'tests/differential/sniper-vs-reference "$PWD/zig-out/bin/bzip2z" "$(command -v bzip2)"'
```

Corpus (seed 20261009; pristine controls accepted by both decoders):

| Name | Bytes | Stride | sha256 |
|---|---|---|---|
| text-1500-l9 | 274 | 1 (exhaustive) | `903b01abcc3f93e979e99d1071ce66dd4f869b268fc547ee116e7fe1bb3e829f` |
| two-streams | 410 | 1 (exhaustive) | `d55f478011b5567f2433406991297142ada5925400e3b4fb8d40971fd471d68b` |
| pattern-101000-l1-two-blocks | 1740 | 7 (coprime with 8) | `74599d4fa8fe2db970999879520c2891646f3a739d80daef531ba71a332565de` |

Historical result with classifier/v1 (2026-10-09/10; three runs plus one
replay with the documented command at `cfd3b7c`, all identical). These counts
are preserved as measured. classifier/v1 had three limitations, corrected in
classifier/v2 (see "Classifier versions" below):

| Outcome | Trials |
|---|---|
| Both reject | 7402 |
| Both accept (residual blind class) | 29 |
| Intentional divergence (corrupted second-stream header) | 30 |
| bzip2z-only reject | 0 |
| Reference-only reject | 0 |
| bzip2z crash / reference crash | 0 / 0 |
| Total | 7461 |

These are deterministic counts over a fixed mutation domain, not a sample
estimate of real-world damage. The multi-block stream is covered at one bit
in seven.

#### classifier/v2 replay (2026-10-10, `08b0fcb`)

| Item | Value |
|---|---|
| Source | `08b0fcb49e853c560b9d3a764f7b6fef1d9172c7`, clean detached worktree |
| `./test` | exit 0 |
| Binary | ReleaseSafe `bzip2z`, sha256 `bc61ad75c2ff0943b46401e51a1529749eea61d898df0f836ffcbb4a44afe765` |
| Oracle | the reference bzip2 1.0.8 path in the Pins table |
| Mutation / classifier | sniper/v1 (corpus seed 20261009) / classifier/v2 |
| Sweep result | exit 0: no crash, no experiment error, no unexplained disagreement on either side |

The scheduler job itself exited 0 only because its wrapper ended with an
`echo`; that aggregate status establishes nothing. The rows above come from
the wrapper's own per-step lines, each printing the preceding command's
exit status (`./test exit 0`, `build exit 0`, `sweep exit 0`). Those lines
were recovered from the session transcript and are kept, with the wrapper
script and their sha256 sums, in a private state directory outside any
temporary directory (wrapper stdout sha256 `533b67bcc70345a033e7826c36398e465e67d0c962dcc04c472961594e1d8230`).

The per-outcome counts and corpus hashes from this replay were lost. The
job's JSON and stderr went to the build budget's per-job scratch directory,
which is deleted when a job succeeds. Exit 0 under v2 means no trial was
classified as failing, but the both-accept, both-reject and divergence
counts were not retained. A capped rerun writing outside the scratch
directory was withdrawn before admission, to avoid an automatic retry and
leave the next build slot to another project. Until a deliberate replay
records them, the v2 counts are unknown, and the v1 table above remains the
only measured breakdown.

#### Replay runner

Future replays use `tests/differential/replay-runner`, run from a clean
checkout of the commit under test. It refuses a dirty tree and a state
directory inside `$TMPDIR`. It creates a fresh private directory under
`${XDG_STATE_HOME:-$HOME/.local/state}/bzip2z-replays/`, runs `./test`, the
ReleaseSafe build and the sweep, and keeps their logs, the sweep report and
stderr. It succeeds only when:

- every stage exits 0, and the binary under test exists;
- the report is exactly one JSON object (two concatenated objects, an
  array or other root is rejected) and matches the declared domain in
  `tests/differential/sniper-domain.json` exactly: definition, classifier,
  trial count, and each corpus item's name, size, stride and sha256. The
  trial count must also equal the sum of ceil(bytes x 8 / stride) over the
  corpus, so the count is derived from the extents, not trusted;
- the reference binary exists and is executable;
- every pristine control is accepted by both decoders, and no crash,
  experiment error or unexplained disagreement is reported;
- all eight outcome counters are present and are nonnegative integers, and
  the passing outcomes (both accept, both reject, intentional divergence)
  sum exactly to the trial count;
- the source revision is unchanged and the tree clean after all steps.

It writes `status.json` with jq after every stage, atomically, with
per-stage statuses, the source, binary, reference, report and domain
identities, and a `complete` flag set only at the end. A run killed
mid-way therefore leaves its completed stages on record, marked incomplete.
It exits nonzero if any write of that receipt fails. `tests/differential/replay-runner-test`, run by `./test`,
checks each of these outcomes with injected fake steps in a throwaway
repository. That includes the six false successes an independent review
found in the first version: an unwritable receipt, a non-JSON report, a
wrong classifier or trial count, a missing binary, a quoted reference path
that broke hand-written JSON, and a build step that moved HEAD. Also covered:
an empty corpus, a failed pristine control, a nonzero failing-outcome count,
a missing reference, and termination during the build. A second independent
review then found four more false successes. One was a report whose
outcomes did not account for its trials. Another used a negative counter
balanced by an inflated one. A third had missing success counters. The
last held two JSON roots, a failing one first and a clean one last. Each
now has a control, alongside fractional, string, array-root and
missing-failure-counter cases and a whitespace-padded single-root
positive. Seven mutation checks were each caught by their control:
- an ignored test status
- an accepted zero-trial report
- a dropped classifier comparison
- a disabled source-stability check
- dropped per-stage receipt writes
- a dropped partition check
- a dropped counter-type check

#### Classifier versions

classifier/v1 (`cfd3b7c`):

- It treated every nonzero, non-signal exit as a rejection. Reference bzip2
  exits 1 for environmental trouble and 3 for an internal failure; neither is
  a detection. The v1 runs did not record which code produced each reference
  rejection, so the 7402 "both reject" count cannot distinguish them.
- It excused every bzip2z-reject/reference-accept flip inside the second
  stream's 32-bit header as trailing data, including flips that leave a legal
  header. Analysis of the logged positions shows this did not change the v1
  counts. 24 of the 32 header bits are in the `BZh` bytes, and every flip
  there breaks the magic. Of the 8 digit bits, 6 yield a non-digit and 2
  yield legal levels ('1', '8'). Those 2 were logged as both-accept (bits
  2220 and 2223), not excused. So all 30 excused flips were invalid headers.
- It passed a trial in which both decoders crashed. No crash occurred in any
  v1 run.

classifier/v2 applies per-binary exit contracts and counts any other exit as
an experiment error that fails the sweep. Reference: 0 accept, 2 reject. bzip2z
CLI: 0 accept, 1 reject; its exit 1 also covers I/O failures, a limitation
mitigated by per-item pristine controls run in the same environment. v2
excuses a flip only when the resulting later-stream header is invalid, and
fails on any crash. `tests/differential/classify-test` (run by `./test`)
checks v2 over every verdict pair, every single-bit flip of a `BZh9` header
and real process exit statuses.

## Residual blind class

Mutations both decoders accept, from the 29 both-accept trials:

- Level digit changed to another digit still large enough for every block
  (byte 3 of a stream).
- Padding bits after the last stream footer (0-7 bits, not covered by any CRC).
- The randomized-block flag in a block shorter than the first randomization
  offset (observed once, in the 300-byte second stream). Inferred explanation:
  derandomization changes no byte of such a block; not individually verified.
- Coding-table bits in a block header (12 of 29, all in the multi-block
  stream's two headers). Inferred explanation: they change only codes for
  symbols the block never uses, so decoding is identical; not individually
  verified.

Beyond single-bit damage: if corruption decodes without a structural error,
the block's CRC32 is the remaining check. Under a random-error model, where
the damage leaves the block's decoded bytes effectively uniformly random, a
damaged block passes its CRC32 with probability about 2^-32. That figure
assumes randomness. Damage in coded data maps nonlinearly onto decoded bytes,
so no burst-length guarantee carries over from coded to decoded data, and
CRC32 gives no protection against deliberate tampering, since anyone can
recompute a matching CRC.

## Intentional divergence

After a complete stream, the reference `bzip2 -t` exits 0 when the remaining
data does not start a valid stream (it warns and ignores it). bzip2z reports
it: 1-3 header bytes are `UnexpectedEof`, longer data `InvalidMagic`. Integrity
checkers need to see such data, so the divergence is deliberate and is pinned by
test "differential: trailing garbage is an intentional, documented divergence".

## Failed or rejected ideas

- 2026-09-29: treating `block_start_bit` as a reliable bound on where
  corruption lies. Falsified by an exhaustive single-bit test: a flip can
  decode as an early end-of-block and misframe what follows. Replaced by the
  `[window_start_bit, bit_offset)` window.
- 2026-09-29: starting that window at the end of the last CRC-verified block.
  Falsified by the same test: a CRC covers decoded bytes, not bit layout, so a
  verified block can still contain the flip. The window now starts at the
  last verified block's start.
- 2026-10-09: the reference-interop tests had reported "skipped" since the
  Zig 0.16 migration (failing-allocator `Io`, then a `readAlloc` semantics
  change). They now run, and a missing tool is a failure, not a skip.
- 2026-10-09: the first sniper run counted 30 disagreements as failures. All
  were the trailing-data divergence; the sweep now classifies only that case,
  in that direction and inside that header, as expected.
- 2026-10-09: single-bit mutation of encoder output found none of the three
  structural gaps; they needed several fields crafted together. Sniper sweeps
  alone are not evidence that structural checks are complete.
- Rejected: deriving the inventory from reference source code (provenance;
  see above).

## Limitations

- Randomized blocks are checked by two crafted cases (one single block each);
  no randomized multi-block or multi-stream input was crafted.
- Code-length sets that violate the Kraft inequality are accepted when tables
  are built, as in the reference; only an unassigned code in the data is
  rejected. Five table shapes over a four-symbol alphabet were crafted; larger
  alphabets and multiple distinct tables per block were not.
- Diagnostics (`decompressStream`) cover the sequential decoder; the parallel
  slice decoder reports errors without locations.
- The sniper sweep covers three small streams; it says nothing about shotgun
  (8-16 clustered bits) or nuke (dense overwrite) damage, which are queued.
