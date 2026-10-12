#ifndef BZIP2Z_H
#define BZIP2Z_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum bzip2z_status {
	BZIP2Z_OK = 0,
	BZIP2Z_INVALID_ARGUMENT = 1,
	BZIP2Z_INVALID_DATA = 2,
	BZIP2Z_CRC_MISMATCH = 3,
	BZIP2Z_OUT_OF_MEMORY = 4,
	BZIP2Z_INTERNAL_ERROR = 5,
} bzip2z_status_t;

typedef struct bzip2z_buffer {
	uint8_t* ptr;
	size_t len;
} bzip2z_buffer_t;

typedef void (*bzip2z_progress_fn)(uint64_t bytes_processed, uint64_t bytes_total, void* userdata);

typedef struct bzip2z_compress_options {
	uint8_t level;
	size_t threads;
	uint8_t multi_stream;
	bzip2z_progress_fn on_progress;
	void* progress_userdata;
	uint64_t progress_bytes_total;
} bzip2z_compress_options_t;

/* Decode phase in which an error was detected (bzip2z_diagnostics_t.phase). */
typedef enum bzip2z_phase {
	BZIP2Z_PHASE_STREAM_HEADER = 0,
	BZIP2Z_PHASE_BLOCK_HEADER = 1,
	BZIP2Z_PHASE_SYMBOL_MAP = 2,
	BZIP2Z_PHASE_SELECTORS = 3,
	BZIP2Z_PHASE_HUFFMAN_TABLES = 4,
	BZIP2Z_PHASE_SYMBOL_DATA = 5,
	BZIP2Z_PHASE_BLOCK_RECONSTRUCT = 6,
	BZIP2Z_PHASE_BLOCK_CRC = 7,
	BZIP2Z_PHASE_STREAM_FOOTER = 8,
} bzip2z_phase_t;

/*
 * Failure report for bzip2z_decompress. When options->diagnostics is non-NULL
 * and check_crc is set, a BZIP2Z_INVALID_DATA or BZIP2Z_CRC_MISMATCH result
 * sets valid to 1 and fills the other fields; in every other case valid is 0
 * and the other fields are unspecified. The report comes from a sequential,
 * CRC-checked re-decode that runs only after a failure, so a successful
 * parallel decode keeps its speed.
 *
 * Bit offsets count from the start of the input buffer, most significant bit
 * first within each byte (byte = offset / 8; bit = offset % 8, where 0 is the
 * 0x80 bit). bit_offset is where the error was detected; the damage behind it
 * lies in [window_start_bit, bit_offset). block_start_bit is meaningful only
 * when has_block_start is 1, and stored_crc/computed_crc only when has_crc is
 * 1. streams and blocks count those fully verified before the error.
 */
typedef struct bzip2z_diagnostics {
	uint64_t bit_offset;
	uint64_t stream_start_bit;
	uint64_t block_start_bit;
	uint64_t window_start_bit;
	uint32_t phase;
	uint32_t stream_index;
	uint32_t block_index;
	uint32_t stored_crc;
	uint32_t computed_crc;
	uint32_t streams;
	uint32_t blocks;
	uint8_t valid;
	uint8_t has_block_start;
	uint8_t has_crc;
	uint8_t reserved;
} bzip2z_diagnostics_t;

typedef struct bzip2z_decompress_options {
	size_t threads;
	uint8_t parallel;
	uint8_t check_crc;
	bzip2z_progress_fn on_progress;
	void* progress_userdata;
	uint64_t progress_bytes_total;
	/* Optional failure report; NULL to skip. */
	bzip2z_diagnostics_t* diagnostics;
} bzip2z_decompress_options_t;

int bzip2z_compress(
	const uint8_t* input_ptr,
	size_t input_len,
	const bzip2z_compress_options_t* options,
	bzip2z_buffer_t* out_buffer
);

int bzip2z_decompress(
	const uint8_t* input_ptr,
	size_t input_len,
	const bzip2z_decompress_options_t* options,
	bzip2z_buffer_t* out_buffer
);

void bzip2z_free(uint8_t* ptr, size_t len);
const char* bzip2z_version_string(void);
size_t bzip2z_version_string_len(void);

/*
 * Name of a decode phase (for example "huffman_tables"), returned as a pointer
 * plus a byte length written to *out_len when out_len is non-NULL. The bytes
 * are static and also NUL-terminated. Returns NULL (length 0) for a value
 * that is not a phase.
 */
const char* bzip2z_phase_name(uint32_t phase, size_t* out_len);

#ifdef __cplusplus
}
#endif

#endif
