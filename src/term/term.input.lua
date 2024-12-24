-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local style = require("term.tss")
local state = require("term.input.state")
local view = require("term.input.view")
local buffer = require("string.buffer")
local socket = require("socket")

--[[
 Our terminal input relies on the [Kitty's keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), 
 `kkbp` prefix in variable/function names stands for `Kitty KeyBoard Protocol`. Initially this module
 was built around the legacy input protocol, but it is really not good enough for any serious terminal application,
 and it seemed too much of a hassle to maintain both implementations. Yet it'd be nice to have a minimal implementation
 of the legacy one as a fallback, so there is a chance it will be added in the future...
]]
--

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
		-- so it must be "paste" terminal event
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
	modifiers = tonumber(modifiers) or 0
	return codepoint, modifiers, tonumber(event), shifted, base
end

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
]]
local new = function(config)
	local win_l, win_c = term.window_size()
	local default_config = {
		l = 1,
		c = 1,
		escape_newlines = true,
		width = win_c - 1,
		win_w = win_c,
		win_h = win_l,
		tab_timing = tonumber(os.getenv("LILUSH_QUICK_PRESS")) or 0.093,
	}
	config = std.tbl.merge(default_config, config)

	if config.rss then
		config.tss = style.new(config.rss)
		config.rss = nil
	end

	local s = state.new(config)
	local v = view.new(s)

	local input = {
		state = s,
		view = v,
		tab_state = {
			start = nil,
			last_release = nil,
			long = false,
			double_tap = false,
		},

		handle_tab_state = function(self, event)
			if event == 1 then
				if not self.tab_state.start then
					self.tab_state.start = socket.gettime()
				end
				return nil
			elseif event == 2 then
				return nil
			elseif event == 3 then
				local now = socket.gettime()
				self.tab_state.long = false

				if self.tab_state.start then
					if now - self.tab_state.start > config.tab_timing then
						self.tab_state.long = true
					end
				end

				self.tab_state.start = nil

				if self.tab_state.last_release then
					self.tab_state.double_tap = (now - self.tab_state.last_release <= config.tab_timing * 2)
				end

				self.tab_state.last_release = now
				return self.tab_state.long
			end
			return nil
		end,

		event = function(self)
			local key, mods, event, shifted, base = get()
			if not key then
				return nil
			end

			if key == "TAB" then
				local long_tab = self:handle_tab_state(event)
				if event == 3 then -- Only process TAB on key release
					self.state.tab_long = long_tab
					return self.state:handle_ctl(key)
				end
				return nil
			end

			-- This must be a clipboard paste...
			if key and not mods and not event then
				-- TODO: We need to replace this with something better,
				-- reading clipboard one char at a time does not seem to be an efficient way...
				for utf_char in key:gmatch(std.utf.patterns.glob) do
					self.state:insert(utf_char)
					self.view:display()
				end
				return nil
			end

			-- Just ignore key releases
			if event == 3 then
				return nil
			end

			-- Handle regular keys
			if mods <= 2 and std.utf.len(key) < 2 then
				if shifted then
					return self.state:insert(shifted)
				end
				return self.state:insert(key)
			end

			-- Handle the controls
			if base then
				key = base
			end
			local mod_string = mods_to_string(mods - 1)
			local shortcut = key
			if mod_string ~= "" then
				shortcut = mod_string .. "+" .. key
			end

			return self.state:handle_ctl(shortcut)
		end,

		run = function(self, exit_events)
			local exit_events = exit_events or { execute = true, exit = true }
			local event, combo
			repeat
				if term.resized() then
					local new_h, new_w = term.window_size()
					if new_h ~= self.state.window.h or new_w ~= self.state.window.w then
						self.state:update_window_size(new_h, new_w)
						self.view:display(true)
					end
				end
				event, combo = self:event()
				if
					event
					and (
						not exit_events[event]
						or (self.state.last_op.type == state.OP.COMPLETION_PROMOTION and event == "execute")
					)
				then
					self.view:display()
				end
			until exit_events[event]
			return event, combo
		end,

		get_content = function(self)
			return self.state:get_content()
		end,

		render = function(self)
			return self.state:get_content()
		end,

		display = function(self, full_redraw)
			self.view:display(full_redraw)
		end,

		prompt_set = function(self, options)
			if self.state.prompt then
				self.state.prompt:set(options)
			end
		end,

		prompt_get = function(self)
			if self.state.prompt then
				return self.state.prompt:get()
			end
			return ""
		end,

		set_position = function(self, l, c)
			return self.state:set_position(l, c)
		end,

		flush = function(self)
			self.state.buffer = ""
			self.state.cursor = 0
			self.state.position = 1
			if self.state.completion then
				self.state.completion:flush()
			end
		end,
	}
	return input
end

return {
	get = get,
	simple_get = simple_get,
	mods_to_string = mods_to_string,
	string_to_mods = string_to_mods,
	new = new,
}
