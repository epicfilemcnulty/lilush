-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local buffer = require("string.buffer")

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
	term.set_raw_mode()
	term.write("\027[?u\027[c")
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

     0b1 (1)  Disambiguate escape codes
     0b10 (2) Report event types
     0b100 (4) Report alternate keys
     0b1000 (8) Report all keys as escape codes
     0b10000 (16) Report associated text

    `enable_kkbp` is hardcoded to set progressive enhancements enum to 15,
    and the code in the `get` function is based on the assumption that we
    are working in this mode.
]]
local enable_kkbp = function()
	term.write("\027[>1u")
	term.write("\027[=15;1u")
end

local disable_kkbp = function()
	term.write("\027[<u")
end

local kkbp_codes = {
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
	["D"] = "LEFT",
	["C"] = "RIGHT",
	["A"] = "UP",
	["B"] = "DOWN",
	["H"] = "HOME",
	["F"] = "END",
	["P"] = "F1",
	["Q"] = "F2",
	["S"] = "F4",
	["E"] = "KP_BEGIN",
	["9"] = "TAB",
	["13"] = "ENTER",
	["127"] = "BACKSPACE",
	["27"] = "ESC",
}
local kkbp_codes_legacy = {
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
	if not csi or string.byte(csi) ~= 27 then
		return nil
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
	if seq:match("~") and kkbp_codes_legacy[codepoint] then
		codepoint = kkbp_codes_legacy[codepoint]
	elseif kkbp_codes[codepoint] then
		codepoint = kkbp_codes[codepoint]
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
	return codepoint, tonumber(modifiers), tonumber(event), shifted, base
end

-- kkbp modifiers are encoded as a bitfield enum,
-- but sometimes we need to display the human friendly
-- representation of the value, so we have `mods_to_string`
-- and `string_to_mods` below
local mods_to_string = function(mods)
	local keys = {
		[1] = "SHIFT",
		[2] = "ALT",
		[4] = "CTRL",
		[8] = "SUPER",
		[16] = "HYPER",
		[32] = "META",
		[64] = "CAPS_LOCK",
		[128] = "NUM_LOCK",
	}
	local combination = {}
	for key, value in pairs(keys) do
		if bit.band(mods, key) ~= 0 then
			table.insert(combination, value)
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

--[[
    Input Object functions & methods.
    For the object definition see `new_input_obj` function below.
]]

local input_obj_max_width = function(self)
	local max = self.__config.width
	if self.__window.w - self.__config.c < max then
		max = self.__window.w - self.__config.c
	end
	return max
end

local input_obj_render = function(self)
	return self.buffer
end

local input_obj_display = function(self)
	local max = self:max_width()
	term.go(self.__config.l, self.__config.c)
	term.write(string.rep(" ", max + 1))
	term.go(self.__config.l, self.__config.c)
	local display_part = std.utf.sub(self.buffer, self.position, self.position + max)
	if self.__config.escape_newlines then
		display_part = display_part:gsub("\n", "␊")
	end
	term.write(display_part)
	term.go(self.__config.l, self.__config.c + self.cursor)
end

local input_obj_flush = function(self)
	if self.history then
		self.history:add(self:render())
	end
	if self.completions then
		self.completions:flush()
	end
	self.buffer = ""
	self.position = 1
	self.cursor = 0
end

local input_obj_left = function(self)
	if self.cursor > 0 then
		if self.completions then
			self.completions:clear()
		end
		self.cursor = self.cursor - 1
		term.move("left")
	elseif self.position > 1 then
		self.position = self.position - 1
		self:display()
	end
	return nil
end

local input_obj_right = function(self)
	local buf_len = std.utf.len(self.buffer)
	local max = self:max_width()
	if self.position + self.cursor - 1 < buf_len then
		if self.cursor <= max then
			self.cursor = self.cursor + 1
			term.move("right")
		else
			self.position = self.position + 1
			self:display()
		end
	end
	return nil
end

local input_obj_previous_space = function(self)
	local cur_pos = self.position + self.cursor - 1
	local till_cursor = std.utf.sub(self.buffer, 1, cur_pos)
	local pos = till_cursor:find("%s%S-$") or 0
	if pos > 0 then
		local offset = cur_pos - pos
		if offset <= self.cursor then
			self.cursor = self.cursor - offset - 1
			return self:display()
		end
		self.position = pos
		self.cursor = 0
		return self:display()
	end
	return false
end

local input_obj_end_of_line = function(self)
	local buf_len = std.utf.len(self.buffer)
	local max = self:max_width()
	if buf_len <= max then
		self.cursor = buf_len
		term.go(self.__config.l, self.__config.c + self.cursor)
		return false
	end
	self.position = buf_len - max
	self.cursor = max
	self:display()
end

local input_obj_start_of_line = function(self)
	if self.cursor > 1 then
		self.position = 1
		self.cursor = 0
		self:display()
	end
end

local input_obj_backspace = function(self)
	local buf_len = std.utf.len(self.buffer)
	if buf_len == 0 then
		return false
	end
	local max = self:max_width()
	if self.cursor == 0 then
		if self.position > 1 then
			self.buffer = std.utf.sub(self.buffer, 1, self.position - 1) .. std.utf.sub(self.buffer, self.position + 1)
			self.position = self.position - 1
			self:display()
		end
		return false
	end
	if self.position + self.cursor - 1 == buf_len then
		self.buffer = std.utf.sub(self.buffer, 1, std.utf.len(self.buffer) - 1)
		term.write("\b \b")
		self.cursor = self.cursor - 1
		return false
	end
	self.buffer = std.utf.sub(self.buffer, 1, self.position + self.cursor - 2)
		.. std.utf.sub(self.buffer, self.position + self.cursor)
	self.cursor = self.cursor - 1
	self:display()
	return false
end

local input_obj_add = function(self, key)
	local buf_len = std.utf.len(self.buffer)
	local max = self:max_width()
	if self.cursor == 0 then
		if self.position == 1 then
			self.buffer = key .. self.buffer
		else
			self.buffer = std.utf.sub(self.buffer, 1, self.position)
				.. key
				.. std.utf.sub(self.buffer, self.position + 1)
		end
		self.cursor = 1
		self:display()
		return false
	end
	if buf_len == self.position + self.cursor - 1 then
		self.buffer = self.buffer .. key
		if self.cursor < max then
			self.cursor = self.cursor + 1
			if key == "\n" and self.__config.escape_newlines then
				key = "␊"
			end
			term.write(key)
		else
			self.position = self.position + 1
			self:display()
		end
		return false
	end
	self.buffer = std.utf.sub(self.buffer, 1, self.position + self.cursor - 1)
		.. key
		.. std.utf.sub(self.buffer, self.position + self.cursor)
	if self.cursor < max then
		self.cursor = self.cursor + 1
	end
	self:display()
	return false
end

local input_obj_external_editor = function(self)
	local editor = os.getenv("EDITOR") or "vi"
	local stdin = std.pipe()
	local stdout = std.pipe()
	stdin:write(self:render())
	stdin:close_inn()
	local pid = std.launch(editor, stdin.out, stdout.inn, nil, "-")
	local _, status = std.wait(pid)
	stdin:close_out()
	stdout:close_inn()
	local result = stdout:read() or "can't get editor output"
	stdout:close_out()
	self.buffer = result
	self:end_of_line()
	-- Ugly, cause we might end up calling display twice...
	self:display()
end

local input_obj_newline = function(self)
	self:add("\n")
end

local input_obj_execute = function(self)
	return "execute"
end

local input_obj_exit = function(self)
	return "exit"
end

local input_obj_clear = function(self)
	self:flush()
	self:display()
end

local input_obj_map_ctrl = function(self, ctrl)
	for action, shortcuts in pairs(self.__ctrls) do
		for _, shortcut in ipairs(shortcuts) do
			if shortcut == ctrl then
				return action
			end
		end
	end
	return nil
end

local input_obj_event = function(self)
	local cp, mods, event, shifted, base = get()
	if cp and event ~= 3 then
		if mods <= 2 and std.utf.len(cp) < 2 then
			if shifted then
				cp = shifted
			end
			return self:add(cp)
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
		local action = self:map_ctrl(shortcut)
		if action then
			return self[action](self)
		end
	end
	return nil
end

local new_input_obj = function(config)
	local win_l, win_c = term.window_size()
	local default_config = {
		l = 1,
		c = 1,
		escape_newlines = true,
		width = win_c - 1,
	}
	local config = std.merge_tables(default_config, config)
	local input_obj = {
		-- DATA
		__window = { h = win_l, w = win_c },
		__config = config,
		buffer = "",
		cursor = 0,
		position = 1,
		history = config.history,
		completions = config.completions,
		-- METHODS
		add = input_obj_add,
		left = input_obj_left,
		right = input_obj_right,
		backspace = input_obj_backspace,
		display = input_obj_display,
		render = input_obj_render,
		flush = input_obj_flush,
		event = input_obj_event,
		exit = input_obj_exit,
		newline = input_obj_newline,
		end_of_line = input_obj_end_of_line,
		start_of_line = input_obj_start_of_line,
		previous_space = input_obj_previous_space,
		execute = input_obj_execute,
		clear = input_obj_clear,
		max_width = input_obj_max_width,
		map_ctrl = input_obj_map_ctrl,
		external_editor = input_obj_external_editor,
	}
	-- keeping it this way for now, hopefully
	-- will be easier to use with custom shortcuts overrides
	-- later on...
	local ctrls = {
		backspace = { "BACKSPACE" },
		exit = { "ESC" },
		left = { "LEFT" },
		right = { "RIGHT" },
		execute = { "ENTER" },
		end_of_line = { "END", "CTRL+e" },
		start_of_line = { "HOME", "CTRL+a" },
		previous_space = { "CTRL+b", "CTRL+LEFT" },
		newline = { "SHIFT+ENTER" },
		external_editor = { "ALT+ENTER" },
		clear = { "CTRL+c" },
	}
	input_obj.__ctrls = ctrls
	term.go(config.l, config.c)
	return input_obj
end

local _M = {
	enable_kkbp = enable_kkbp,
	disable_kkbp = disable_kkbp,
	has_kkbp = has_kkbp,
	mods_to_string = mods_to_string,
	string_to_mods = string_to_mods,
	get = get,
	new = new_input_obj,
}

return _M
