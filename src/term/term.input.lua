-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local style = require("term.tss")
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

-- Enum for operation types (previously in separate state file)
local OP = {
	NONE = 0,
	INSERT = 1,
	DELETE = 2,
	CURSOR_MOVE = 3,
	POSITION_CHANGE = 4,
	HISTORY_SCROLL = 5,
	COMPLETION_SCROLL = 6,
	COMPLETION_PROMOTION = 7,
	COMPLETION_PROMOTION_FULL = 8,
	FULL_CHANGE = 9,
}

--[[
    Input Object functions & methods.
]]
local default_rss = {
	input = {
		fg = 253,
		s = "normal",
		blank = { w = 1 },
	},
	completion = {
		fg = 247,
	},
}

local new = function(config)
	local win_l, win_c = term.window_size()
	local default_config = {
		l = 1,
		c = 1,
		escape_newlines = true,
		width = win_c - 1,
		win_w = win_c,
		win_h = win_l,
		tss = style.merge(default_rss, config.rss),
		blank = " ",
		tab_timing = tonumber(os.getenv("LILUSH_QUICK_PRESS")) or 0.093,
	}
	config = std.tbl.merge(default_config, config)
	config.rss = nil

	local input = {
		-- State fields (previously in separate state object)
		buffer = "",
		cursor = 0,
		position = 1,
		completion = config.completion,
		history = config.history,
		prompt = config.prompt,
		window = { w = config.win_w, h = config.win_h },
		config = config,
		tab_long = false,
		-- Last operation tracking
		last_op = {
			type = OP.NONE,
			position = 0,
		},
		-- Tab state
		tab_state = {
			start = nil,
			last_release = nil,
			long = false,
			double_tap = false,
		},

		-- State methods (previously in separate state object)
		prompt_len = function(self)
			local len = 0
			local prompt = ""
			if self.prompt then
				prompt = self.prompt:get() or ""
				len = std.utf.len(prompt)
			end
			return len, prompt
		end,

		max_visible_width = function(self)
			local prompt_len = self:prompt_len()
			local available_width = self.window.w - self.config.c - prompt_len
			local max = math.min(self.config.width or self.window.w, available_width)
			return max
		end,

		update_window_size = function(self, new_h, new_w)
			self.window.h = new_h
			self.window.w = new_w

			-- Adjust visible width if needed
			if self.config.width then
				self.config.width = math.min(new_w - 1, self.config.width)
			end

			-- Ensure cursor position is valid
			local max_visible = self:max_visible_width()
			if self.cursor > max_visible then
				self.cursor = max_visible
				local content_length = std.utf.len(self.buffer)
				if content_length > max_visible then
					self.position = math.max(1, content_length - max_visible + 1)
				end
			end
		end,

		update_cursor = function(self, new_cursor)
			if new_cursor == self.cursor then
				return false
			end
			local max_width = self:max_visible_width()
			local buf_len = std.utf.len(self.buffer)

			if new_cursor > buf_len then
				new_cursor = buf_len
			end

			local op = { type = OP.CURSOR_MOVE }
			-- Adjust position if cursor would go beyond visible area
			if new_cursor > max_width then
				self.position = self.position + (new_cursor - max_width)
				self.cursor = max_width
				op.type = OP.POSITION_CHANGE
			elseif new_cursor < 0 then
				if self.position > 1 then
					op.type = OP.POSITION_CHANGE
					self.position = self.position + new_cursor
					if self.position < 1 then
						self.position = 1
					end
				end
				self.cursor = 0
			else
				self.cursor = new_cursor
			end
			return op
		end,

		set_position = function(self, l, c)
			if l then
				self.config.l = l
			end
			if c then
				self.config.c = c
			end
		end,

		get_content = function(self)
			return self.buffer
		end,

		insert = function(self, char)
			local buf_len = std.utf.len(self.buffer)
			local insert_pos = self.position + self.cursor - 1

			local op = { type = OP.INSERT, position = insert_pos + 1 }
			self.last_op = op
			if self.cursor == 0 then
				if self.position == 1 then
					self.buffer = char .. self.buffer
				else
					self.buffer = std.utf.sub(self.buffer, 1, self.position)
						.. char
						.. std.utf.sub(self.buffer, self.position + 1)
				end
				self.cursor = 1
				return true
			end

			if buf_len == insert_pos then
				self.buffer = self.buffer .. char
				local cursor_op = self:update_cursor(self.cursor + 1)
				-- if it's a cursor move, we change the op to the insert,
				-- but if it's a position change, we just pass it through
				if cursor_op.type ~= OP.CURSOR_MOVE then
					self.last_op = cursor_op
				end
				return true
			end

			self.buffer = std.utf.sub(self.buffer, 1, insert_pos) .. char .. std.utf.sub(self.buffer, insert_pos + 1)
			local cursor_op = self:update_cursor(self.cursor + 1)
			if cursor_op.type ~= OP.CURSOR_MOVE then
				self.last_op = cursor_op
			end
			return true
		end,

		backspace = function(self)
			local buf_len = std.utf.len(self.buffer)
			if buf_len == 0 then
				return false
			end

			local delete_pos = self.position + self.cursor - 1
			if self.cursor == 0 and self.position == 1 then
				return false
			end

			local op = { type = OP.DELETE, position = delete_pos, line = self.last_op.line }
			self.last_op = op

			if self.cursor == 0 then
				if self.position > 1 then
					-- Move position back and delete from there
					self.position = self.position - 1
					delete_pos = self.position
					self.buffer = std.utf.sub(self.buffer, 1, delete_pos - 1)
						.. std.utf.sub(self.buffer, delete_pos + 1)
					self.last_op.type = OP.POSITION_CHANGE
					return true
				end
				return false
			end

			if delete_pos == buf_len then
				self.buffer = std.utf.sub(self.buffer, 1, buf_len - 1)
				local cursor_op = self:update_cursor(self.cursor - 1)
				if cursor_op.type ~= OP.CURSOR_MOVE then
					self.last_op = cursor_op
				end
				return true
			end

			self.buffer = std.utf.sub(self.buffer, 1, delete_pos - 1) .. std.utf.sub(self.buffer, delete_pos + 1)
			local cursor_op = self:update_cursor(self.cursor - 1)
			if cursor_op.type ~= OP.CURSOR_MOVE then
				self.last_op = cursor_op
			end
			return true
		end,

		move_left = function(self)
			if self.cursor > 0 or self.position > 1 then
				self.last_op = self:update_cursor(self.cursor - 1)
				return true
			end
			return false
		end,

		move_right = function(self)
			self.last_op = self:update_cursor(self.cursor + 1)
			return true
		end,

		end_of_line = function(self)
			local buf_len = std.utf.len(self.buffer)
			if self.position + self.cursor - 1 < buf_len then
				self.last_op = self:update_cursor(buf_len)
				return true
			end
			return false
		end,

		start_of_line = function(self)
			if self.cursor > 0 or self.position > 1 then
				self.last_op = self:update_cursor(-std.utf.len(self.buffer))
				return true
			end
			return false
		end,

		history_up = function(self)
			if not self.history then
				return false
			end

			if self.history:up() then
				local op = { type = OP.HISTORY_SCROLL, line = self.last_op.line, len = std.utf.len(self.buffer) }
				if #self.buffer > 0 and self.history.position == #self.history.entries then
					self.history:stash(self.buffer)
				end
				self.buffer = self.history:get()
				self.cursor = 0
				self.position = 1
				self.last_op = op
				return true
			end
			return false
		end,

		history_down = function(self)
			if not self.history then
				return false
			end

			if self.history:down() then
				local op = { type = OP.HISTORY_SCROLL, line = self.last_op.line, len = std.utf.len(self.buffer) }
				self.buffer = self.history:get()
				self.cursor = 0
				self.position = 1
				self.last_op = op
				return true
			end
			return self:scroll_completion()
		end,

		add_to_history = function(self)
			if self.history and #self.buffer > 0 then
				self.history:add(self.buffer)
			end
		end,

		scroll_completion = function(self, direction)
			if not self.completion or not self.completion:available() then
				return false
			end

			local op = { type = OP.COMPLETION_SCROLL, line = self.last_op.line, completion = self.completion:get() }
			direction = direction or "down"
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
			self.last_op = op
			return true
		end,

		promote_completion = function(self)
			if not self.completion or not self.completion:available() then
				return false
			end

			local promoted = self.completion:get(true)
			local metadata = self.completion.__meta[self.completion.__chosen]

			local op = { type = OP.COMPLETION_PROMOTION, line = self.last_op.line, completion = self.completion:get() }
			if metadata.replace_prompt then
				if metadata.trim_promotion then
					promoted = promoted:gsub("^%s+", "")
				elseif metadata.reduce_spaces then
					promoted = promoted:gsub("(%s+)", " ")
				end
				self.buffer = metadata.replace_prompt .. promoted
				op.type = OP.COMPLETION_PROMOTION_FULL
			else
				self.buffer = self.buffer .. promoted
			end
			self.completion:flush()
			self.last_op = op
			if metadata.exec_on_prom then
				self:add_to_history()
			end
			return metadata.exec_on_prom and "execute" or true
		end,

		search_completion = function(self)
			if not self.completion then
				return false
			end
			if self.buffer:match("%s$") then
				self.completion:flush()
				return false
			end
			return self.completion:search(self.buffer, self.history)
		end,

		external_editor = function(self)
			local tmp_file = "/tmp/lilush_edit_" .. std.nanoid()
			std.fs.write_file(tmp_file, self.buffer)
			local editor = os.getenv("EDITOR") or "vi"
			local pid = std.ps.launch(editor, nil, nil, nil, tmp_file)
			local _, status = std.ps.wait(pid)
			local result = std.fs.read_file(tmp_file)
			if result then
				std.fs.remove(tmp_file)
				self.buffer = result
			else
				result = "can't get editor output"
			end
			self.last_op.type = OP.FULL_CHANGE
			return self:end_of_line()
		end,

		handle_ctl = function(self, shortcut)
			self.last_op.last_line = self.config.l

			if shortcut == "TAB" then
				if self.completion and self.completion:available() then
					if #self.completion.__candidates == 1 then
						return self:promote_completion()
					end
					if self.tab_long then
						return self:scroll_completion()
					end
					return self:promote_completion()
				end
				return nil
			end

			if shortcut == "BACKSPACE" then
				return self:backspace()
			end

			if shortcut == "LEFT" then
				return self:move_left()
			elseif shortcut == "RIGHT" then
				return self:move_right()
			elseif shortcut == "UP" then
				return self:history_up()
			elseif shortcut == "DOWN" then
				return self:history_down()
			end

			if shortcut == "HOME" or shortcut == "CTRL+a" then
				return self:start_of_line()
			end
			if shortcut == "END" or shortcut == "CTRL+e" then
				return self:end_of_line()
			end

			if shortcut == "ALT+ENTER" then
				return self:external_editor()
			end

			if shortcut == "ENTER" then
				if self.completion and self.completion:available() then
					local metadata = self.completion.__meta[self.completion.__chosen]
					if metadata and metadata.exec_on_prom then
						return self:promote_completion()
					end
				end
				-- If buffer is empty, increment line and redraw
				if self.buffer == "" then
					self.config.l = self.config.l + 1
					if self.config.l > self.window.h then
						self.config.l = self.window.h
					end
					self.last_op = {
						type = OP.FULL_CHANGE,
					}
					return true
				end
				self:add_to_history()
				return "execute"
			end

			if shortcut == "ESC" then
				if self.buffer == "" then
					return "exit"
				end
				return self:scroll_completion("up")
			end
			return "combo", shortcut
		end,

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
					self.tab_long = long_tab
					return self:handle_ctl(key)
				end
				return nil
			end

			-- This must be a clipboard paste...
			if key and not mods and not event then
				-- TODO: We need to replace this with something better,
				-- reading clipboard one char at a time does not seem to be an efficient way...
				for utf_char in key:gmatch(std.utf.patterns.glob) do
					self:insert(utf_char)
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
					return self:insert(shifted)
				end
				return self:insert(key)
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

			return self:handle_ctl(shortcut)
		end,

		run = function(self, exit_events)
			exit_events = exit_events or { execute = true, exit = true }
			local event, combo
			repeat
				if term.resized() then
					local new_h, new_w = term.window_size()
					if new_h ~= self.window.h or new_w ~= self.window.w then
						self:update_window_size(new_h, new_w)
						self.view:display(true)
					end
				end
				event, combo = self:event()
				if
					event
					and (
						not exit_events[event]
						or (self.last_op.type == OP.COMPLETION_PROMOTION_FULL and event == "execute")
					)
				then
					self.view:display()
				end
			until exit_events[event]
			return event, combo
		end,

		display = function(self, full_redraw)
			self.view:display(full_redraw)
		end,

		prompt_set = function(self, options)
			if self.prompt then
				self.prompt:set(options)
			end
		end,

		prompt_get = function(self)
			if self.prompt then
				return self.prompt:get()
			end
			return ""
		end,

		flush = function(self)
			self.buffer = ""
			self.cursor = 0
			self.position = 1
			if self.completion then
				self.completion:flush()
			end
		end,
	}

	-- Create view and initialize it with the input object
	input.view = view.new(input)
	input.OP = OP
	return input
end

return {
	get = get,
	simple_get = simple_get,
	mods_to_string = mods_to_string,
	string_to_mods = string_to_mods,
	new = new,
	OP = OP, -- Export OP for any external users that might need it
}
