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

typedef struct bzip2z_compress_options {
	uint8_t level;
	size_t threads;
	uint8_t multi_stream;
} bzip2z_compress_options_t;

typedef struct bzip2z_decompress_options {
	size_t threads;
	uint8_t parallel;
	uint8_t check_crc;
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

#ifdef __cplusplus
}
#endif

#endif
