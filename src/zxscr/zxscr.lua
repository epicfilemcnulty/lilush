-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
  ZX Spectrum SCR file viewer for Kitty terminal graphics protocol.

  The SCR format is a 6912-byte memory dump of the ZX Spectrum display:
  - Bitmap data: 6144 bytes (256x192 pixels, 1 bit per pixel)
  - Attribute data: 768 bytes (32x24 character cells, each 8x8 pixels)

  The screen layout is notoriously non-linear - organized in thirds
  with interleaved scan lines.

  Each attribute byte controls an 8x8 pixel block:
  - Bits 0-2: INK color (foreground)
  - Bits 3-5: PAPER color (background)
  - Bit 6: BRIGHT flag
  - Bit 7: FLASH flag (ignored for static display)
]]

local std = require("std")
local gfx = require("term.gfx")

local SCR_SIZE = 6912
local BITMAP_SIZE = 6144
local SCREEN_WIDTH = 256
local SCREEN_HEIGHT = 192

-- ZX Spectrum 16-color palette (8 normal + 8 bright)
-- Index 0-7: normal colors, 8-15: bright colors
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

-- Convert screen Y coordinate (0-191) to SCR bitmap file offset
-- ZX Spectrum's memory layout formula:
-- The screen is divided into 3 thirds (0-63, 64-127, 128-191)
-- Within each third, lines are interleaved in a complex pattern
local function y_to_bitmap_offset(y)
	-- Which third of the screen (0, 1, or 2)
	local third = math.floor(y / 64)
	-- Line within the third (0-63)
	local line_in_third = y % 64
	-- Character row within third (0-7)
	local char_row = math.floor(line_in_third / 8)
	-- Pixel row within character (0-7)
	local pixel_row = line_in_third % 8

	-- Each third is 2048 bytes
	-- Within third: pixel_row * 256 + char_row * 32
	local offset = third * 2048 + pixel_row * 256 + char_row * 32

	return offset
end

-- Get attribute byte offset for a given screen position
-- Attributes are stored linearly, one byte per 8x8 cell
local function xy_to_attr_offset(x, y)
	local cell_x = math.floor(x / 8)
	local cell_y = math.floor(y / 8)
	return BITMAP_SIZE + cell_y * 32 + cell_x
end

-- Parse attribute byte into ink, paper, and bright flag
local function parse_attribute(attr_byte)
	local ink = attr_byte % 8 -- bits 0-2
	local paper = math.floor(attr_byte / 8) % 8 -- bits 3-5
	local bright = math.floor(attr_byte / 64) % 2 -- bit 6
	-- bit 7 is flash, ignored

	-- Apply bright flag to color indices
	if bright == 1 then
		ink = ink + 8
		paper = paper + 8
	end

	return ink, paper
end

-- Decode SCR data into a 2D pixel array with RGB colors
-- Returns pixels[y][x] = {r, g, b}
local function decode_scr(data)
	if #data ~= SCR_SIZE then
		return nil, string.format("Invalid SCR file size: expected %d bytes, got %d", SCR_SIZE, #data)
	end

	local pixels = {}

	for y = 0, SCREEN_HEIGHT - 1 do
		pixels[y] = {}
		local bitmap_offset = y_to_bitmap_offset(y)

		for x = 0, SCREEN_WIDTH - 1 do
			-- Get the byte containing this pixel
			local byte_x = math.floor(x / 8)
			local bit_pos = 7 - (x % 8) -- MSB is leftmost pixel

			local byte_offset = bitmap_offset + byte_x + 1 -- +1 for Lua 1-indexing
			local bitmap_byte = data:byte(byte_offset)

			-- Get attribute for this position
			local attr_offset = xy_to_attr_offset(x, y) + 1 -- +1 for Lua 1-indexing
			local attr_byte = data:byte(attr_offset)
			local ink, paper = parse_attribute(attr_byte)

			-- Check if pixel is set (ink) or not (paper)
			local pixel_set = math.floor(bitmap_byte / (2 ^ bit_pos)) % 2 == 1

			local color_idx = pixel_set and ink or paper
			pixels[y][x] = ZX_PALETTE[color_idx]
		end
	end

	return pixels
end

-- Display SCR file using Kitty graphics protocol,
-- optionally scaled.

--[[

For quick reference, here is size-scale
info for supported scales:

| Scale | Dimensions | Pixels | RGBA Size (bytes) |
|-------|------------|--------|-------------------|
| 1x | 256×192 | 49,152 | 196,608 (~192KB) |
| 2x | 512×384 | 196,608 | 786,432 (~768KB) |
| 3x | 768×576 | 442,368 | 1,769,472 (~1.7MB) |
| 4x | 1024×768 | 786,432 | 3,145,728 (~3MB) |
| 5x | 1280×960 | 1,228,800 | 4,915,200 (~4.7MB) |
| 8x | 2048×1536 | 3,145,728 | 12,582,912 (~12MB) |

]]

local function display(filepath, options)
	options = options or {}
	local scale = options.scale or 1

	local data, err = std.fs.read_file(filepath)
	if not data then
		return nil, "Failed to read file: " .. (err or "unknown error")
	end

	local pixels, decode_err = decode_scr(data)
	if not pixels then
		return nil, decode_err
	end

	local canvas_width = SCREEN_WIDTH * scale
	local canvas_height = SCREEN_HEIGHT * scale

	local canvas = gfx.new_canvas({
		width = canvas_width,
		height = canvas_height,
	})

	-- Fill canvas with decoded pixels (with scaling)
	for y = 0, SCREEN_HEIGHT - 1 do
		for x = 0, SCREEN_WIDTH - 1 do
			local color = pixels[y][x]
			if scale == 1 then
				canvas:pixel(x + 1, y + 1, color) -- +1 for 1-indexed canvas
			else
				-- Draw scaled pixel as a filled rectangle
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

	-- Send to terminal
	canvas:send({ a = "T" }) -- Transmit and display immediately
	return true
end

return {
	display = display,
	decode_scr = decode_scr,
	ZX_PALETTE = ZX_PALETTE,
	SCR_SIZE = SCR_SIZE,
	SCREEN_WIDTH = SCREEN_WIDTH,
	SCREEN_HEIGHT = SCREEN_HEIGHT,
}
