-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
    ZX Spectrum Screen Renderer

    This module renders ZX Spectrum screen memory (6912 bytes in SCR format)
    to a term.gfx canvas for display via Kitty graphics protocol.

    Based on the existing zxscr module but optimized for emulator use
    with support for scaling and incremental updates.

    Screen format:
    - Bitmap: 6144 bytes (256x192 pixels, 1 bit per pixel)
    - Attributes: 768 bytes (32x24 character cells, 8x8 pixels each)

    The bitmap layout is notoriously non-linear:
    - Screen divided into 3 thirds (64 lines each)
    - Within each third, lines are interleaved
]]

local M = {}

local std = require("std")
local bit = require("bit")
local sbuf = require("string.buffer")
local gfx = require("term.gfx")

local SYNC_START = "\027[?2026h"
local SYNC_END = "\027[?2026l"

local function build_shm_or_data(shm_name, data, tx_opts)
	-- shm_open/mmap has noticeable fixed overhead; for small payloads it's
	-- typically faster to send inline.
	if #data < 32768 then
		return gfx.build_data(data, tx_opts)
	end

	local _, err = std.create_shm(shm_name, data)
	if not err then
		local shm_opts = {}
		for k, v in pairs(tx_opts) do
			shm_opts[k] = v
		end
		shm_opts.t = "s"
		shm_opts.S = #data
		return gfx.build_shm(shm_name, shm_opts)
	end
	return gfx.build_data(data, tx_opts)
end

-- Animation-backed double buffering:
-- - Create a single placement once.
-- - Upload new frames into frame 2/3 (edit in place) using a=f,r=<frame>.
-- - Switch current frame with a=a,c=<frame>.
-- This avoids per-frame placements and avoids re-transmitting base image ids.
local anim_show_frame

anim_show_frame = function(out, image_id, frame_no)
	out:put(gfx.build_cmd({ a = "a", i = image_id, c = frame_no, q = 2 }))
end

local function anim_init(out, image_id, shm_name_a, shm_name_b, data, opts, row, col, offset_x, offset_y)
	-- Start clean
	out:put(gfx.build_cmd({ a = "d", d = "I", i = image_id, q = 2 }))

	-- Position the cursor for the placement
	if row and col then
		out:put("\027[", tostring(row), ";", tostring(col), "H")
	end

	-- Root frame (base image)
	out:put(build_shm_or_data(shm_name_a, data, { a = "t", i = image_id, f = opts.f, s = opts.s, v = opts.v, q = 2 }))

	-- Create placement once (stable p=1)
	local display_opts = { a = "p", i = image_id, p = 1, C = 1, q = 2 }
	if offset_x and offset_y then
		display_opts.X = offset_x
		display_opts.Y = offset_y
	end
	out:put(gfx.build_cmd(display_opts))

	-- Create two additional frames (2 and 3) for double-buffering.
	-- We never edit/display the root frame directly.
	out:put(build_shm_or_data(shm_name_a, data, { a = "f", i = image_id, f = opts.f, s = opts.s, v = opts.v, q = 2, X = 1 }))
	out:put(build_shm_or_data(shm_name_b, data, { a = "f", i = image_id, f = opts.f, s = opts.s, v = opts.v, q = 2, X = 1 }))

	-- Show frame 2 initially
	anim_show_frame(out, image_id, 2)
end

local function anim_edit_frame_rect(out, image_id, shm_name, data, opts, frame_no, x, y, s, v)
	out:put(build_shm_or_data(shm_name, data, {
		a = "f",
		i = image_id,
		r = frame_no,
		f = opts.f,
		x = x,
		y = y,
		s = s,
		v = v,
		q = 2,
		X = 1,
	}))
end

-- anim_show_frame defined above

-- Screen dimensions
local SCREEN_WIDTH = 256
local SCREEN_HEIGHT = 192
local BITMAP_SIZE = 6144

-- Use RGB (f=24) instead of RGBA (f=32) to reduce bandwidth
local PIXEL_BYTES = 3

-- Full PAL display dimensions including border
-- Defined here (before Screen:new()) so buffer pre-allocation can use them.
local FULL_WIDTH = 352 -- 48 + 256 + 48
local FULL_HEIGHT = 296 -- 56 + 192 + 48

-- Border sizes (in pixels)
local BORDER_LEFT = 48
local BORDER_RIGHT = 48
local BORDER_TOP = 56
local BORDER_BOTTOM = 48

-- ZX Spectrum 16-color palette (8 normal + 8 bright)
local ZX_PALETTE = {
	[0] = { 0, 0, 0 }, -- Black
	[1] = { 0, 0, 205 }, -- Blue
	[2] = { 205, 0, 0 }, -- Red
	[3] = { 205, 0, 205 }, -- Magenta
	[4] = { 0, 205, 0 }, -- Green
	[5] = { 0, 205, 205 }, -- Cyan
	[6] = { 205, 205, 0 }, -- Yellow
	[7] = { 205, 205, 205 }, -- White
	-- Bright variants
	[8] = { 0, 0, 0 }, -- Black (same)
	[9] = { 0, 0, 255 }, -- Bright Blue
	[10] = { 255, 0, 0 }, -- Bright Red
	[11] = { 255, 0, 255 }, -- Bright Magenta
	[12] = { 0, 255, 0 }, -- Bright Green
	[13] = { 0, 255, 255 }, -- Bright Cyan
	[14] = { 255, 255, 0 }, -- Bright Yellow
	[15] = { 255, 255, 255 }, -- Bright White
}

-- Pre-computed Y coordinate to bitmap offset lookup table
-- Avoids repeated arithmetic in hot render loop
local Y_OFFSET = {}
for y = 0, 191 do
	local third = math.floor(y / 64)
	local line_in_third = y % 64
	local char_row = math.floor(line_in_third / 8)
	local pixel_row = line_in_third % 8
	Y_OFFSET[y] = third * 2048 + pixel_row * 256 + char_row * 32
end

-- Pre-computed attribute byte to colors lookup table
-- Maps raw attribute byte (0-255) to {ink_color, paper_color}
local ATTR_COLORS = {}
for attr = 0, 255 do
	local ink = attr % 8
	local paper = math.floor(attr / 8) % 8
	local bright = math.floor(attr / 64) % 2
	if bright == 1 then
		ink = ink + 8
		paper = paper + 8
	end
	ATTR_COLORS[attr] = { ZX_PALETTE[ink], ZX_PALETTE[paper] }
end

-- Convert screen Y coordinate (0-191) to SCR bitmap offset
-- ZX Spectrum's memory layout is organized in thirds with interleaved lines
local function y_to_bitmap_offset(y)
	local third = math.floor(y / 64)
	local line_in_third = y % 64
	local char_row = math.floor(line_in_third / 8)
	local pixel_row = line_in_third % 8

	return third * 2048 + pixel_row * 256 + char_row * 32
end

-- Get attribute byte offset for a given screen position
local function xy_to_attr_offset(x, y)
	local cell_x = math.floor(x / 8)
	local cell_y = math.floor(y / 8)
	return BITMAP_SIZE + cell_y * 32 + cell_x
end

-- Parse attribute byte into ink and paper color indices
local function parse_attribute(attr_byte)
	local ink = attr_byte % 8
	local paper = math.floor(attr_byte / 8) % 8
	local bright = math.floor(attr_byte / 64) % 2

	if bright == 1 then
		ink = ink + 8
		paper = paper + 8
	end

	return ink, paper
end

-- Render SCR data to a canvas with optional scaling
-- Optimized: iterates by 8×8 cells, uses lookup tables
function M.render(canvas, scr_data, scale)
	scale = scale or 1

	if #scr_data ~= 6912 then
		return nil, "Invalid SCR data size"
	end

	-- Iterate by character cells (32×24) instead of pixels (256×192)
	for cell_y = 0, 23 do
		for cell_x = 0, 31 do
			-- Get attribute colors once per cell (was 64× per cell before)
			local attr_offset = BITMAP_SIZE + cell_y * 32 + cell_x + 1
			local attr_byte = scr_data:byte(attr_offset)
			local colors = ATTR_COLORS[attr_byte]
			local ink_color, paper_color = colors[1], colors[2]

			local base_x = cell_x * 8
			local base_y = cell_y * 8

			-- Process 8 pixel rows in this cell
			for py = 0, 7 do
				local y = base_y + py
				local bitmap_offset = Y_OFFSET[y] + cell_x + 1
				local bitmap_byte = scr_data:byte(bitmap_offset)

				-- Process 8 pixels in this row
				for px = 0, 7 do
					local x = base_x + px
					-- Use bit library for fast bit extraction
					local pixel_set = bit.band(bit.rshift(bitmap_byte, 7 - px), 1) == 1
					local color = pixel_set and ink_color or paper_color

					-- Draw pixel (with scaling)
					if scale == 1 then
						canvas:pixel(x + 1, y + 1, color)
					else
						local sx = x * scale + 1
						local sy = y * scale + 1
						for dy = 0, scale - 1 do
							for dx = 0, scale - 1 do
								canvas:pixel(sx + dx, sy + dy, color)
							end
						end
					end
				end
			end
		end
	end

	return true
end

-- ============================================================================
-- Screen class for instance-based rendering with state isolation
-- ============================================================================

local Screen = {}
Screen.__index = Screen

-- Image ids used by the emulator
local IMAGE_ID_MAIN = 7800
local IMAGE_ID_BORDER = 7801

-- Create a new screen renderer instance
function M.new()
	local shm_prefix = "/lilush-zx-" .. std.nanoid()
	local self = setmetatable({
		-- Incremental render state
		prev_screen = nil,
		-- Pre-allocated buffers for reuse (reduces GC pressure)
		rgba_buffer = sbuf.new(SCREEN_WIDTH * SCREEN_HEIGHT * PIXEL_BYTES),
		rgba_buffer_border = sbuf.new(FULL_WIDTH * FULL_HEIGHT * PIXEL_BYTES),
		row_buffer = sbuf.new(FULL_WIDTH * PIXEL_BYTES),
		-- Previous frame data for skip optimization
		prev_scr_data = nil,
		-- Shared memory object names (avoid per-frame shm leaks)
		shm_main_a = shm_prefix .. "-main-a",
		shm_main_b = shm_prefix .. "-main-b",
		shm_border_a = shm_prefix .. "-border-a",
		shm_border_b = shm_prefix .. "-border-b",
		-- Animation state (kitty graphics protocol animation frames)
		anim_main_initialized = false,
		anim_border_initialized = false,
		anim_main_frame = 2,
		anim_border_frame = 2,
		-- Track if we've initialized images (for cleanup)
		initialized = false,
	}, Screen)
	return self
end

-- Cleanup images on exit (call this when emulator closes)
function Screen:cleanup()
	if self.initialized then
		-- Delete all our images to clean up terminal state
		gfx.send_cmd({ a = "d", d = "I", i = IMAGE_ID_MAIN })
		gfx.send_cmd({ a = "d", d = "I", i = IMAGE_ID_BORDER })

		-- Cleanup shared memory objects we created.
		-- POSIX shm objects appear as files in /dev/shm/<name-without-leading-slash>
		local function rm_shm(name)
			if not name then
				return
			end
			pcall(std.fs.remove, "/dev/shm/" .. name:sub(2), false)
		end
		rm_shm(self.shm_main_a)
		rm_shm(self.shm_main_b)
		rm_shm(self.shm_border_a)
		rm_shm(self.shm_border_b)

		self.initialized = false
		self.anim_main_initialized = false
		self.anim_border_initialized = false
		self.anim_main_frame = 2
		self.anim_border_frame = 2
	end
end

-- Optimized render that only updates changed character cells
-- Requires tracking previous screen state
function Screen:render_incremental(canvas, scr_data, scale)
	scale = scale or 1

	if #scr_data ~= 6912 then
		return nil, "Invalid SCR data size"
	end

	-- If no previous state, do full render
	if not self.prev_screen then
		self.prev_screen = scr_data
		return M.render(canvas, scr_data, scale)
	end

	-- Check each 8x8 character cell for changes
	for cell_y = 0, 23 do
		for cell_x = 0, 31 do
			local changed = false

			-- Check attribute byte
			local attr_offset = BITMAP_SIZE + cell_y * 32 + cell_x + 1
			if scr_data:byte(attr_offset) ~= self.prev_screen:byte(attr_offset) then
				changed = true
			end

			-- Check bitmap bytes for this cell (8 bytes, one per line)
			if not changed then
				local base_y = cell_y * 8
				for line = 0, 7 do
					local y = base_y + line
					local bitmap_offset = Y_OFFSET[y] + cell_x + 1
					if scr_data:byte(bitmap_offset) ~= self.prev_screen:byte(bitmap_offset) then
						changed = true
						break
					end
				end
			end

			-- If changed, redraw this cell
			if changed then
				local base_x = cell_x * 8
				local base_y = cell_y * 8

				-- Get attribute colors once per cell (moved outside py loop)
				local attr_byte = scr_data:byte(attr_offset)
				local colors = ATTR_COLORS[attr_byte]
				local ink_color, paper_color = colors[1], colors[2]

				for py = 0, 7 do
					local y = base_y + py
					local bitmap_offset = Y_OFFSET[y] + cell_x + 1
					local bitmap_byte = scr_data:byte(bitmap_offset)

					for px = 0, 7 do
						local x = base_x + px
						local pixel_set = bit.band(bit.rshift(bitmap_byte, 7 - px), 1) == 1
						local color = pixel_set and ink_color or paper_color

						if scale == 1 then
							canvas:pixel(x + 1, y + 1, color)
						else
							local sx = x * scale + 1
							local sy = y * scale + 1
							for dy = 0, scale - 1 do
								for dx = 0, scale - 1 do
									canvas:pixel(sx + dx, sy + dy, color)
								end
							end
						end
					end
				end
			end
		end
	end

	self.prev_screen = scr_data
	return true
end

-- Reset incremental state (call when loading new program)
function Screen:reset_incremental()
	self.prev_screen = nil
	self.prev_scr_data = nil
end

-- ============================================================================
-- FAST DIRECT RENDERING (bypasses canvas for maximum performance)
-- ============================================================================

-- Pre-compute RGB strings for each color (avoids string.char calls in hot loop)
local COLOR_RGB = {}
for i = 0, 15 do
	local c = ZX_PALETTE[i]
	COLOR_RGB[i] = string.char(c[1], c[2], c[3])
end

-- Pre-compute expanded pixel rows for all 256 possible bitmap bytes
-- For each bitmap byte and attribute, we get 8 RGB pixels
-- This is a 2-level lookup: PIXEL_ROWS[bitmap_byte][attr_byte] = 24-byte string (8 pixels × 3 bytes)
local PIXEL_ROWS = {}
for bitmap = 0, 255 do
	PIXEL_ROWS[bitmap] = {}
	for attr = 0, 255 do
		local ink_rgb = COLOR_RGB[attr % 8 + (bit.band(attr, 64) ~= 0 and 8 or 0)]
		local paper_rgb = COLOR_RGB[bit.band(bit.rshift(attr, 3), 7) + (bit.band(attr, 64) ~= 0 and 8 or 0)]

		local row = sbuf.new(24)
		for px = 7, 0, -1 do
			if bit.band(bitmap, bit.lshift(1, px)) ~= 0 then
				row:put(ink_rgb)
			else
				row:put(paper_rgb)
			end
		end
		PIXEL_ROWS[bitmap][attr] = row:get()
	end
end

-- Cache for horizontally scaled 8-pixel chunks.
-- SCALED_PIXEL_ROWS[scale][bitmap_byte][attr_byte] => (8*scale) pixels as RGB.
local SCALED_PIXEL_ROWS = {}

local function get_pixel_row(bitmap_byte, attr_byte, scale)
	if scale == 1 then
		return PIXEL_ROWS[bitmap_byte][attr_byte]
	end
	local by_scale = SCALED_PIXEL_ROWS[scale]
	if not by_scale then
		by_scale = {}
		SCALED_PIXEL_ROWS[scale] = by_scale
	end
	local by_bitmap = by_scale[bitmap_byte]
	if not by_bitmap then
		by_bitmap = {}
		by_scale[bitmap_byte] = by_bitmap
	end
	local cached = by_bitmap[attr_byte]
	if cached then
		return cached
	end

	-- Expand the 8-pixel RGB row horizontally
	local base = PIXEL_ROWS[bitmap_byte][attr_byte]
	local out = sbuf.new(8 * scale * PIXEL_BYTES)
	for px = 0, 7 do
		local p = base:sub(px * PIXEL_BYTES + 1, px * PIXEL_BYTES + PIXEL_BYTES)
		for _ = 1, scale do
			out:put(p)
		end
	end
	cached = out:get()
	by_bitmap[attr_byte] = cached
	return cached
end

local function build_full_frame(scr_data, scale, frame_buf, row_buf)
	frame_buf:reset()
	for y = 0, SCREEN_HEIGHT - 1 do
		row_buf:reset()
		local bitmap_base = Y_OFFSET[y]
		local attr_row = math.floor(y / 8)
		for cell_x = 0, 31 do
			local bitmap_byte = scr_data:byte(bitmap_base + cell_x + 1)
			local attr_byte = scr_data:byte(BITMAP_SIZE + attr_row * 32 + cell_x + 1)
			row_buf:put(get_pixel_row(bitmap_byte, attr_byte, scale))
		end
		local row_data = row_buf:get()
		for _ = 1, scale do
			frame_buf:put(row_data)
		end
	end
	return frame_buf:get()
end

-- Fast render directly to RGBA buffer and send via Kitty protocol
-- This bypasses the canvas abstraction entirely
-- Note: This renders only the 256x192 main display without border
-- row, col: terminal row/column for image placement (1-indexed)
-- offset_x, offset_y: sub-cell pixel offsets within the cell
function Screen:render_fast(scr_data, scale, row, col, offset_x, offset_y)
	scale = scale or 1

	if #scr_data ~= 6912 then
		return nil, "Invalid SCR data size"
	end

	local prev = self.prev_scr_data
	if scr_data == prev then
		return true
	end

	local width = SCREEN_WIDTH * scale
	local height = SCREEN_HEIGHT * scale
	local image_id = IMAGE_ID_MAIN
	local opts = { f = 24, s = width, v = height }
	self.initialized = true

	local need_init = (not self.anim_main_initialized)
		or (self.anim_main_scale ~= scale)
		or (self.anim_main_row ~= row)
		or (self.anim_main_col ~= col)
		or (self.anim_main_offx ~= offset_x)
		or (self.anim_main_offy ~= offset_y)

	local cmd = sbuf.new(4096)
	cmd:put(SYNC_START)

	if not self.full_row_buffer or self.full_row_buffer_scale ~= scale then
		self.full_row_buffer = sbuf.new(SCREEN_WIDTH * scale * PIXEL_BYTES)
		self.full_row_buffer_scale = scale
	end

	if need_init then
		local pixel_data = build_full_frame(scr_data, scale, self.rgba_buffer, self.full_row_buffer)
		anim_init(cmd, image_id, self.shm_main_a, self.shm_main_b, pixel_data, opts, row, col, offset_x, offset_y)
		self.anim_main_initialized = true
		self.anim_main_frame = 2
		self.anim_main_scale = scale
		self.anim_main_row = row
		self.anim_main_col = col
		self.anim_main_offx = offset_x
		self.anim_main_offy = offset_y
		cmd:put(SYNC_END)
		io.write(cmd:get())
		io.flush()
		self.prev_scr_data = scr_data
		return true
	end

	-- Double-buffering: render into a non-displayed frame, then flip.
	local front = self.anim_main_frame
	local back = (front == 2) and 3 or 2
	local shm_name = (back == 2) and self.shm_main_a or self.shm_main_b
	local pixel_data = build_full_frame(scr_data, scale, self.rgba_buffer, self.full_row_buffer)
	anim_edit_frame_rect(cmd, image_id, shm_name, pixel_data, opts, back, 0, 0, opts.s, opts.v)
	anim_show_frame(cmd, image_id, back)
	self.anim_main_frame = back

	cmd:put(SYNC_END)
	io.write(cmd:get())
	io.flush()
	self.prev_scr_data = scr_data
	return true
end

-- ============================================================================
-- BORDER RENDERING (for tape loading visualization)
-- ============================================================================

-- Full PAL display dimensions including border
-- (Defined earlier in this file)

-- Scanlines per frame (PAL)
local SCANLINES_PER_FRAME = 312

-- The visible display starts at scanline 8 in the PAL frame
-- Main display (192 lines) starts at scanline 64
-- So visible top border = scanlines 8-63 (56 lines)
-- Main display = scanlines 64-255 (192 lines)
-- Visible bottom border = scanlines 256-303 (48 lines)
local VISIBLE_START_LINE = 8

-- Pre-compute RGB strings for border colors (same as COLOR_RGB but using indices 0-7)
local BORDER_RGB = {}
for i = 0, 7 do
	local c = ZX_PALETTE[i]
	BORDER_RGB[i] = string.char(c[1], c[2], c[3])
end

-- Render screen with border using per-scanline border colors
-- border_lines: 312-byte string with border color (0-7) per scanline (can be nil)
-- show_stripes: if true, show actual border colors; if false, show black border
-- row, col: terminal row/column for image placement (1-indexed)
-- offset_x, offset_y: sub-cell pixel offsets within the cell
function Screen:render_with_border(scr_data, border_lines, scale, show_stripes, row, col, offset_x, offset_y)
	scale = scale or 1

	if #scr_data ~= 6912 then
		return nil, "Invalid SCR data size"
	end

	-- If no border data or not showing stripes, use black border
	local use_border_data = show_stripes and border_lines and #border_lines == SCANLINES_PER_FRAME

	local width = FULL_WIDTH * scale
	local height = FULL_HEIGHT * scale

	-- Reuse pre-allocated buffer
	self.rgba_buffer_border:reset()
	local out = self.rgba_buffer_border

	local image_id = IMAGE_ID_BORDER
	local opts = { f = 24, s = width, v = height }
	self.initialized = true

	-- Black color for non-stripe border
	local black_rgb = BORDER_RGB[0]

	-- Ensure scaled row buffer is allocated for border scale
	if scale > 1 and self.scaled_row_buffer_border_scale ~= scale then
		self.scaled_row_buffer_border = sbuf.new(width * PIXEL_BYTES)
		self.scaled_row_buffer_border_scale = scale
	end

	-- Process each display row
	-- Map display rows to PAL scanlines (visible area starts at scanline 8)
	for display_y = 0, FULL_HEIGHT - 1 do
		local scanline = VISIBLE_START_LINE + display_y

		-- Get border color: from scanline data if showing stripes, otherwise black
		local border_rgb
		if use_border_data then
			local border_color = border_lines:byte(scanline + 1) or 0
			border_rgb = BORDER_RGB[border_color]
		else
			border_rgb = black_rgb
		end

		-- Build one native-resolution row (reuse buffer)
		self.row_buffer:reset()
		local row = self.row_buffer

		if display_y < BORDER_TOP or display_y >= BORDER_TOP + SCREEN_HEIGHT then
			-- Pure border row (top or bottom)
			for _ = 0, FULL_WIDTH - 1 do
				row:put(border_rgb)
			end
		else
			-- Main display row with left/right borders
			local y = display_y - BORDER_TOP
			local bitmap_base = Y_OFFSET[y]
			local attr_row = math.floor(y / 8)

			-- Left border
			for _ = 0, BORDER_LEFT - 1 do
				row:put(border_rgb)
			end

			-- Main display (256 pixels)
			for cell_x = 0, 31 do
				local bitmap_byte = scr_data:byte(bitmap_base + cell_x + 1)
				local attr_byte = scr_data:byte(BITMAP_SIZE + attr_row * 32 + cell_x + 1)
				row:put(PIXEL_ROWS[bitmap_byte][attr_byte])
			end

			-- Right border
			for _ = 0, BORDER_RIGHT - 1 do
				row:put(border_rgb)
			end
		end

		local row_data = row:get()

		if scale == 1 then
			out:put(row_data)
		else
			-- Scale horizontally and vertically (reuse buffer)
			self.scaled_row_buffer_border:reset()
			local scaled_row = self.scaled_row_buffer_border
			for px = 0, FULL_WIDTH - 1 do
				local pixel = row_data:sub(px * PIXEL_BYTES + 1, px * PIXEL_BYTES + PIXEL_BYTES)
				for _ = 1, scale do
					scaled_row:put(pixel)
				end
			end
			local scaled_row_data = scaled_row:get()

			-- Repeat for vertical scaling
			for _ = 1, scale do
				out:put(scaled_row_data)
			end
		end
	end

	local pixel_data = out:get()
	local cmd = sbuf.new(#pixel_data + 1024)
	cmd:put(SYNC_START)
	local need_init = (not self.anim_border_initialized)
		or (self.anim_border_scale ~= scale)
		or (self.anim_border_row ~= row)
		or (self.anim_border_col ~= col)
		or (self.anim_border_offx ~= offset_x)
		or (self.anim_border_offy ~= offset_y)

	if need_init then
		anim_init(cmd, image_id, self.shm_border_a, self.shm_border_b, pixel_data, opts, row, col, offset_x, offset_y)
		self.anim_border_initialized = true
		self.anim_border_frame = 2
		self.anim_border_scale = scale
		self.anim_border_row = row
		self.anim_border_col = col
		self.anim_border_offx = offset_x
		self.anim_border_offy = offset_y
	else
		local front = self.anim_border_frame
		local back = (front == 2) and 3 or 2
		local shm_name = (back == 2) and self.shm_border_a or self.shm_border_b
		anim_edit_frame_rect(cmd, image_id, shm_name, pixel_data, opts, back, 0, 0, opts.s, opts.v)
		anim_show_frame(cmd, image_id, back)
		self.anim_border_frame = back
	end
	cmd:put(SYNC_END)
	io.write(cmd:get())
	io.flush()
	return true
end

-- Export palette and dimensions for external use
M.ZX_PALETTE = ZX_PALETTE
M.SCREEN_WIDTH = SCREEN_WIDTH
M.SCREEN_HEIGHT = SCREEN_HEIGHT
M.FULL_WIDTH = FULL_WIDTH
M.FULL_HEIGHT = FULL_HEIGHT
M.BORDER_LEFT = BORDER_LEFT
M.BORDER_TOP = BORDER_TOP
M.BORDER_RIGHT = BORDER_RIGHT
M.BORDER_BOTTOM = BORDER_BOTTOM

return M
