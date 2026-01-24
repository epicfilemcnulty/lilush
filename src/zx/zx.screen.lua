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

local bit = require("bit")
local sbuf = require("string.buffer")
local gfx = require("term.gfx")

-- Screen dimensions
local SCREEN_WIDTH = 256
local SCREEN_HEIGHT = 192
local BITMAP_SIZE = 6144

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

-- Create a new screen renderer instance
function M.new()
	local self = setmetatable({
		-- Incremental render state
		prev_screen = nil,
	}, Screen)
	return self
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
end

-- ============================================================================
-- FAST DIRECT RENDERING (bypasses canvas for maximum performance)
-- ============================================================================

-- Pre-compute RGBA strings for each color (avoids string.char calls in hot loop)
local COLOR_RGBA = {}
for i = 0, 15 do
	local c = ZX_PALETTE[i]
	COLOR_RGBA[i] = string.char(c[1], c[2], c[3], 255)
end

-- Pre-compute expanded pixel rows for all 256 possible bitmap bytes
-- For each bitmap byte and attribute, we get 8 RGBA pixels
-- This is a 2-level lookup: PIXEL_ROWS[bitmap_byte][attr_byte] = 32-byte string (8 pixels × 4 bytes)
local PIXEL_ROWS = {}
for bitmap = 0, 255 do
	PIXEL_ROWS[bitmap] = {}
	for attr = 0, 255 do
		local colors = ATTR_COLORS[attr]
		local ink_rgba = COLOR_RGBA[attr % 8 + (bit.band(attr, 64) ~= 0 and 8 or 0)]
		local paper_rgba = COLOR_RGBA[bit.band(bit.rshift(attr, 3), 7) + (bit.band(attr, 64) ~= 0 and 8 or 0)]

		local row = sbuf.new(32)
		for px = 7, 0, -1 do
			if bit.band(bitmap, bit.lshift(1, px)) ~= 0 then
				row:put(ink_rgba)
			else
				row:put(paper_rgba)
			end
		end
		PIXEL_ROWS[bitmap][attr] = row:get()
	end
end

-- Fast render directly to RGBA buffer and send via Kitty protocol
-- This bypasses the canvas abstraction entirely
-- Note: This renders only the 256x192 main display without border
-- Optional offset_x, offset_y specify sub-cell pixel offsets within the current cell
function Screen:render_fast(scr_data, scale, offset_x, offset_y)
	scale = scale or 1

	if #scr_data ~= 6912 then
		return nil, "Invalid SCR data size"
	end

	local width = SCREEN_WIDTH * scale
	local height = SCREEN_HEIGHT * scale

	-- Build graphics protocol options
	-- C=1 prevents cursor movement after displaying the image
	local opts = { a = "T", f = 32, s = width, v = height, C = 1 }
	if offset_x and offset_y then
		opts.X = offset_x
		opts.Y = offset_y
	end

	if scale == 1 then
		-- Scale 1: direct output using pre-computed rows
		local out = sbuf.new(SCREEN_WIDTH * SCREEN_HEIGHT * 4)

		for y = 0, SCREEN_HEIGHT - 1 do
			local bitmap_base = Y_OFFSET[y]
			local attr_row = math.floor(y / 8)

			for cell_x = 0, 31 do
				local bitmap_byte = scr_data:byte(bitmap_base + cell_x + 1)
				local attr_byte = scr_data:byte(BITMAP_SIZE + attr_row * 32 + cell_x + 1)
				out:put(PIXEL_ROWS[bitmap_byte][attr_byte])
			end
		end

		gfx.send_data(out:get(), opts)
		return true
	end

	-- Scale > 1: build scaled buffer efficiently
	-- Pre-allocate full buffer
	local out = sbuf.new(width * height * 4)

	for y = 0, SCREEN_HEIGHT - 1 do
		local bitmap_base = Y_OFFSET[y]
		local attr_row = math.floor(y / 8)

		-- Build native row first
		local row_parts = {}
		for cell_x = 0, 31 do
			local bitmap_byte = scr_data:byte(bitmap_base + cell_x + 1)
			local attr_byte = scr_data:byte(BITMAP_SIZE + attr_row * 32 + cell_x + 1)
			row_parts[cell_x + 1] = PIXEL_ROWS[bitmap_byte][attr_byte]
		end

		-- Scale horizontally: repeat each pixel 'scale' times
		local scaled_row = sbuf.new(width * 4)
		for _, part in ipairs(row_parts) do
			-- Each part is 32 bytes (8 pixels × 4 bytes)
			for px = 0, 7 do
				local pixel = part:sub(px * 4 + 1, px * 4 + 4)
				for _ = 1, scale do
					scaled_row:put(pixel)
				end
			end
		end
		local row_data = scaled_row:get()

		-- Output row 'scale' times for vertical scaling
		for _ = 1, scale do
			out:put(row_data)
		end
	end

	gfx.send_data(out:get(), opts)
	return true
end

-- ============================================================================
-- BORDER RENDERING (for tape loading visualization)
-- ============================================================================

-- Full PAL display dimensions including border
local FULL_WIDTH = 352 -- 48 + 256 + 48
local FULL_HEIGHT = 296 -- 56 + 192 + 48

-- Border sizes (in pixels)
local BORDER_LEFT = 48
local BORDER_RIGHT = 48
local BORDER_TOP = 56
local BORDER_BOTTOM = 48

-- Scanlines per frame (PAL)
local SCANLINES_PER_FRAME = 312

-- The visible display starts at scanline 8 in the PAL frame
-- Main display (192 lines) starts at scanline 64
-- So visible top border = scanlines 8-63 (56 lines)
-- Main display = scanlines 64-255 (192 lines)
-- Visible bottom border = scanlines 256-303 (48 lines)
local VISIBLE_START_LINE = 8

-- Pre-compute RGBA strings for border colors (same as COLOR_RGBA but using indices 0-7)
local BORDER_RGBA = {}
for i = 0, 7 do
	local c = ZX_PALETTE[i]
	BORDER_RGBA[i] = string.char(c[1], c[2], c[3], 255)
end

-- Render screen with border using per-scanline border colors
-- border_lines: 312-byte string with border color (0-7) per scanline (can be nil)
-- show_stripes: if true, show actual border colors; if false, show black border
-- Optional offset_x, offset_y specify sub-cell pixel offsets within the current cell
function Screen:render_with_border(scr_data, border_lines, scale, show_stripes, offset_x, offset_y)
	scale = scale or 1

	if #scr_data ~= 6912 then
		return nil, "Invalid SCR data size"
	end

	-- If no border data or not showing stripes, use black border
	local use_border_data = show_stripes and border_lines and #border_lines == SCANLINES_PER_FRAME

	local width = FULL_WIDTH * scale
	local height = FULL_HEIGHT * scale
	local out = sbuf.new(width * height * 4)

	-- Build graphics protocol options
	-- C=1 prevents cursor movement after displaying the image
	local opts = { a = "T", f = 32, s = width, v = height, C = 1 }
	if offset_x and offset_y then
		opts.X = offset_x
		opts.Y = offset_y
	end

	-- Black color for non-stripe border
	local black_rgba = BORDER_RGBA[0]

	-- Process each display row
	-- Map display rows to PAL scanlines (visible area starts at scanline 8)
	for display_y = 0, FULL_HEIGHT - 1 do
		local scanline = VISIBLE_START_LINE + display_y

		-- Get border color: from scanline data if showing stripes, otherwise black
		local border_rgba
		if use_border_data then
			local border_color = border_lines:byte(scanline + 1) or 0
			border_rgba = BORDER_RGBA[border_color]
		else
			border_rgba = black_rgba
		end

		-- Build one native-resolution row
		local row = sbuf.new(FULL_WIDTH * 4)

		if display_y < BORDER_TOP or display_y >= BORDER_TOP + SCREEN_HEIGHT then
			-- Pure border row (top or bottom)
			for _ = 0, FULL_WIDTH - 1 do
				row:put(border_rgba)
			end
		else
			-- Main display row with left/right borders
			local y = display_y - BORDER_TOP
			local bitmap_base = Y_OFFSET[y]
			local attr_row = math.floor(y / 8)

			-- Left border
			for _ = 0, BORDER_LEFT - 1 do
				row:put(border_rgba)
			end

			-- Main display (256 pixels)
			for cell_x = 0, 31 do
				local bitmap_byte = scr_data:byte(bitmap_base + cell_x + 1)
				local attr_byte = scr_data:byte(BITMAP_SIZE + attr_row * 32 + cell_x + 1)
				row:put(PIXEL_ROWS[bitmap_byte][attr_byte])
			end

			-- Right border
			for _ = 0, BORDER_RIGHT - 1 do
				row:put(border_rgba)
			end
		end

		local row_data = row:get()

		if scale == 1 then
			out:put(row_data)
		else
			-- Scale horizontally and vertically
			local scaled_row = sbuf.new(width * 4)
			for px = 0, FULL_WIDTH - 1 do
				local pixel = row_data:sub(px * 4 + 1, px * 4 + 4)
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

	gfx.send_data(out:get(), opts)
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
