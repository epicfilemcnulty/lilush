-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local core = require("term.core")
local buffer = require("string.buffer")
local std = require("std")

--[[
     See https://en.wikipedia.org/wiki/ANSI_escape_code
     for info on ANSI escape codes, text colors and attributes.
]]

local hide_cursor = function()
	io.write("\027[?25l")
	io.flush()
end

local show_cursor = function()
	io.write("\027[?25h")
	io.flush()
end

local go = function(l, c)
	if l and c then
		io.write("\027[", l, ";", c, "H")
		io.flush()
	end
end

local write = function(s)
	io.write(s)
	io.flush()
end

local write_at = function(l, c, s)
	go(l, c)
	io.write(s)
	io.flush()
end

local MOVEMENTS = {
	up = "\027[{count}A",
	down = "\027[{count}B",
	right = "\027[{count}C",
	left = "\027[{count}D",
	line_down = "\027[{count}E",
	line_up = "\027[{count}F",
	column = "\027[{count}G",
}

local move = function(direction, count)
	if MOVEMENTS[direction] then
		local count = count or 1
		local move = MOVEMENTS[direction]:gsub("{count}", count)
		io.write(move)
		io.flush()
	end
end

local clear = function()
	io.write("\027[2J")
	io.flush()
end

local clear_line = function(mode)
	local mode = mode or 0
	-- 0 == from cursor to the end of the line
	-- 1 == from cursor to the beginning of the line
	-- 2 == the whole line
	-- Cursor position does not change!
	write("\027[" .. mode .. "K")
end

local COLORS = {
	black = 30,
	red = 31,
	green = 32,
	yellow = 33,
	blue = 34,
	magenta = 35,
	cyan = 36,
	white = 37,
	reset = 39,
}

local STYLES = {
	reset = 0,
	bold = 1,
	dim = 2,
	italic = 3,
	underlined = 4,
	slow_blink = 5,
	rapid_blink = 6,
	inverted = 7,
	exp = 8,
	double_underlined = 21,
	normal = 22,
	not_italic = 23,
	not_underlined = 24,
	not_blinking = 25,
	not_inverted = 27,
}

local style = function(...)
	local args = { ... }
	local style_ansi = "\27["
	for _, v in ipairs(args) do
		if STYLES[v] then
			style_ansi = style_ansi .. STYLES[v] .. ";"
		end
	end
	if style_ansi == "\27[" then
		style_ansi = ""
	else
		style_ansi = style_ansi:sub(1, -2) .. "m"
	end
	return style_ansi
end

local set_style = function(...)
	local ansi = style(...)
	if ansi ~= "" then
		write(ansi)
	end
end

local color = function(fg, bg)
	local fg_ansi = ""
	local bg_ansi = ""
	if fg then
		if type(fg) == "string" and COLORS[fg] then
			fg_ansi = "\027[" .. COLORS[fg] .. "m"
		elseif type(fg) == "number" then
			fg_ansi = "\027[38;5;" .. fg .. "m"
		else
			fg_ansi = "\027[38;2;" .. fg[1] .. ";" .. fg[2] .. ";" .. fg[3] .. "m"
		end
	end
	if bg then
		if type(bg) == "string" and COLORS[bg] then
			bg_ansi = "\027[" .. COLORS[bg] + 10 .. "m"
		elseif type(bg) == "number" then
			bg_ansi = "\027[48;5;" .. bg .. "m"
		else
			bg_ansi = "\027[48;2;" .. bg[1] .. ";" .. bg[2] .. ";" .. bg[3] .. "m"
		end
	end
	return fg_ansi .. bg_ansi
end

local set_color = function(fg, bg)
	local ansi = color(fg, bg)
	if ansi ~= "" then
		write(ansi)
	end
end

local cursor_position = function()
	write("\027[6n")
	local response = ""

	-- Read ESC
	local c = io.read(1)
	if not c or string.byte(c) ~= 27 then
		return nil
	end

	-- Read [
	c = io.read(1)
	if not c or c ~= "[" then
		return nil
	end

	-- Read until 'R' terminator
	repeat
		c = io.read(1)
		if c and c ~= "R" then
			response = response .. c
		end
	until not c or c == "R"

	if response and c == "R" then
		local line = tonumber(response:match("^(%d+)"))
		local column = tonumber(response:match("^%d+;(%d+)"))
		return line, column
	end
	return nil
end

local title = function(str)
	write("\027]0;" .. str .. string.char(7))
end

local kitty_notify = function(title, body)
	local id = "i=" .. tostring(os.time()) .. ":"
	local start = "\027]99;" .. id
	local ending = "\027\\"
	if title and body then
		local out = start .. "d=0:p=title;" .. title .. ending
		out = out .. start .. "d=1:p=body;" .. body .. ending
		write(out)
	elseif title or body then
		local msg = title or body
		local out = start .. "d=1:p=body;" .. msg .. ending
		write(out)
	end
end

--[[
  Kitty Text Sizing Protocol support
  See: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/

  The text sizing protocol allows rendering text in multiple terminal cells
  by scaling the font size. This is useful for creating visual hierarchy,
  superscripts, subscripts, and other text effects.
]]

-- Preset configurations for common text sizing scenarios
local TS_PRESETS = {
	double = { s = 2, h = 0 },
	triple = { s = 3, h = 0 },
	quadruple = { s = 4, h = 0 },
	superscript = { n = 1, d = 2, v = 0, w = 1 }, -- Half-size, top-aligned, 2 chars/cell
	subscript = { n = 1, d = 2, v = 1, w = 1 }, -- Half-size, bottom-aligned, 2 chars/cell
	half = { n = 1, d = 2, w = 1 }, -- Half-size, 2 chars/cell
	compact = { n = 1, d = 2, v = 2, w = 1 }, -- Half-size, centered, 2 chars/cell
}

-- Generate text sizing escape sequence
-- opts table can contain: s (scale 1-7), w (width 0-7), n (numerator 0-15),
-- d (denominator 0-15), v (vertical align 0-2), h (horizontal align 0-2)
--
-- For fractional scaling with explicit w, text is automatically chunked so that
-- each chunk fits within the specified cell width. Per the Kitty text sizing protocol,
-- fractional scaling does NOT affect the number of cells - only the rendered font size.
-- To fit multiple characters per cell, we emit separate escape sequences for each chunk.
local text_size = function(text, opts)
	if not text or text == "" or not opts then
		return text or ""
	end

	-- Validate parameters and determine if we need fractional chunking
	local scale = nil
	local width = nil
	local numerator = nil
	local denominator = nil
	local v_align = nil
	local h_align = nil

	-- Scale factor (1-7)
	if opts.s and opts.s >= 1 and opts.s <= 7 then
		scale = math.floor(opts.s)
	end

	-- Explicit width (0-7)
	if opts.w and opts.w >= 0 and opts.w <= 7 then
		width = math.floor(opts.w)
	end

	-- Fractional scaling (both must be 0-15, d must be > n when non-zero)
	if opts.n and opts.d and opts.n >= 0 and opts.n <= 15 and opts.d >= 0 and opts.d <= 15 then
		if opts.d > opts.n then
			numerator = math.floor(opts.n)
			denominator = math.floor(opts.d)
		end
	end

	-- Vertical alignment (0-2)
	if opts.v and opts.v >= 0 and opts.v <= 2 then
		v_align = math.floor(opts.v)
	end

	-- Horizontal alignment (0-2)
	if opts.h and opts.h >= 0 and opts.h <= 2 then
		h_align = math.floor(opts.h)
	end

	-- Build base metadata string (without w, which may vary per chunk)
	local base_metadata = {}
	if scale then
		table.insert(base_metadata, "s=" .. scale)
	end
	if numerator and denominator then
		table.insert(base_metadata, "n=" .. numerator)
		table.insert(base_metadata, "d=" .. denominator)
	end
	if v_align then
		table.insert(base_metadata, "v=" .. v_align)
	end
	if h_align then
		table.insert(base_metadata, "h=" .. h_align)
	end

	-- If no valid metadata was generated, return text as-is
	if #base_metadata == 0 and not width then
		return text
	end

	-- Determine if we need to chunk text for fractional scaling
	-- Chunking is needed when: fractional scaling is active AND explicit w is specified
	-- The formula: chars_per_cell = w * d / n (how many characters fit in w cells)
	local needs_chunking = numerator and denominator and width and width > 0 and numerator > 0

	if needs_chunking then
		-- Calculate how many display columns fit per chunk
		-- For n=1, d=2, w=1: target_width = 1 * 2 / 1 = 2 display columns per chunk
		local target_width = math.floor(width * denominator / numerator)
		if target_width < 1 then
			target_width = 1
		end

		-- Build metadata string with w included
		local metadata_with_w = {}
		for _, m in ipairs(base_metadata) do
			table.insert(metadata_with_w, m)
		end
		table.insert(metadata_with_w, "w=" .. width)
		local meta_str = table.concat(metadata_with_w, ":")

		-- Chunk the text based on display width
		local result = {}
		local chunk = ""
		local chunk_width = 0
		local i = 1
		local text_len = std.utf.len(text)

		while i <= text_len do
			local char = std.utf.sub(text, i, i)
			local char_width = std.utf.display_len(char)

			-- Check if adding this character would exceed target width
			if chunk_width + char_width > target_width and chunk ~= "" then
				-- Emit current chunk
				table.insert(result, "\027]66;" .. meta_str .. ";" .. chunk .. "\027\\")
				chunk = ""
				chunk_width = 0
			end

			-- Add character to current chunk
			chunk = chunk .. char
			chunk_width = chunk_width + char_width

			-- If chunk is exactly at target width, emit it
			if chunk_width >= target_width then
				table.insert(result, "\027]66;" .. meta_str .. ";" .. chunk .. "\027\\")
				chunk = ""
				chunk_width = 0
			end

			i = i + 1
		end

		-- Emit any remaining characters in the last chunk
		if chunk ~= "" then
			table.insert(result, "\027]66;" .. meta_str .. ";" .. chunk .. "\027\\")
		end

		return table.concat(result, "")
	else
		-- No chunking needed - emit single escape sequence
		local metadata = {}
		for _, m in ipairs(base_metadata) do
			table.insert(metadata, m)
		end
		if width then
			table.insert(metadata, "w=" .. width)
		end

		if #metadata == 0 then
			return text
		end

		local meta_str = table.concat(metadata, ":")
		return "\027]66;" .. meta_str .. ";" .. text .. "\027\\"
	end
end

--[[
  Calculate text-sizing chunk boundaries without generating escape sequences.

  This is a helper for apply_sized() in TSS, which needs to know where chunks
  break so it can apply inline styles correctly within each chunk.

  Parameters:
    text: plain text (no ANSI codes) to analyze
    opts: text-sizing options table (same format as text_size)

  Returns:
    If chunking is needed: table of {start, stop, meta_str} where start/stop are
      1-based character indices (UTF-8 aware), and meta_str is the OSC 66 metadata
    If no chunking needed: nil, meta_str (single wrap case)
    If no text-sizing: nil, nil
]]
local text_size_chunks = function(text, opts)
	if not text or text == "" or not opts then
		return nil, nil
	end

	-- Validate parameters (same logic as text_size)
	local scale = nil
	local width = nil
	local numerator = nil
	local denominator = nil
	local v_align = nil
	local h_align = nil

	if opts.s and opts.s >= 1 and opts.s <= 7 then
		scale = math.floor(opts.s)
	end

	if opts.w and opts.w >= 0 and opts.w <= 7 then
		width = math.floor(opts.w)
	end

	if opts.n and opts.d and opts.n >= 0 and opts.n <= 15 and opts.d >= 0 and opts.d <= 15 then
		if opts.d > opts.n then
			numerator = math.floor(opts.n)
			denominator = math.floor(opts.d)
		end
	end

	if opts.v and opts.v >= 0 and opts.v <= 2 then
		v_align = math.floor(opts.v)
	end

	if opts.h and opts.h >= 0 and opts.h <= 2 then
		h_align = math.floor(opts.h)
	end

	-- Build metadata string
	local metadata = {}
	if scale then
		table.insert(metadata, "s=" .. scale)
	end
	if numerator and denominator then
		table.insert(metadata, "n=" .. numerator)
		table.insert(metadata, "d=" .. denominator)
	end
	if v_align then
		table.insert(metadata, "v=" .. v_align)
	end
	if h_align then
		table.insert(metadata, "h=" .. h_align)
	end
	if width then
		table.insert(metadata, "w=" .. width)
	end

	if #metadata == 0 then
		return nil, nil
	end

	local meta_str = table.concat(metadata, ":")

	-- Check if chunking is needed
	local needs_chunking = numerator and denominator and width and width > 0 and numerator > 0

	if not needs_chunking then
		return nil, meta_str
	end

	-- Calculate chunk boundaries
	local target_width = math.floor(width * denominator / numerator)
	if target_width < 1 then
		target_width = 1
	end

	local chunks = {}
	local chunk_start = 1
	local chunk_width = 0
	local i = 1
	local text_len = std.utf.len(text)

	while i <= text_len do
		local char = std.utf.sub(text, i, i)
		local char_width = std.utf.display_len(char)

		-- Check if adding this character would exceed target width
		if chunk_width + char_width > target_width and chunk_start <= i - 1 then
			-- Record current chunk
			table.insert(chunks, {
				start = chunk_start,
				stop = i - 1,
				meta_str = meta_str,
			})
			chunk_start = i
			chunk_width = 0
		end

		chunk_width = chunk_width + char_width

		-- If chunk is exactly at target width, finalize it
		if chunk_width >= target_width then
			table.insert(chunks, {
				start = chunk_start,
				stop = i,
				meta_str = meta_str,
			})
			chunk_start = i + 1
			chunk_width = 0
		end

		i = i + 1
	end

	-- Handle any remaining characters
	if chunk_start <= text_len then
		table.insert(chunks, {
			start = chunk_start,
			stop = text_len,
			meta_str = meta_str,
		})
	end

	return chunks, meta_str
end

--[[ 
  We use and support [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
  first and foremost. Legacy protocol will be supported eventually, though.
  `kkbp` in function names stands for Kitty KeyBoard Protocol. ]]

--[[
 `has_kkbp` checks for the kkbp support.

 We issue a request for kkbp enhancement flags status and for
 the primary device attributes. If we get the kkbp response
 first (CSI ? flags u), the protocol is supported. If we get
 the device attributes response first (CSI ? ... c), it's not. ]]
local has_kkbp = function()
	write("\027[?u\027[c")
	local buf = buffer.new()
	local esc_received = false
	local bracket_received = false

	repeat
		local c = io.read(1)
		if c then
			if not esc_received and string.byte(c) == 27 then
				esc_received = true
			elseif esc_received and not bracket_received and c == "[" then
				bracket_received = true
			elseif bracket_received then
				buf:put(c)
			end
		end
	until not c or c == "u" or c == "c"

	local answer = buf:get()
	-- kkbp response format: ? flags u (where flags can be empty or digits)
	-- DA response format: ? number ; number ... c
	if answer:match("^%?%d*u$") then
		return true
	end
	return false
end

--[[
 `has_ts` checks for text sizing protocol support using CPR method.

 IMPORTANT: This function must be called while the terminal is in raw mode.
 It reads terminal responses via io.read() which requires raw mode to work
 correctly. If called in normal (cooked) mode, the function will hang waiting
 for input that never arrives in the expected format.

 Detection mechanism from the spec:
 1. Send CR + CPR + OSC66(w=2) + CPR + OSC66(s=2) + CPR
 2. Wait for three CPR responses
 3. Compare cursor positions:
    - All same: no support
    - 2nd moved 2 cells: width support
    - 3rd moved another 2 cells: full support (scale)

 Returns: false | "width" | true
]]
local has_ts = function()
	-- Save current cursor position
	write("\r") -- Carriage return to start of line
	local l1, c1 = cursor_position()
	if not l1 or not c1 then
		return false
	end

	-- Test width support: send w=2 with a space
	write("\027]66;w=2; \027\\")
	local l2, c2 = cursor_position()

	-- Test scale support: send s=2 with a space
	write("\027]66;s=2; \027\\")
	local l3, c3 = cursor_position()

	-- Clean up: move cursor back to start
	write("\r")

	if not l2 or not c2 or not l3 or not c3 then
		return false
	end

	-- Analyze cursor movements
	local width_support = (c2 - c1) == 2
	local scale_support = (c3 - c2) == 2

	if scale_support then
		return true -- Full text sizing support
	elseif width_support then
		return "width" -- Only width parameter supported
	else
		return false -- No support
	end
end

--[[
 `has_ts_combined` checks how terminals handle combined s+w metadata.

 IMPORTANT: This function must be called while terminal is in raw mode.

 It sends OSC66 with both s and w and inspects cursor advance:
 - 4 cells advance for "s=2:w=2; " => combined semantics (s * w)
 - 2 cells advance => width-only semantics (w)
]]
local has_ts_combined = function()
	write("\r")
	local l1, c1 = cursor_position()
	if not l1 or not c1 then
		return false
	end

	write("\027]66;s=2:w=2; \027\\")
	local l2, c2 = cursor_position()
	write("\r")

	if not l2 or not c2 then
		return false
	end

	return (c2 - c1) == 4
end
--[[
    kkbp has progressive enhancements, which are encoded as a bitfield enum:

     0b1     (1)  Disambiguate escape codes
     0b10    (2)  Report event types
     0b100   (4)  Report alternate keys
     0b1000  (8)  Report all keys as escape codes
     0b10000 (16) Report associated text

    `enable_kkbp` is hardcoded to set progressive enhancements enum to 15,
    and the code in the `term.input` module is based on the assumption that we
    are working in this mode.
]]
local enable_kkbp = function()
	write("\027[>1u")
	write("\027[=15;1u")
	io.flush()
end

local disable_kkbp = function()
	write("\027[<u")
	io.flush()
end

local enable_bracketed_paste = function()
	write("\027[?2004h")
	io.flush()
end

local disable_bracketed_paste = function()
	write("\027[?2004l")
	io.flush()
end

--[[
	Query terminal for pixel dimensions using xterm-style escape sequences.
	CSI 14 t -> returns CSI 4 ; height ; width t (window size in pixels)
	CSI 16 t -> returns CSI 6 ; height ; width t (cell size in pixels)
	Returns: window_width, window_height, cell_width, cell_height (all in pixels)
	Returns nil if query fails or times out.
]]
local get_pixel_dimensions = function(timeout_ms)
	timeout_ms = timeout_ms or 100
	-- Query both window size (14t) and cell size (16t)
	write("\027[14t\027[16t")
	io.flush()

	local buf = buffer.new()
	local win_w, win_h, cell_w, cell_h
	local responses_received = 0
	local start_time = os.clock() * 1000

	while responses_received < 2 do
		-- Check timeout
		if (os.clock() * 1000 - start_time) > timeout_ms then
			break
		end

		local c = io.read(1)
		if c then
			buf:put(c)
			local data = buf:tostring()
			-- Look for complete responses: ESC [ 4 ; h ; w t or ESC [ 6 ; h ; w t
			local response_type, height, width = data:match("\027%[([46]);(%d+);(%d+)t")
			if response_type then
				if response_type == "4" then
					win_h = tonumber(height)
					win_w = tonumber(width)
					responses_received = responses_received + 1
				elseif response_type == "6" then
					cell_h = tonumber(height)
					cell_w = tonumber(width)
					responses_received = responses_received + 1
				end
				-- Clear buffer after successful parse
				buf:reset()
			end
		end
	end

	if win_w and cell_w then
		return win_w, win_h, cell_w, cell_h
	end
	return nil
end

local set_sane_mode = function()
	core.set_sane_mode()
end

local set_raw_mode = function()
	if not core.raw_mode() then
		core.set_raw_mode()
	end
end

local switch_screen = function(scr)
	local scr = scr or "main"
	if scr == "main" then
		io.write("\027[?47l")
	else
		io.write("\027[?47h")
	end
	io.flush()
end

local alt_screen = function()
	set_raw_mode()
	local l, c = cursor_position()
	switch_screen("alt")
	enable_kkbp()
	enable_bracketed_paste()
	hide_cursor()
	return {
		l = l,
		c = c,
		done = function(self)
			disable_bracketed_paste()
			disable_kkbp()
			switch_screen("main")
			go(self.l, self.c)
			show_cursor()
			set_sane_mode()
		end,
	}
end

--[[
 Our terminal input relies on the [Kitty's keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), 
 `kkbp` prefix in variable/function names stands for `Kitty KeyBoard Protocol`. Initially this module
 was built around the legacy input protocol, but it is really not good enough for any serious terminal application,
 and it seemed too much of a hassle to maintain both implementations. Yet it'd be nice to have a minimal implementation
 of the legacy one as a fallback, so there is a chance it will be added in the future...
]]
--

local KKBP_CODES = {
	["57441"] = "LEFT_SHIFT",
	["57442"] = "LEFT_CTRL",
	["57443"] = "LEFT_ALT",
	["57444"] = "LEFT_SUPER",
	["57447"] = "RIGHT_SHIFT",
	["57448"] = "RIGHT_CTRL",
	["57449"] = "RIGHT_ALT",
	["57450"] = "RIGHT_SUPER",
	["57358"] = "CAPS_LOCK",
	["57359"] = "SCROLL_LOCK",
	["57360"] = "NUM_LOCK",
	["57361"] = "PRINT_SCREEN",
	["57362"] = "PAUSE",
	["57363"] = "MENU",
	["57428"] = "MEDIA_PLAY",
	["57429"] = "MEDIA_PAUSE",
	["57430"] = "MEDIA_PLAY_PAUSE",
	["57431"] = "MEDIA_REVERSE",
	["57432"] = "MEDIA_STOP",
	["57433"] = "MEDIA_FAST_FORWARD",
	["57434"] = "MEDIA_REWIND",
	["57435"] = "MEDIA_TRACK_NEXT",
	["57436"] = "MEDIA_TRACK_PREVIOUS",
	["57437"] = "MEDIA_RECORD",
	["57438"] = "VOLUME_DOWN",
	["57439"] = "VOLUME_UP",
	["57440"] = "VOLUME_MUTE",
	["57451"] = "RIGHT_HYPER",
	["57399"] = "KP_0",
	["57400"] = "KP_1",
	["57401"] = "KP_2",
	["57402"] = "KP_3",
	["57403"] = "KP_4",
	["57404"] = "KP_5",
	["57405"] = "KP_6",
	["57406"] = "KP_7",
	["57407"] = "KP_8",
	["57408"] = "KP_9",
	["57409"] = "KP_DECIMAL",
	["57410"] = "KP_DIVIDE",
	["57411"] = "KP_MULTIPLY",
	["57412"] = "KP_SUBTRACT",
	["57413"] = "KP_ADD",
	["57414"] = "KP_ENTER",
	["57415"] = "KP_EQUAL",
	["57416"] = "KP_SEPARATOR",
	["57417"] = "KP_LEFT",
	["57418"] = "KP_RIGHT",
	["57419"] = "KP_UP",
	["57420"] = "KP_DOWN",
	["57421"] = "KP_PAGE_UP",
	["57422"] = "KP_PAGE_DOWN",
	["57423"] = "KP_HOME",
	["57424"] = "KP_END",
	["57425"] = "KP_INSERT",
	["57426"] = "KP_DELETE",
	["D"] = "LEFT",
	["C"] = "RIGHT",
	["A"] = "UP",
	["B"] = "DOWN",
	["H"] = "HOME",
	["F"] = "END",
	["P"] = "F1",
	["Q"] = "F2",
	["R"] = "F3",
	["S"] = "F4",
	["57365"] = "F5",
	["57366"] = "F6",
	["57367"] = "F7",
	["57368"] = "F8",
	["57369"] = "F9",
	["57370"] = "F10",
	["57371"] = "F11",
	["57372"] = "F12",
	["E"] = "KP_BEGIN",
	["9"] = "TAB",
	["13"] = "ENTER",
	["127"] = "BACKSPACE",
	["27"] = "ESC",
}
local KKBP_CODES_LEGACY = {
	["2"] = "INSERT",
	["3"] = "DELETE",
	["5"] = "PAGE_UP",
	["6"] = "PAGE_DOWN",
	["7"] = "HOME",
	["8"] = "END",
	["11"] = "F1",
	["12"] = "F2",
	["13"] = "F3",
	["14"] = "F4",
	["15"] = "F5",
	["17"] = "F6",
	["18"] = "F7",
	["19"] = "F8",
	["20"] = "F9",
	["21"] = "F10",
	["23"] = "F11",
	["24"] = "F12",
}
--[[ We are assuming that every key press is reported
as an escape sequence (PE enum set to 15), which simplifies
parsing a lot. ]]
local get = function()
	local stop_chars = "[ABCDEFHPQSu~]"
	local csi = io.read(1)
	if not csi then
		return nil
	end
	if string.byte(csi) ~= 27 then
		-- With PE flag 15 and bracketed paste mode, this shouldn't happen
		-- for normal input, but handle it gracefully just in case
		return csi
	end
	csi = io.read(1)
	if not csi or csi ~= "[" then
		return nil
	end
	local buf = buffer.new()
	repeat
		local c = io.read(1)
		if c then
			buf:put(c)
		end
	until not c or c:match(stop_chars)
	local seq = buf:get()

	-- Handle bracketed paste mode (ESC[200~ starts paste, ESC[201~ ends it)
	if seq == "200~" then
		local paste_buf = buffer.new()
		local esc_seq = ""
		repeat
			local p = io.read(1)
			if p then
				if string.byte(p) == 27 then
					-- Potential end sequence
					esc_seq = p
					p = io.read(1)
					if p == "[" then
						esc_seq = esc_seq .. p
						-- Read the rest: should be "201~"
						local end_marker = io.read(4) -- "201~"
						if end_marker == "201~" then
							break
						else
							-- False alarm, add to paste buffer
							paste_buf:put(esc_seq .. end_marker)
						end
					else
						paste_buf:put(esc_seq)
						if p then
							paste_buf:put(p)
						end
					end
				else
					paste_buf:put(p)
				end
			end
		until not p
		return paste_buf:get()
	end

	local modifiers = "1"
	local event = "1"
	local codepoint, shifted, base
	-- Let's handle the weird exception (`1;mod:eventCODEPOINT`) fisrt
	if seq:match("^1;") then
		modifiers, event = seq:match("^1;(%d+):([123])")
		if not event then
			modifiers = seq:match("^1;(%d+)")
			event = "1"
		end
		codepoint = seq:match("(%u)$")
	else
		codepoint = seq:match("^[^:;u~]+")
		if seq:match(";") then
			modifiers = seq:match("^[^;]+;(%d+)") or "1"
			event = seq:match("^[^;]+;%d+:([123])") or "1"
		end
	end
	local alternate_block = seq:match("^[^:;]+:([%d:]+)")
	if alternate_block then
		if alternate_block:match("^:") then
			base = alternate_block:match("^:(.*)")
		else
			shifted = alternate_block:match("^(%d+)")
			if alternate_block:match(":") then
				base = alternate_block:match("^[^:]+:(.*)")
			end
		end
	end
	if shifted then
		shifted = std.utf.char(tonumber(shifted))
	end
	if base then
		base = std.utf.char(tonumber(base))
	end
	if seq:match("~") and KKBP_CODES_LEGACY[codepoint] then
		codepoint = KKBP_CODES_LEGACY[codepoint]
	elseif KKBP_CODES[codepoint] then
		codepoint = KKBP_CODES[codepoint]
	else
		local cp = tonumber(codepoint)
		if cp then
			-- kkbp uses Unicode Private Use Area for encoding
			-- non-printable keys, and our kkb_codes mapping does
			-- not include all of them, hence this clause for now.
			if cp >= 57344 and cp <= 63743 then
				codepoint = "TBD"
			else
				codepoint = std.utf.char(cp)
			end
		end
	end
	modifiers = tonumber(modifiers) or 0
	return codepoint, modifiers, tonumber(event), shifted, base
end

local mods_to_string = function(mods)
	local keys = {
		{ 1, "SHIFT" },
		{ 2, "ALT" },
		{ 4, "CTRL" },
		{ 8, "SUPER" },
		{ 16, "HYPER" },
		{ 32, "META" },
		{ 64, "CAPS_LOCK" },
		{ 128, "NUM_LOCK" },
	}
	local combination = {}
	for i = 1, #keys do
		local mask = keys[i][1]
		local name = keys[i][2]
		if bit.band(mods, mask) ~= 0 then
			table.insert(combination, name)
		end
	end
	return table.concat(combination, "+")
end

local string_to_mods = function(combination)
	local keys = {
		SHIFT = 1,
		ALT = 2,
		CTRL = 4,
		SUPER = 8,
		HYPER = 16,
		META = 32,
		CAPS_LOCK = 64,
		NUM_LOCK = 128,
	}
	local byte = 0
	local modifiers = {}
	for modifier in string.gmatch(combination, "%w+") do
		table.insert(modifiers, modifier)
	end
	for _, modifier in ipairs(modifiers) do
		if keys[modifier] then
			byte = bit.bor(byte, keys[modifier])
		end
	end
	return byte
end

local simple_get = function()
	local cp, mods, event, shifted, base = get()
	if not cp then
		return nil
	end
	-- Handle case where get() returns just a character (non-KKBP input)
	if not mods then
		return cp
	end
	-- Ignore key release events (event == 3)
	if event == 3 then
		return nil
	end
	if mods <= 2 and std.utf.len(cp) < 2 then
		if shifted then
			cp = shifted
		end
		return cp
	end
	if base then
		cp = base
	end
	local mod_string = mods_to_string(mods - 1)
	local shortcut = mod_string .. "+"
	if mod_string == "" then
		shortcut = cp
	else
		shortcut = shortcut .. cp
	end
	return shortcut
end

return {
	TS_PRESETS = TS_PRESETS,
	COLORS = COLORS,
	kitty_notify = kitty_notify,
	title = title,
	go = go,
	move = move,
	clear_line = clear_line,
	cursor_position = cursor_position,
	write = write,
	write_at = write_at,
	clear = clear,
	hide_cursor = hide_cursor,
	show_cursor = show_cursor,
	style = style,
	color = color,
	set_style = set_style,
	set_color = set_color,
	set_raw_mode = set_raw_mode,
	set_sane_mode = set_sane_mode,
	is_tty = core.is_tty,
	resized = core.resized,
	raw_mode = core.raw_mode,
	window_size = core.get_window_size,
	get_pixel_dimensions = get_pixel_dimensions,
	switch_screen = switch_screen,
	alt_screen = alt_screen,
	has_kkbp = has_kkbp,
	enable_kkbp = enable_kkbp,
	disable_kkbp = disable_kkbp,
	enable_bracketed_paste = enable_bracketed_paste,
	disable_bracketed_paste = disable_bracketed_paste,
	get = get,
	simple_get = simple_get,
	mods_to_string = mods_to_string,
	string_to_mods = string_to_mods,
	-- Text sizing protocol
	text_size = text_size,
	text_size_chunks = text_size_chunks,
	has_ts = has_ts,
	has_ts_combined = has_ts_combined,
	-- Cancel (SIGINT) API
	install_cancel_handler = core.install_cancel_handler,
	remove_cancel_handler = core.remove_cancel_handler,
	check_cancel = core.check_cancel,
}
