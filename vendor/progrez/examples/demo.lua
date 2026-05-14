#!/usr/bin/env luajit
-- progrez demo — exercises the C FFI from LuaJIT.
--
-- Usage:
--   luajit examples/demo.lua
--
-- The shared library must be built first:
--   nix develop -c zig build

local ffi = require("ffi")

ffi.cdef[[
typedef struct progrez_ctx progrez_ctx;

progrez_ctx *progrez_create(const char *label);
void progrez_destroy(progrez_ctx *ctx);
void progrez_set_identity(progrez_ctx *ctx, const char *caller_name, const char *context_name);
void progrez_set_indeterminate(progrez_ctx *ctx);
void progrez_set_determinate(progrez_ctx *ctx, uint64_t files_total, uint64_t bytes_total);
void progrez_set_guess(progrez_ctx *ctx, uint64_t guess_files, uint64_t guess_bytes);
void progrez_update(progrez_ctx *ctx, uint64_t files_processed, uint64_t bytes_processed);
void progrez_finish(progrez_ctx *ctx);
void progrez_set_interval_ms(progrez_ctx *ctx, uint32_t ms);
void progrez_set_gradient(progrez_ctx *ctx,
                          uint8_t start_r, uint8_t start_g, uint8_t start_b,
                          uint8_t mid_r,   uint8_t mid_g,   uint8_t mid_b,
                          uint8_t end_r,   uint8_t end_g,   uint8_t end_b);
void progrez_set_gradient_2(progrez_ctx *ctx,
                            uint8_t start_r, uint8_t start_g, uint8_t start_b,
                            uint8_t end_r,   uint8_t end_g,   uint8_t end_b);
void progrez_set_label(progrez_ctx *ctx, const char *label);
void progrez_set_sparkline(progrez_ctx *ctx, bool enabled);
void progrez_set_notify(progrez_ctx *ctx, bool enabled);
void progrez_set_notify_after(progrez_ctx *ctx, uint32_t seconds);

int usleep(unsigned int usec);
]]

-- Load the shared library from the build output directory
local script_dir = arg[0]:match("(.*/)")  or "./"
local lib_path = script_dir .. "../zig-out/lib/libprogrez.dylib"
local ok, progrez = pcall(ffi.load, lib_path)
if not ok then
    -- Try Linux path
    lib_path = script_dir .. "../zig-out/lib/libprogrez.so"
    ok, progrez = pcall(ffi.load, lib_path)
end
if not ok then
    io.stderr:write("Failed to load libprogrez. Build first: nix develop -c zig build\n")
    os.exit(1)
end

local function sleep_ms(ms)
    -- LuaJIT doesn't have a built-in sleep, use ffi
    ffi.C.usleep(ms * 1000)
end

-- Phase 1: Indeterminate (scanning)
local ctx = progrez.progrez_create("Scanning")
if ctx == nil then
    io.stderr:write("Failed to create progress context\n")
    os.exit(1)
end

progrez.progrez_set_identity(ctx, "luajit-demo", "demo file scan")
progrez.progrez_set_indeterminate(ctx)
progrez.progrez_set_sparkline(ctx, true)
progrez.progrez_set_notify(ctx, true)  -- enable notifications for demo

for i = 1, 70 do
    progrez.progrez_update(ctx, i, i * 150000)
    sleep_ms(75)
end

-- Update label before switching to determinate mode
progrez.progrez_set_label(ctx, "Processing")

-- Phase 2: Determinate (processing)
local total_files = 200
local total_bytes = total_files * 150000  -- ~30 MB
progrez.progrez_set_determinate(ctx, total_files, total_bytes)

for i = 1, total_files do
    progrez.progrez_update(ctx, i, i * 150000)
    -- Vary the sleep to produce interesting sparkline
    sleep_ms(30 + (i % 7) * 8)
end

progrez.progrez_finish(ctx)
progrez.progrez_destroy(ctx)
