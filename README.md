# bzip2z

Clean-room, pure Zig reimplementation of bzip2 with a focus on correctness, clarity, and performance. Designed as a library dependency and a drop-in CLI replacement.

## Highlights

- Pure Zig bzip2 encoder/decoder with SA-IS suffix array construction for BWT.
- Multi-block streaming support for large inputs.
- Optional concurrent block compression (`-j N` / `CompressOptions.threads`).
- Optional pbzip2-style multi-stream compression and parallel decompression (opt-in).
- Concatenated stream decoding supported.
- Legacy randomized-block decoding uses the canonical 512-entry compatibility sequence to preserve interoperable CRC validation.
- CLI-compatible with bzip2 flags, plus `--about`.

## Algorithmic improvements

This implementation replaces the original block-sorting logic with a clean, efficient SA-IS suffix array construction for the Burrows–Wheeler Transform. SA-IS provides linear-time suffix array construction in practice, which reduces time spent in block sorting and improves throughput on large and repetitive inputs.

## Multi-stream + parallel decode (pbzip2-style)

`bzip2z` can emit concatenated streams (one per block) and decode them in parallel. This mirrors pbzip2 behavior and stays compatible with standard bzip2 tooling:

- Compression: opt in via `-j N` (CLI) or `CompressOptions.multi_stream = true` (library).
- Decompression: opt in via `-j N` (CLI file inputs) or `DecompressOptions.parallel = true` (library).
- Default behavior remains standard single-stream bzip2 for maximum compatibility and streaming support.

For file inputs with `-j`, the CLI streams output in order while decoding streams in parallel (no full-file slurp).

## Benchmarks

A benchmark tool is included to compare Zig bzip2 vs system bzip2:

```
./build -Doptimize=ReleaseFast bench
./zig-out/bin/bench-bzip2 --size 1M --pattern mixed --iterations 3 --threads 1
```

If `pbzip2` is available, the benchmark also reports pbzip2 vs system bzip2 using the resolved thread count.

Environment:

- Run date: 2026-01-15
- Host: Darwin 25.3.0 (arm64)
- CPU: Apple M4 Max
- Zig: 0.15.2
- System bzip2: 1.0.8 (via Nix dev shell)
- pbzip2: 1.1.13 (via Nix dev shell)
- Optimize: ReleaseFast

Results (mixed data, 3 iterations):

1) Size 1.0 MB, threads = 1

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       18.64           10.43        1.79x
Decompress (MB/s):     67.14           69.38        0.97x
Compressed size:      265768          265931        1.00x
Compression ratio:      3.95x           3.94x
Peak memory (Zig):  4.3 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):       10.31           10.43        0.99x
Decompress (MB/s):     56.93           69.38        0.82x
Compressed size:      266013          265931        1.00x
Compression ratio:      3.94x           3.94x
```

2) Size 1.0 MB, threads = auto (resolved 16)

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       27.18           10.33        2.63x
Decompress (MB/s):     68.65           69.16        0.99x
Compressed size:      265768          265931        1.00x
Compression ratio:      3.95x           3.94x
Peak memory (Zig):  4.3 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):       11.33           10.33        1.10x
Decompress (MB/s):     56.47           69.16        0.82x
Compressed size:      266013          265931        1.00x
Compression ratio:      3.94x           3.94x
```

3) Size 8.0 MB, threads = 1

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       19.09           11.00        1.74x
Decompress (MB/s):     69.59           86.09        0.81x
Compressed size:     2108528         2111379        1.00x
Compression ratio:      3.98x           3.97x
Peak memory (Zig):  20.0 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):       11.06           11.00        1.01x
Decompress (MB/s):    219.44           86.09        2.55x
Compressed size:     2111886         2111379        1.00x
Compression ratio:      3.97x           3.97x
```

4) Size 8.0 MB, threads = auto (resolved 16)

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       58.11           10.96        5.30x
Decompress (MB/s):     66.96           85.98        0.78x
Compressed size:     2108528         2111379        1.00x
Compression ratio:      3.98x           3.97x
Peak memory (Zig):  20.0 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):       71.04           10.96        6.48x
Decompress (MB/s):    210.00           85.98        2.44x
Compressed size:     2111886         2111379        1.00x
Compression ratio:      3.97x           3.97x
```

5) Size 16.0 MB, threads = 1

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       18.82           10.92        1.72x
Decompress (MB/s):     68.10           84.63        0.80x
Compressed size:     4214561         4220876        1.00x
Compression ratio:      3.98x           3.97x
Peak memory (Zig):  38.0 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):       10.97           10.92        1.00x
Decompress (MB/s):    367.62           84.63        4.34x
Compressed size:     4222194         4220876        1.00x
Compression ratio:      3.97x           3.97x
```

6) Size 16.0 MB, threads = auto (resolved 16)

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       94.26           11.06        8.52x
Decompress (MB/s):     69.05           89.89        0.77x
Compressed size:     4214561         4220876        1.00x
Compression ratio:      3.98x           3.97x
Peak memory (Zig):  38.0 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):      105.40           11.06        9.53x
Decompress (MB/s):    381.62           89.89        4.25x
Compressed size:     4222194         4220876        1.00x
Compression ratio:      3.97x           3.97x
```

7) Size 32.0 MB, threads = 1

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       19.35           10.97        1.76x
Decompress (MB/s):     69.67           90.19        0.77x
Compressed size:     8427960         8440715        1.00x
Compression ratio:      3.98x           3.98x
Peak memory (Zig):  74.0 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):       11.07           10.97        1.01x
Decompress (MB/s):    604.28           90.19        6.70x
Compressed size:     8440614         8440715        1.00x
Compression ratio:      3.98x           3.98x
```

8) Size 32.0 MB, threads = auto (resolved 16)

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):      135.51           10.95        12.37x
Decompress (MB/s):     69.52           89.15        0.78x
Compressed size:     8427960         8440715        1.00x
Compression ratio:      3.98x           3.98x
Peak memory (Zig):  74.0 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):      110.60           10.95        10.10x
Decompress (MB/s):    607.33           89.15        6.81x
Compressed size:     8440614         8440715        1.00x
Compression ratio:      3.98x           3.98x
```

9) Size 64.0 MB, threads = 1

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       19.29           10.85        1.78x
Decompress (MB/s):     69.60           84.78        0.82x
Compressed size:    16853446        16878475        1.00x
Compression ratio:      3.98x           3.98x
Peak memory (Zig):  146.1 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):       10.95           10.85        1.01x
Decompress (MB/s):    741.50           84.78        8.75x
Compressed size:    16879540        16878475        1.00x
Compression ratio:      3.98x           3.98x
```

10) Size 64.0 MB, threads = auto (resolved 16)

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):      150.43           10.80        13.93x
Decompress (MB/s):     67.12           88.47        0.76x
Compressed size:    16853446        16878475        1.00x
Compression ratio:      3.98x           3.98x
Peak memory (Zig):  146.1 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):      109.48           10.80        10.13x
Decompress (MB/s):    766.04           88.47        8.66x
Compressed size:    16879540        16878475        1.00x
Compression ratio:      3.98x           3.98x
```

11) Size 128.0 MB, threads = 1

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):       18.94           10.77        1.76x
Decompress (MB/s):     67.44           87.61        0.77x
Compressed size:    33705032        33749976        1.00x
Compression ratio:      3.98x           3.98x
Peak memory (Zig):  290.1 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):       10.89           10.77        1.01x
Decompress (MB/s):    837.30           87.61        9.56x
Compressed size:    33757754        33749976        1.00x
Compression ratio:      3.98x           3.98x
```

12) Size 128.0 MB, threads = auto (resolved 16)

```
                    Zig bzip2       System bzip2    Ratio
                    ---------       ------------    -----
Compress (MB/s):      162.74           10.77        15.10x
Decompress (MB/s):     66.75           88.23        0.76x
Compressed size:    33705032        33749976        1.00x
Compression ratio:      3.98x           3.98x
Peak memory (Zig):  290.1 MB
```

```
                    pbzip2          System bzip2    Ratio
                    ------          ------------    -----
Compress (MB/s):      115.61           10.77        10.73x
Decompress (MB/s):    845.55           88.23        9.58x
Compressed size:    33757754        33749976        1.00x
Compression ratio:      3.98x           3.98x
```

The benchmark uses the system `bzip2` binary (provided in the Nix dev shell) for comparison. Run in a controlled environment and record results in your benchmark log.

## Credits

- Original bzip2 algorithm and format: Julian R Seward <jseward@bzip.org>
- This clean-room Zig reimplementation: Peter Marreck

## Library usage

```zig
const std = @import("std");
const bzip2 = @import("bzip2z").bzip2;

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const input = "hello world";
	const compressed = try bzip2.compressWithOptions(allocator, input, .{
		.level = 9,
		.threads = 4,
		.multi_stream = true,
	});
	defer allocator.free(compressed);

	const decompressed = try bzip2.decompressWithOptions(allocator, compressed, .{
		.threads = 4,
		.parallel = true,
	});
	defer allocator.free(decompressed);
}
```

## CLI usage

```
./build
./zig-out/bin/bzip2 -k file.txt
./zig-out/bin/bzip2 -j 8 -k file.txt
./zig-out/bin/bunzip2 file.txt.bz2
./zig-out/bin/bzcat file.txt.bz2
./zig-out/bin/bzip2 --about
```

`-j N` opts into pbzip2-style concatenated streams for compression and enables parallel decompression for file inputs.

## Tests

Run all tests:

```
./test
```

## Development

Use the dev shell for consistent toolchain and bzip2 dependency:

```
nix develop -c bash
```
