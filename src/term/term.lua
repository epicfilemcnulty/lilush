-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local core = require("term.core")
local buffer = require("string.buffer")

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

local movements = {
	up = "\027[{count}A",
	down = "\027[{count}B",
	right = "\027[{count}C",
	left = "\027[{count}D",
	line_down = "\027[{count}E",
	line_up = "\027[{count}F",
	column = "\027[{count}G",
}

local move = function(direction, count)
	if movements[direction] then
		local count = count or 1
		local move = movements[direction]:gsub("{count}", count)
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

local colors = {
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

local styles = {
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
		if styles[v] then
			style_ansi = style_ansi .. styles[v] .. ";"
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
		if type(fg) == "string" and colors[fg] then
			fg_ansi = "\027[" .. colors[fg] .. "m"
		elseif type(fg) == "number" then
			fg_ansi = "\027[38;5;" .. fg .. "m"
		else
			fg_ansi = "\027[38;2;" .. fg[1] .. ";" .. fg[2] .. ";" .. fg[3] .. "m"
		end
	end
	if bg then
		if type(bg) == "string" and colors[bg] then
			bg_ansi = "\027[" .. colors[bg] + 10 .. "m"
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
	repeat
		local r = io.read(1)
		if r then
			if r ~= "\027" and r ~= "[" then
				response = response .. r
			end
		end
	until r == nil
	if response then
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
  We use and support [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
  first and foremost. Legacy protocol will be supported eventually, though.
  `kkbp` in function names stands for Kitty KeyBoard Protocol. ]]

--[[
 `has_kkbp` checks for the kkbp support.
 
 We issue a request for kkbp enhancement flags status and for
 the primary device attributes. If we get the kkbp response
 first (which ends with `u`), the protocol is supported. ]]
local has_kkbp = function()
	write("\027[?u\027[c")
	local buf = buffer.new()
	repeat
		local c = io.read(1)
		if c then
			buf:put(c)
		end
	until not c or c == "u"
	local answer = buf:get()
	if answer:match("u$") then
		return true
	end
	return false
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

local set_sane_mode = function()
	core.set_sane_mode()
end

local set_raw_mode = function()
	--if not core.raw_mode() then
	core.set_raw_mode()
	--end
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
	hide_cursor()
	return {
		l = l,
		c = c,
		done = function(self)
			disable_kkbp()
			switch_screen("main")
			go(self.l, self.c)
			show_cursor()
			set_sane_mode()
		end,
	}
end

local _M = {
	kitty_notify = kitty_notify,
	title = title,
	colors = colors,
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
	switch_screen = switch_screen,
	alt_screen = alt_screen,
	has_kkbp = has_kkbp,
	enable_kkbp = enable_kkbp,
	disable_kkbp = disable_kkbp,
}

return _M
