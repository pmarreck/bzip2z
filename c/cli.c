#include "bzip2z.h"
#ifdef HAVE_PROGREZ
#include "progrez.h"
#endif

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <unistd.h>
#endif

typedef enum cli_mode {
	MODE_COMPRESS,
	MODE_DECOMPRESS,
	MODE_TEST,
} cli_mode_t;

typedef struct cli_options {
	cli_mode_t mode;
	int stdout_mode;
	int keep;
	int force;
	int quiet;
	unsigned verbose;
	uint8_t level;
	size_t threads;
	int pbzip2;
	int about;
	int show_version;
	int show_license;
	uint64_t stdin_size;
} cli_options_t;

typedef struct file_list {
	char** items;
	size_t len;
	size_t cap;
} file_list_t;

static void file_list_init(file_list_t* files) {
	files->items = NULL;
	files->len = 0;
	files->cap = 0;
}

static void file_list_deinit(file_list_t* files) {
	free(files->items);
	files->items = NULL;
	files->len = 0;
	files->cap = 0;
}

static int file_list_append(file_list_t* files, char* item) {
	if (files->len == files->cap) {
		size_t next_cap = files->cap == 0 ? 8 : files->cap * 2;
		char** next = (char**)realloc(files->items, next_cap * sizeof(char*));
		if (next == NULL) {
			return 0;
		}
		files->items = next;
		files->cap = next_cap;
	}
	files->items[files->len++] = item;
	return 1;
}

static const char* base_name(const char* path) {
	const char* slash = strrchr(path, '/');
#ifdef _WIN32
	const char* backslash = strrchr(path, '\\');
	if (backslash != NULL && (slash == NULL || backslash > slash)) {
		slash = backslash;
	}
#endif
	return slash == NULL ? path : slash + 1;
}

static cli_mode_t default_mode_from_program(const char* program) {
	const char* base = base_name(program);
	if (strcmp(base, "bunzip2z") == 0 || strcmp(base, "bunzip2z.exe") == 0) {
		return MODE_DECOMPRESS;
	}
	if (strcmp(base, "bzcatz") == 0 || strcmp(base, "bzcatz.exe") == 0) {
		return MODE_DECOMPRESS;
	}
	return MODE_COMPRESS;
}

static int default_stdout_from_program(const char* program) {
	const char* base = base_name(program);
	return strcmp(base, "bzcatz") == 0 || strcmp(base, "bzcatz.exe") == 0;
}

static void usage(const char* program) {
	printf(
		"bzip2z - C CLI adapter using bzip2z FFI\n"
		"\n"
		"usage: %s [options] [files...]\n"
		"\n"
		" -h, --help          show this help\n"
		" -d, --decompress    decompress input\n"
		" -z, --compress      compress input\n"
		" -k, --keep          keep source files\n"
		" -f, --force         overwrite output paths\n"
		" -t, --test          verify archive integrity only\n"
		" -c, --stdout        write payload bytes to stdout\n"
		" -q, --quiet         suppress non-fatal diagnostics\n"
		" -v, --verbose       increase logging (repeat for more detail)\n"
		" -L, --license       print version and license notice\n"
		" -V, --version       print version and license notice\n"
		" -s, --small         reduced-memory mode (max 2500k)\n"
		" -1 .. -9            block size from 100k to 900k\n"
		" --fast              same as -1\n"
		" --best              same as -9\n"
		" -j N                pbzip2-style multi-stream compression and parallel decode using N threads\n"
		" --size N            hint for stdin input size (enables determinate progress)\n"
		" --about             show implementation summary\n"
		"\n"
		"Default mode depends on executable name:\n"
		" bzip2z   => compress\n"
		" bunzip2z => decompress\n"
		" bzcatz   => decompress to stdout\n"
		"\n"
		"With no files, input is read from stdin.\n"
		"Short options can be combined (example: -v4).\n"
		"\n"
		"Environment: BZIP2Z_SIZE=N sets stdin size hint, PROGRESS=false disables progress.\n",
		program
	);
}

static void version_info(void) {
	const char* version_ptr = bzip2z_version_string();
	size_t version_len = bzip2z_version_string_len();
	printf(
		"bzip2z %.*s\n"
		"C CLI adapter via stable bzip2z FFI\n"
		"Original bzip2: Julian R Seward <jseward@bzip.org>\n"
		"This reimplementation: Peter Marreck\n",
		(int)version_len,
		version_ptr
	);
}

static void license_info(void) {
	version_info();
	printf(
		"\n"
		"Original bzip2 license:\n"
		" bzip2/libbzip2 version 1.0.6 of 6 September 2010\n"
		" Copyright (C) 1996-2010 Julian R Seward <jseward@bzip.org>\n"
		" Redistribution and use in source and binary forms, with or without\n"
		" modification, are permitted provided that the following conditions are met:\n"
		" 1. Redistributions of source code must retain the above copyright notice.\n"
		" 2. The origin of this software must not be misrepresented; you must not\n"
		"    claim that you wrote the original software.\n"
		" 3. Altered source versions must be plainly marked as such.\n"
		" 4. The name of the author may not be used to endorse or promote products\n"
		"    derived from this software without specific prior written permission.\n"
	);
}

static const char* status_name(int status) {
	switch (status) {
		case BZIP2Z_OK:
			return "OK";
		case BZIP2Z_INVALID_ARGUMENT:
			return "INVALID_ARGUMENT";
		case BZIP2Z_INVALID_DATA:
			return "INVALID_DATA";
		case BZIP2Z_CRC_MISMATCH:
			return "CRC_MISMATCH";
		case BZIP2Z_OUT_OF_MEMORY:
			return "OUT_OF_MEMORY";
		case BZIP2Z_INTERNAL_ERROR:
		default:
			return "INTERNAL_ERROR";
	}
}

static int parse_size(const char* text, size_t* value_out) {
	char* end = NULL;
	unsigned long long parsed = strtoull(text, &end, 10);
	if (end == text || *end != '\0') {
		return 0;
	}
	*value_out = (size_t)parsed;
	return 1;
}

#ifdef HAVE_PROGREZ
static void progress_callback(uint64_t bytes_done, uint64_t bytes_total, void* userdata) {
	progrez_ctx* ctx = (progrez_ctx*)userdata;
	(void)bytes_total;
	progrez_update(ctx, 0, bytes_done);
}

static progrez_ctx* progress_start(const char* label, const char* path,
                                   uint64_t bytes_total, const cli_options_t* opts) {
	if (opts->quiet) return NULL;
#ifdef _WIN32
	if (!_isatty(_fileno(stderr))) return NULL;
#else
	if (!isatty(STDERR_FILENO)) return NULL;
#endif

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
#else
/* No-op stubs when progrez is not available */
typedef void progrez_ctx;
static void progress_callback(uint64_t bytes_done, uint64_t bytes_total, void* userdata) {
	(void)bytes_done; (void)bytes_total; (void)userdata;
}
static progrez_ctx* progress_start(const char* label, const char* path,
                                   uint64_t bytes_total, const cli_options_t* opts) {
	(void)label; (void)path; (void)bytes_total; (void)opts;
	return NULL;
}
static void progress_end(progrez_ctx* ctx) { (void)ctx; }
#endif

static int parse_args(int argc, char** argv, cli_options_t* opts, file_list_t* files) {
	int i;
	for (i = 1; i < argc; i++) {
		const char* arg = argv[i];
		if (arg[0] == '\0') {
			continue;
		}

		if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
			return 1;
		}
		if (strcmp(arg, "--about") == 0 || strcmp(arg, "-a") == 0) {
			opts->about = 1;
			continue;
		}
		if (strcmp(arg, "--version") == 0 || strcmp(arg, "-V") == 0) {
			opts->show_version = 1;
			continue;
		}
		if (strcmp(arg, "--license") == 0 || strcmp(arg, "-L") == 0) {
			opts->show_license = 1;
			continue;
		}
		if (strcmp(arg, "--decompress") == 0 || strcmp(arg, "-d") == 0) {
			opts->mode = MODE_DECOMPRESS;
			continue;
		}
		if (strcmp(arg, "--compress") == 0 || strcmp(arg, "-z") == 0) {
			opts->mode = MODE_COMPRESS;
			continue;
		}
		if (strcmp(arg, "--test") == 0 || strcmp(arg, "-t") == 0) {
			opts->mode = MODE_TEST;
			continue;
		}
		if (strcmp(arg, "--keep") == 0 || strcmp(arg, "-k") == 0) {
			opts->keep = 1;
			continue;
		}
		if (strcmp(arg, "--force") == 0 || strcmp(arg, "-f") == 0) {
			opts->force = 1;
			continue;
		}
		if (strcmp(arg, "--stdout") == 0 || strcmp(arg, "-c") == 0) {
			opts->stdout_mode = 1;
			continue;
		}
		if (strcmp(arg, "--quiet") == 0 || strcmp(arg, "-q") == 0) {
			opts->quiet = 1;
			continue;
		}
		if (strcmp(arg, "--small") == 0 || strcmp(arg, "-s") == 0) {
			continue;
		}
		if (strcmp(arg, "--fast") == 0) {
			opts->level = 1;
			continue;
		}
		if (strcmp(arg, "--best") == 0) {
			opts->level = 9;
			continue;
		}
		if (strcmp(arg, "--size") == 0) {
			if (i + 1 >= argc) return -1;
			size_t val;
			if (!parse_size(argv[i + 1], &val)) return -1;
			opts->stdin_size = (uint64_t)val;
			i++;
			continue;
		}
		if (strcmp(arg, "-j") == 0) {
			if (i + 1 >= argc || !parse_size(argv[i + 1], &opts->threads)) {
				return -1;
			}
			opts->pbzip2 = 1;
			i++;
			continue;
		}

		if (arg[0] == '-' && arg[1] != '\0' && arg[1] != '-') {
			size_t j;
			for (j = 1; arg[j] != '\0'; j++) {
				char flag = arg[j];
				if (flag >= '1' && flag <= '9') {
					opts->level = (uint8_t)(flag - '0');
					continue;
				}
				switch (flag) {
					case 'd':
						opts->mode = MODE_DECOMPRESS;
						break;
					case 'z':
						opts->mode = MODE_COMPRESS;
						break;
					case 't':
						opts->mode = MODE_TEST;
						break;
					case 'k':
						opts->keep = 1;
						break;
					case 'f':
						opts->force = 1;
						break;
					case 'c':
						opts->stdout_mode = 1;
						break;
					case 'q':
						opts->quiet = 1;
						break;
					case 'v':
						opts->verbose++;
						break;
					case 's':
						break;
					case 'L':
						opts->show_license = 1;
						break;
					case 'V':
						opts->show_version = 1;
						break;
					case 'j': {
						const char* rest = &arg[j + 1];
						if (*rest != '\0') {
							if (!parse_size(rest, &opts->threads)) {
								return -1;
							}
							opts->pbzip2 = 1;
							j = strlen(arg) - 1;
						} else {
							if (i + 1 >= argc || !parse_size(argv[i + 1], &opts->threads)) {
								return -1;
							}
							opts->pbzip2 = 1;
							i++;
						}
						break;
					}
					default:
						return -1;
				}
			}
			continue;
		}

		if (!file_list_append(files, argv[i])) {
			return -1;
		}
	}

	return 0;
}

static int file_exists(const char* path) {
	FILE* f = fopen(path, "rb");
	if (f == NULL) {
		return 0;
	}
	fclose(f);
	return 1;
}

static int has_bz2_suffix(const char* path) {
	size_t len = strlen(path);
	if (len < 4) {
		return 0;
	}
	return strcmp(path + len - 4, ".bz2") == 0;
}

static char* output_path(const char* input, cli_mode_t mode) {
	size_t len = strlen(input);
	char* out;
	if (mode == MODE_COMPRESS) {
		out = (char*)malloc(len + 5);
		if (out == NULL) {
			return NULL;
		}
		memcpy(out, input, len);
		memcpy(out + len, ".bz2", 5);
		return out;
	}
	if (!has_bz2_suffix(input)) {
		return NULL;
	}
	out = (char*)malloc(len - 3);
	if (out == NULL) {
		return NULL;
	}
	memcpy(out, input, len - 4);
	out[len - 4] = '\0';
	return out;
}

static int read_stream(FILE* input, uint8_t** out_data, size_t* out_len) {
	size_t cap = 65536;
	size_t len = 0;
	uint8_t* data = (uint8_t*)malloc(cap);
	if (data == NULL) {
		return 0;
	}

	while (1) {
		size_t n;
		if (len == cap) {
			size_t next_cap = cap * 2;
			uint8_t* next = (uint8_t*)realloc(data, next_cap);
			if (next == NULL) {
				free(data);
				return 0;
			}
			data = next;
			cap = next_cap;
		}
		n = fread(data + len, 1, cap - len, input);
		len += n;
		if (n == 0) {
			if (ferror(input)) {
				free(data);
				return 0;
			}
			break;
		}
	}

	*out_data = data;
	*out_len = len;
	return 1;
}

static int read_file(const char* path, uint8_t** out_data, size_t* out_len) {
	FILE* file = fopen(path, "rb");
	int ok;
	if (file == NULL) {
		return 0;
	}
	ok = read_stream(file, out_data, out_len);
	fclose(file);
	return ok;
}

static int write_stream(FILE* output, const uint8_t* data, size_t len) {
	if (len == 0) {
		return 1;
	}
	return fwrite(data, 1, len, output) == len;
}

static int write_file(const char* path, const uint8_t* data, size_t len) {
	FILE* file = fopen(path, "wb");
	int ok;
	if (file == NULL) {
		return 0;
	}
	ok = write_stream(file, data, len);
	fclose(file);
	return ok;
}

static int run_compress_bytes(
	const uint8_t* input,
	size_t input_len,
	const cli_options_t* opts,
	bzip2z_buffer_t* output
) {
	bzip2z_compress_options_t copt = {0};
	copt.level = opts->level;
	copt.threads = opts->threads;
	copt.multi_stream = opts->pbzip2 ? 1 : 0;
	return bzip2z_compress(input, input_len, &copt, output);
}

static int run_decompress_bytes(
	const uint8_t* input,
	size_t input_len,
	const cli_options_t* opts,
	int check_crc,
	bzip2z_buffer_t* output
) {
	bzip2z_decompress_options_t dopt = {0};
	dopt.threads = opts->threads;
	dopt.parallel = (opts->pbzip2 && opts->threads > 1) ? 1 : 0;
	dopt.check_crc = check_crc ? 1 : 0;
	return bzip2z_decompress(input, input_len, &dopt, output);
}

static int compress_file(const char* path, const cli_options_t* opts) {
	uint8_t* input = NULL;
	size_t input_len = 0;
	bzip2z_buffer_t out = {0};
	char* out_path = NULL;
	int status;

	if (!read_file(path, &input, &input_len)) {
		return -1;
	}

	progrez_ctx* pctx = progress_start("Compressing", path, (uint64_t)input_len, opts);

	bzip2z_compress_options_t copt = {0};
	copt.level = opts->level;
	copt.threads = opts->threads;
	copt.multi_stream = opts->pbzip2 ? 1 : 0;
	copt.on_progress = pctx ? progress_callback : NULL;
	copt.progress_userdata = pctx;
	copt.progress_bytes_total = (uint64_t)input_len;
	status = bzip2z_compress(input, input_len, &copt, &out);

	free(input);
	progress_end(pctx);

	if (status != BZIP2Z_OK) {
		return status;
	}

	if (opts->stdout_mode) {
		if (!write_stream(stdout, out.ptr, out.len)) {
			bzip2z_free(out.ptr, out.len);
			return -1;
		}
		bzip2z_free(out.ptr, out.len);
		return 0;
	}

	out_path = output_path(path, MODE_COMPRESS);
	if (out_path == NULL) {
		bzip2z_free(out.ptr, out.len);
		return -1;
	}

	if (!opts->force && file_exists(out_path)) {
		free(out_path);
		bzip2z_free(out.ptr, out.len);
		return -2;
	}

	if (!write_file(out_path, out.ptr, out.len)) {
		free(out_path);
		bzip2z_free(out.ptr, out.len);
		return -1;
	}

	if (!opts->keep) {
		remove(path);
	}

	free(out_path);
	bzip2z_free(out.ptr, out.len);
	return 0;
}

static int decompress_file(const char* path, const cli_options_t* opts) {
	uint8_t* input = NULL;
	size_t input_len = 0;
	bzip2z_buffer_t out = {0};
	char* out_path = NULL;
	int status;

	if (!read_file(path, &input, &input_len)) {
		return -1;
	}

	progrez_ctx* pctx = progress_start("Decompressing", path, (uint64_t)input_len, opts);

	bzip2z_decompress_options_t dopt = {0};
	dopt.threads = opts->threads;
	dopt.parallel = (opts->pbzip2 && opts->threads > 1) ? 1 : 0;
	dopt.check_crc = 1;
	dopt.on_progress = pctx ? progress_callback : NULL;
	dopt.progress_userdata = pctx;
	dopt.progress_bytes_total = (uint64_t)input_len;
	status = bzip2z_decompress(input, input_len, &dopt, &out);

	free(input);
	progress_end(pctx);

	if (status != BZIP2Z_OK) {
		return status;
	}

	if (opts->stdout_mode) {
		if (!write_stream(stdout, out.ptr, out.len)) {
			bzip2z_free(out.ptr, out.len);
			return -1;
		}
		bzip2z_free(out.ptr, out.len);
		return 0;
	}

	out_path = output_path(path, MODE_DECOMPRESS);
	if (out_path == NULL) {
		bzip2z_free(out.ptr, out.len);
		return -1;
	}

	if (!opts->force && file_exists(out_path)) {
		free(out_path);
		bzip2z_free(out.ptr, out.len);
		return -2;
	}

	if (!write_file(out_path, out.ptr, out.len)) {
		free(out_path);
		bzip2z_free(out.ptr, out.len);
		return -1;
	}

	if (!opts->keep) {
		remove(path);
	}

	free(out_path);
	bzip2z_free(out.ptr, out.len);
	return 0;
}

static int test_file(const char* path, const cli_options_t* opts) {
	uint8_t* input = NULL;
	size_t input_len = 0;
	bzip2z_buffer_t out = {0};
	int status;

	if (!read_file(path, &input, &input_len)) {
		return -1;
	}

	progrez_ctx* pctx = progress_start("Testing", path, (uint64_t)input_len, opts);

	bzip2z_decompress_options_t dopt = {0};
	dopt.threads = opts->threads;
	dopt.parallel = (opts->pbzip2 && opts->threads > 1) ? 1 : 0;
	dopt.check_crc = 1;
	dopt.on_progress = pctx ? progress_callback : NULL;
	dopt.progress_userdata = pctx;
	dopt.progress_bytes_total = (uint64_t)input_len;
	status = bzip2z_decompress(input, input_len, &dopt, &out);

	free(input);
	progress_end(pctx);

	if (status != BZIP2Z_OK) {
		return status;
	}

	bzip2z_free(out.ptr, out.len);
	return 0;
}

static int process_stdin(const cli_options_t* opts) {
	uint8_t* input = NULL;
	size_t input_len = 0;
	bzip2z_buffer_t out = {0};
	int status;

	if (!read_stream(stdin, &input, &input_len)) {
		return 1;
	}

	progrez_ctx* pctx = progress_start(
		opts->mode == MODE_COMPRESS ? "Compressing" :
		opts->mode == MODE_TEST ? "Testing" : "Decompressing",
		NULL,
		opts->stdin_size > 0 ? opts->stdin_size : (uint64_t)input_len,
		opts
	);

	if (opts->mode == MODE_COMPRESS) {
		bzip2z_compress_options_t copt = {0};
		copt.level = opts->level;
		copt.threads = opts->threads;
		copt.multi_stream = opts->pbzip2 ? 1 : 0;
		copt.on_progress = pctx ? progress_callback : NULL;
		copt.progress_userdata = pctx;
		copt.progress_bytes_total = opts->stdin_size > 0 ? opts->stdin_size : (uint64_t)input_len;
		status = bzip2z_compress(input, input_len, &copt, &out);
	} else {
		bzip2z_decompress_options_t dopt = {0};
		dopt.threads = opts->threads;
		dopt.parallel = (opts->pbzip2 && opts->threads > 1) ? 1 : 0;
		dopt.check_crc = 1;
		dopt.on_progress = pctx ? progress_callback : NULL;
		dopt.progress_userdata = pctx;
		dopt.progress_bytes_total = opts->stdin_size > 0 ? opts->stdin_size : (uint64_t)input_len;
		status = bzip2z_decompress(input, input_len, &dopt, &out);
	}
	free(input);
	progress_end(pctx);

	if (status != BZIP2Z_OK) {
		if (!opts->quiet) {
			fprintf(stderr, "bzip2z: %s\n", status_name(status));
		}
		return 1;
	}

	if (opts->mode != MODE_TEST) {
		if (!write_stream(stdout, out.ptr, out.len)) {
			bzip2z_free(out.ptr, out.len);
			return 1;
		}
	}
	bzip2z_free(out.ptr, out.len);
	return 0;
}

int main(int argc, char** argv) {
	cli_options_t opts;
	file_list_t files;
	int parse_result;
	size_t idx;
	int exit_code = 0;

#ifdef _WIN32
	_setmode(_fileno(stdin), _O_BINARY);
	_setmode(_fileno(stdout), _O_BINARY);
#endif

	opts.mode = default_mode_from_program(argv[0]);
	opts.stdout_mode = default_stdout_from_program(argv[0]);
	opts.keep = 0;
	opts.force = 0;
	opts.quiet = 0;
	opts.verbose = 0;
	opts.level = 9;
	opts.threads = 0;
	opts.pbzip2 = 0;
	opts.about = 0;
	opts.show_version = 0;
	opts.show_license = 0;
	opts.stdin_size = 0;

	file_list_init(&files);
	parse_result = parse_args(argc, argv, &opts, &files);
	if (parse_result == 1) {
		usage(argv[0]);
		file_list_deinit(&files);
		return 0;
	}
	if (parse_result != 0) {
		fprintf(stderr, "bzip2z: invalid arguments\n");
		usage(argv[0]);
		file_list_deinit(&files);
		return 2;
	}

	if (opts.about) {
		version_info();
		file_list_deinit(&files);
		return 0;
	}
	if (opts.show_version) {
		version_info();
		file_list_deinit(&files);
		return 0;
	}
	if (opts.show_license) {
		license_info();
		file_list_deinit(&files);
		return 0;
	}

	if (opts.stdin_size == 0) {
		const char* env_size = getenv("BZIP2Z_SIZE");
		if (env_size != NULL) {
			size_t val;
			if (parse_size(env_size, &val)) {
				opts.stdin_size = (uint64_t)val;
			}
		}
	}

	if (files.len == 0) {
		exit_code = process_stdin(&opts);
		file_list_deinit(&files);
		return exit_code;
	}

	for (idx = 0; idx < files.len; idx++) {
		const char* path = files.items[idx];
		int rc;
		switch (opts.mode) {
			case MODE_COMPRESS:
				rc = compress_file(path, &opts);
				break;
			case MODE_DECOMPRESS:
				rc = decompress_file(path, &opts);
				break;
			case MODE_TEST:
			default:
				rc = test_file(path, &opts);
				break;
		}

		if (rc == 0) {
			if (opts.verbose > 0) {
				printf("%s: ok\n", path);
			}
			continue;
		}

		exit_code = 1;
		if (!opts.quiet) {
			if (rc == -2) {
				fprintf(stderr, "%s: OutputExists\n", path);
			} else if (rc < 0) {
				fprintf(stderr, "%s: %s\n", path, strerror(errno));
			} else {
				fprintf(stderr, "%s: %s\n", path, status_name(rc));
			}
		}
	}

	file_list_deinit(&files);
	return exit_code;
}
