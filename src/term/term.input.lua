-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local style = require("term.tss")
local buffer = require("string.buffer")
local socket = require("socket")

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
	if not csi then
		return nil
	end
	if string.byte(csi) ~= 27 then
		-- Sequence does not start from the ESC,
		-- so it must be paste terminal event
		return csi .. io.read("*a")
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

local simple_get = function()
	local cp, mods, event, shifted, base = get()
	if cp and event ~= 3 then
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
	return nil
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

local input_obj_prompt_len = function(self)
	local len = 0
	local prompt = ""
	if self.prompt and self.prompt.get then
		prompt = self.prompt:get()
		len = std.utf.len(prompt)
	end
	return len, prompt
end

local input_obj_render = function(self)
	return self.buffer
end

local input_obj_display = function(self, redraw_prompt)
	local prompt_len, prompt = self:prompt_len()
	local max = self:max_width()
	if redraw_prompt and prompt_len > 0 then
		term.go(self.__config.l, self.__config.c)
		term.write(prompt)
	end
	term.go(self.__config.l, self.__config.c + prompt_len)
	term.clear_line()
	local display_part = std.utf.sub(self.buffer, self.position, self.position + (max - prompt_len))
	if self.__config.escape_newlines then
		display_part = display_part:gsub("\n", "␊")
	end
	if self.__config.tss then
		term.write(self.__config.tss:apply("input", display_part))
	else
		term.write(display_part)
	end
	if self.cursor > max - prompt_len then
		self.cursor = max - prompt_len
	end
	term.go(self.__config.l, self.__config.c + self.cursor + prompt_len)
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

local input_obj_up = function(self)
	if self.history and self.history:up() then
		if #self.buffer > 0 and self.history.position == #self.history.entries then
			self.history:stash(self.buffer)
		end
		self.buffer = self.history:get()
		self:end_of_line()
	end
	return false
end

local input_obj_down = function(self)
	if self.history and self.history:down() then
		self.buffer = self.history:get()
		self:end_of_line()
		return false
	end
	return self:scroll_completion()
end

local input_obj_left = function(self)
	if self.cursor > 0 then
		if self.completion then
			if self.position + self.cursor - 1 == std.utf.len(self.buffer) then
				term.clear_line()
			end
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
	local max = self:max_width() - self:prompt_len()
	if self.position + self.cursor - 1 < buf_len then
		if self.cursor <= max then
			self.cursor = self.cursor + 1
			term.move("right")
		else
			self.position = self.position + 1
			self:display()
		end
	else
		return self:promote_completion()
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

local input_obj_next_space = function(self)
	local buf_len = std.utf.len(self.buffer)
	local max = self:max_width() - self:prompt_len()
	local cur_pos = self.position + self.cursor
	local cur_char = std.utf.sub(self.buffer, cur_pos, cur_pos + 1)
	if cur_char:match("%s") then
		cur_pos = cur_pos + 1
	end
	local pos = self.buffer:find("%s", cur_pos) or 0
	if pos > 0 and pos > cur_pos then
		if pos < max then
			self.cursor = self.cursor + (pos - cur_pos) + 1
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
	local max = self:max_width() - self:prompt_len()
	self.position = 1
	self.cursor = buf_len
	if buf_len > max then
		self.cursor = max
		self.position = buf_len - max
	end
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
		if self.completion then
			term.clear_line()
		end
		self.buffer = std.utf.sub(self.buffer, 1, buf_len - 1)
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
	local prompt_len = 0
	if self.prompt then
		prompt_len = std.utf.len(self.prompt:get())
	end
	local max = self:max_width() - prompt_len
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
		if self.cursor < max then
			self.cursor = self.cursor + 1
			if key == "\n" and self.__config.escape_newlines then
				key = "␊"
			end
			local compl = ""
			self.buffer = self.buffer .. key
			if self.completion then
				term.clear_line()
				if key ~= " " and self.completion:search(self:render(), self.history) then
					compl = self.completion:get()
				end
			end
			if self.__config.tss then
				term.write(self.__config.tss:apply("input", key) .. compl)
			else
				term.write(key .. compl)
			end
			if #compl > 0 then
				term.go(self.__config.l, self.__config.c + self.cursor + prompt_len)
			end
		else
			self.buffer = self.buffer .. key
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
	local stdin = std.ps.pipe()
	local stdout = std.ps.pipe()
	stdin:write(self:render())
	stdin:close_inn()
	local pid = std.ps.launch(editor, stdin.out, stdout.inn, nil, "-")
	local _, status = std.ps.wait(pid)
	stdin:close_out()
	stdout:close_inn()
	local result = stdout:read() or "can't get editor output"
	stdout:close_out()
	self.buffer = result
	self:end_of_line()
	self:display()
end

local input_obj_tab = function(self)
	if self.completion and self.completion:available() then
		if #self.completion.__candidates == 1 then
			return self:promote_completion()
		end
		if self.__tab.long then
			return self:scroll_completion()
		end
		return self:promote_completion()
	end
end

local scroll_completion = function(self, direction)
	local direction = direction or "down"

	if self.completion then
		local prompt_len = 0
		if self.prompt then
			prompt_len = std.utf.len(self.prompt:get())
		end
		if self.completion:available() then
			term.clear_line()
			local total = #self.completion.__candidates
			if direction == "down" then
				self.completion.__chosen = self.completion.__chosen + 1
				if self.completion.__chosen > total then
					self.completion.__chosen = 1
				end
			else
				self.completion.__chosen = self.completion.__chosen - 1
				if self.completion.__chosen < 1 then
					self.completion.__chosen = total
				end
			end
			term.write(self.completion:get())
			term.go(self.__config.l, self.__config.c + self.cursor + prompt_len)
		end
	end
end

local promote_completion = function(self)
	if self.completion then
		local prompt_len = 0
		if self.prompt then
			prompt_len = std.utf.len(self.prompt:get())
		end
		if self.completion:available() then
			term.clear_line()
			local promoted = self.completion:get(true)
			local metadata = self.completion.__meta[self.completion.__chosen]
			if metadata.replace_prompt then
				if metadata.trim_promotion then
					promoted = promoted:gsub("^%s+", "")
				end
				self.buffer = metadata.replace_prompt .. promoted
			else
				self.buffer = self.buffer .. promoted
			end
			self.completion:flush()
			self:end_of_line()
			if metadata.exec_on_prom then
				return self:execute()
			end
		end
	end
end

local input_obj_newline = function(self)
	self:add("\n")
end

local input_obj_execute = function(self)
	if self.completion and self.completion:available() then
		local metadata = self.completion.__meta[self.completion.__chosen]
		if metadata and metadata.exec_on_prom then
			return self:promote_completion()
		end
	end
	if self.buffer == "" then
		self.__config.l = self.__config.l + 1
		if self.__config.l > self.__window.h then
			self.__config.l = self.__window.h
		end
		return self:display(true)
	end
	io.read("*a")
	return "execute"
end

local input_obj_escape = function(self)
	if self.buffer == "" then
		return "exit"
	end
	return self:scroll_completion("up")
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
	if cp and cp == "TAB" then
		if not self.__tab.start and event == 1 then
			self.__tab.start = socket.gettime()
			return nil
		end
		if event == 2 then
			return nil
		end
		if event == 3 then
			local now = socket.gettime()
			self.__tab.long = false
			if self.__tab.start then
				if now - self.__tab.start > self.__tab.quick_press then
					self.__tab.long = true
				end
			end
			self.__tab.start = nil
			if self.__tab.last_release then
				if now - self.__tab.last_release <= self.__tab.quick_press * 2 then
					self.__tab.double_tap = true
				else
					self.__tab.double_tap = false
				end
			end
			self.__tab.last_release = now
		end
		event = 1
	end
	if cp and not mods and not event then
		self.buffer = self.buffer .. cp
		return self:end_of_line()
	end
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
		return "combo", shortcut
	end
	return nil
end

local input_obj_resize = function(self)
	local win_l, win_c = term.window_size()
	if win_c ~= self.__window.w then
		self.__window = { h = win_l, w = win_c }
		self.__config.max_width = win_c - 1
		return true
	end
	return false
end

local input_obj_run = function(self, exit_events)
	local exit_events = exit_events or { execute = true, exit = true }
	local event, combo
	repeat
		if term.resized() then
			if self:resize() then
				term.clear_line(2)
				self:display(true)
			end
		end
		event, combo = self:event()
	until exit_events[event]
	return event, combo
end

local new_input_obj = function(config)
	local win_l, win_c = term.window_size()
	local default_config = {
		l = 1,
		c = 1,
		escape_newlines = true,
		max_width = win_c - 1,
		width = win_c - 1,
	}
	local config = std.tbl.merge(default_config, config)
	if config.rss then
		local tss = style.new(config.rss)
		config.tss = tss
		config.rss = nil
	end
	local input_obj = {
		-- DATA
		__window = { h = win_l, w = win_c },
		__config = config,
		__tab = { quick_press = tonumber(os.getenv("LILUSH_QUICK_PRESS")) or 0.093 },
		buffer = "",
		cursor = 0,
		position = 1,
		-- History, Completion & Prompt objects (can be nils)
		history = config.history,
		completion = config.completion,
		prompt = config.prompt,
		-- METHODS
		add = input_obj_add,
		left = input_obj_left,
		right = input_obj_right,
		up = input_obj_up,
		down = input_obj_down,
		backspace = input_obj_backspace,
		display = input_obj_display,
		render = input_obj_render,
		flush = input_obj_flush,
		resize = input_obj_resize,
		event = input_obj_event,
		esc = input_obj_escape,
		tab = input_obj_tab,
		scroll_completion = scroll_completion,
		promote_completion = promote_completion,
		newline = input_obj_newline,
		end_of_line = input_obj_end_of_line,
		start_of_line = input_obj_start_of_line,
		previous_space = input_obj_previous_space,
		next_space = input_obj_next_space,
		execute = input_obj_execute,
		run = input_obj_run,
		clear = input_obj_clear,
		max_width = input_obj_max_width,
		prompt_len = input_obj_prompt_len,
		map_ctrl = input_obj_map_ctrl,
		external_editor = input_obj_external_editor,
	}
	-- keeping it this way for now, hopefully
	-- will be easier to use with custom shortcuts overrides
	-- later on...
	local ctrls = {
		backspace = { "BACKSPACE" },
		esc = { "ESC" },
		left = { "LEFT" },
		right = { "RIGHT" },
		up = { "UP" },
		down = { "DOWN" },
		tab = { "TAB" },
		execute = { "ENTER" },
		end_of_line = { "END", "CTRL+e" },
		start_of_line = { "HOME", "CTRL+a" },
		previous_space = { "CTRL+b", "CTRL+LEFT" },
		next_space = { "CTRL+w", "CTRL+RIGHT" },
		newline = { "SHIFT+ENTER" },
		external_editor = { "ALT+ENTER" },
		clear = { "CTRL+u" },
	}
	input_obj.__ctrls = ctrls
	input_obj:resize()
	return input_obj
end

local _M = {
	mods_to_string = mods_to_string,
	string_to_mods = string_to_mods,
	get = get,
	simple_get = simple_get,
	new = new_input_obj,
}

return _M
