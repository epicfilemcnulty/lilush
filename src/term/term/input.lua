-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local term = require("term")
local style = require("term.tss")
local buffer = require("string.buffer")
local socket = require("socket")

--[[
  Input Object, its functions & methods.

  All input methods related to editing/movement functions return `true` or `false`,
  where `true` means that the full redraw is required and
  `false` (or `nil`) means that either no redraw is required at all,
  or that it has been handled by the method itself.

  The main loop is proccessed in the `input:run()` method,
  where, based on the return of the `input:event()` method,
  we call (or don't) the `input:display()` method. `display()`
  decides between a full redraw and a lightweight partial update
  (rendering the visible line and syncing the cursor) based on
  the cached render state.

  Input object instance with default config for reference:
  {
    -- Geometry stuff for positioning =)
    cfg = {
	  l = 1,
	  c = 1,
      w = window_width,
      h = window_height,
	  width = w - 1,
	  blank = " ",
	  tab_timing = 0.093,
	},
    -- Input state
	__state = {
	  lines = { "" },
	  line = 1,
	  cursor = 1,
	  offset = 0, -- current position in line is offset + cursor
	  last_completion = 0, -- keeping length for clearing purposes
	  tab_long = false,
	  tab_state = {
	    start = nil, last_release = nil,
	    long = false,
	    double_tap = false,
	  },
	},
    -- optional __prompt, __history and __completion objects
    -- plus input methods would go below
    ...
  }

]]

-- We recognize two kinds of TAB presses -- long and short,
-- and also there is `double_tap` event (which is not even used), hence all the mumbo jumbo
-- with this function and tab_state table...
-- This all cries for refactoring, at the very least we could get rid of that standalone tab_long field...
local handle_tab_state = function(self, event)
	local s = self.__state
	if event == 2 then
		return nil
	end
	if event == 1 then
		if not s.tab_state.start then
			s.tab_state.start = socket.gettime()
		end
		return nil
	end
	if event == 3 then
		local now = socket.gettime()
		s.tab_state.long = false

		if s.tab_state.start then
			if now - s.tab_state.start > self.cfg.tab_timing then
				s.tab_state.long = true
			end
		end

		s.tab_state.start = nil

		if s.tab_state.last_release then
			s.tab_state.double_tap = (now - s.tab_state.last_release <= self.cfg.tab_timing * 2)
		end

		s.tab_state.last_release = now
		return s.tab_state.long
	end
	return nil
end

local history_count = function(history)
	return history:entries_count()
end

local history_position = function(history)
	return history:position_get()
end

local completion_count = function(completion)
	return completion:count()
end

local completion_chosen_index = function(completion)
	return completion:chosen_index()
end

local completion_set_chosen_index = function(completion, idx)
	completion:set_chosen_index(idx)
end

local completion_meta_at = function(completion, idx)
	return completion:meta_at(idx)
end

local cursor_is_at_eol = function(self)
	local s = self.__state
	local line = s.lines[s.line] or ""
	return s.offset + s.cursor == std.utf.len(line) + 1
end

-- All control events are handled here
local handle_ctl = function(self, shortcut)
	local s = self.__state
	if shortcut == "TAB" then
		if not cursor_is_at_eol(self) then
			self:completion_reset_visual(true)
			return nil
		end
		if self.__completion and self.__completion:available() then
			if completion_count(self.__completion) == 1 then
				return self:promote_completion()
			end
			if s.tab_long then
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

	if shortcut == "CTRL+LEFT" then
		return self:move_to_previous_space()
	end
	if shortcut == "CTRL+RIGHT" then
		return self:move_to_next_space()
	end

	if shortcut == "HOME" then
		self:completion_reset_visual(true)
		s.line = 1
		return self:start_of_line()
	end
	if shortcut == "CTRL+a" then
		self:completion_reset_visual(true)
		return self:start_of_line()
	end

	if shortcut == "END" then
		self:completion_reset_visual(true)
		s.line = #s.lines
		return self:end_of_line()
	end
	if shortcut == "CTRL+e" then
		self:completion_reset_visual(true)
		return self:end_of_line()
	end

	-- Add a newline on SHIFT+ENTER
	if shortcut == "SHIFT+ENTER" then
		return self:newline()
	end

	if shortcut == "ALT+ENTER" then
		return self:external_editor()
	end

	if shortcut == "ALT+." then
		return self:insert_last_arg()
	end

	if shortcut == "ENTER" then
		if self.__completion and self.__completion:available() then
			local metadata = completion_meta_at(self.__completion, completion_chosen_index(self.__completion))
			if metadata and metadata.exec_on_prom then
				return self:promote_completion()
			end
		end
		-- If buffer is empty just increment line and redraw
		if self:buffer_empty() then
			self.cfg.l = self.cfg.l + 1
			if self.cfg.l > self.cfg.h then
				self.cfg.l = self.cfg.h
			end
			return true
		end

		return "execute"
	end

	if shortcut == "ESC" then
		if self:buffer_empty() then
			return "exit"
		end
		return self:scroll_completion("up")
	end
	return "combo", shortcut
end

local event = function(self)
	local s = self.__state
	local key, mods, event, shifted, base = term.get()
	if not key then
		return nil
	end

	if key == "TAB" then
		local long_tab = self:handle_tab_state(event)
		if event == 3 then -- Only process TAB on key release
			s.tab_long = long_tab
			return self:handle_ctl(key)
		end
		return nil
	end

	-- This must be a clipboard paste...
	if key and not mods and not event then
		local b = buffer.new()
		b:put(key)
		local rest = io.read("*a")
		if rest then
			b:put(rest)
		end
		for i, line in ipairs(std.txt.lines(b:get())) do
			if i == 1 then
				local p = std.utf.sub(s.lines[s.line], 1, s.offset + s.cursor - 1)
				local suffix = std.utf.sub(s.lines[s.line], s.offset + s.cursor)
				s.lines[s.line] = p .. line .. suffix
				self:cursor_right(std.utf.len(line))
			else
				self:newline()
				s.lines[s.line] = line
				self:end_of_line()
			end
		end
		return true
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
	local mod_string = term.mods_to_string(mods - 1)
	local shortcut = key
	if mod_string ~= "" then
		shortcut = mod_string .. "+" .. key
	end

	return self:handle_ctl(shortcut)
end

local run = function(self, exit_events)
	exit_events = exit_events or { execute = true, exit = true }
	local event, combo
	repeat
		if term.resized() then
			local h, w = term.window_size()
			if h ~= self.cfg.h or w ~= self.cfg.w then
				self:update_window_size(h, w)
				self:display(true)
			end
		end
		event, combo = self:event()
		if event and not exit_events[event] then
			self:display()
		end
	until exit_events[event]
	return event, combo
end

local newline = function(self)
	local s = self.__state
	self:completion_reset_visual(true)
	-- If we are at the beginning of the line, we'll
	-- insert the new line before the current one
	if s.cursor == 1 and s.offset == 0 then
		table.insert(s.lines, s.line, "")
	elseif s.cursor + s.offset == std.utf.len(s.lines[s.line]) + 1 then
		--  If we are at the end, insert the new line
		-- after the current one
		s.line = s.line + 1
		table.insert(s.lines, s.line, "")
	else
		-- Middle of the line case
		local p = std.utf.sub(s.lines[s.line], 1, s.offset + s.cursor - 1)
		local suffix = std.utf.sub(s.lines[s.line], s.offset + s.cursor)
		s.lines[s.line] = p
		s.line = s.line + 1
		table.insert(s.lines, s.line, suffix)
	end
	return self:start_of_line()
end

local clear_all = function(self)
	term.go(self.cfg.l, self.cfg.c)
	-- Since we want to clear the whole input box,
	-- we use `cfg.width` here rather than `self:max_width()` --
	-- max_width()'s value is dynamic, which is not what we want here
	term.write(string.rep(self.cfg.blank, self.cfg.width))
	term.go(self.cfg.l, self.cfg.c)
end

local clear_from_prompt = function(self)
	local pl, _ = self:prompt_len()
	if pl == 0 then
		return self:clear_all()
	end
	term.go(self.cfg.l, self.cfg.c + pl)
	term.write(string.rep(self.cfg.blank, self:max_width()))
	term.go(self.cfg.l, self.cfg.c + pl)
end

local clear_from_cursor = function(self)
	local s = self.__state
	local pl, _ = self:prompt_len()
	term.go(self.cfg.l, self.cfg.c + pl + s.cursor - 1)
	local count = self:max_width() - s.cursor
	term.write(string.rep(self.cfg.blank, count))
	term.move("left", count)
end

local clear_completion = function(self)
	local s = self.__state
	if s.last_completion > 0 then
		term.write(string.rep(self.cfg.blank, s.last_completion))
		term.move("left", s.last_completion)
		s.last_completion = 0
	end
end

local draw_completion = function(self)
	local s = self.__state
	self:clear_completion()
	if not cursor_is_at_eol(self) then
		return nil
	end
	if self.__completion and self.__completion:available() then
		local completion = self.__completion:get()
		local len = std.utf.len(completion)
		if completion ~= "" and len > 0 and len <= self:max_width() - s.cursor then
			term.write(self.cfg.tss:apply("completion", completion).text)
			s.last_completion = len
			term.move("left", len)
		end
	end
end

local visible_slice = function(self)
	local s = self.__state
	local mw = self:max_width()
	local line = s.lines[s.line] or ""
	if s.offset > 0 then
		line = std.utf.sub(line, s.offset + 1)
	end
	if std.utf.len(line) > mw then
		line = std.utf.sub(line, 1, mw)
	end
	return line, mw
end

local normalize_viewport = function(self, anchor)
	local s = self.__state

	if #s.lines == 0 then
		s.lines = { "" }
	end

	local line_idx = tonumber(s.line) or 1
	line_idx = math.floor(line_idx)
	if line_idx < 1 then
		line_idx = 1
	elseif line_idx > #s.lines then
		line_idx = #s.lines
	end
	s.line = line_idx

	local line = s.lines[s.line] or ""
	local line_len = std.utf.len(line)
	local mw = self:max_width()
	if mw < 1 then
		mw = 1
	end

	local target_pos
	if anchor == "start" then
		target_pos = 1
	elseif anchor == "end" then
		target_pos = line_len + 1
	else
		local cursor = tonumber(s.cursor) or 1
		local offset = tonumber(s.offset) or 0
		cursor = math.floor(cursor)
		offset = math.floor(offset)
		if cursor < 1 then
			cursor = 1
		end
		if offset < 0 then
			offset = 0
		end
		target_pos = offset + cursor
		if target_pos < 1 then
			target_pos = 1
		elseif target_pos > line_len + 1 then
			target_pos = line_len + 1
		end
	end

	if target_pos <= mw then
		s.offset = 0
		s.cursor = target_pos
	else
		s.offset = target_pos - mw
		s.cursor = mw
	end
	return true
end

local snapshot_render_state = function(self)
	local s = self.__state
	local render = s.render or {}
	local prompt_len, prompt = self:prompt_len()
	local visible, mw = self:visible_slice()

	render.last_prompt = prompt or ""
	render.last_prompt_len = prompt_len or 0
	render.last_visible = visible or ""
	render.last_visible_len = std.utf.len(render.last_visible)
	render.last_line = s.line
	render.last_offset = s.offset
	render.last_cursor = s.cursor
	render.last_mw = mw
	render.last_completion = s.last_completion or 0
	render.ready = true

	s.render = render
	return true
end

local completion_reset_visual = function(self, flush_model)
	self:clear_completion()
	if flush_model and self.__completion then
		self.__completion:flush()
	end
	return true
end

local render_visible_line = function(self, clear_tail)
	local s = self.__state
	local render = s.render or {}
	local prompt_len = self:prompt_len()
	local visible = self:visible_slice()
	local visible_len = std.utf.len(visible)
	local prev_len = render.last_visible_len or 0

	term.go(self.cfg.l, self.cfg.c + prompt_len)
	term.write(visible)
	if clear_tail and prev_len > visible_len then
		term.write(string.rep(self.cfg.blank, prev_len - visible_len))
	end
	self:sync_cursor()
	return true
end

local render_from_column = function(self, col, clear_tail)
	local s = self.__state
	local render = s.render or {}
	local prompt_len = self:prompt_len()
	local visible = self:visible_slice()
	local visible_len = std.utf.len(visible)
	local prev_len = render.last_visible_len or 0

	col = math.floor(tonumber(col) or 1)
	if col < 1 then
		col = 1
	elseif col > visible_len + 1 then
		col = visible_len + 1
	end

	local suffix = ""
	if col <= visible_len then
		suffix = std.utf.sub(visible, col)
	end

	term.go(self.cfg.l, self.cfg.c + prompt_len + col - 1)
	if suffix ~= "" then
		term.write(suffix)
	end

	if clear_tail then
		local old_suffix_len = 0
		if prev_len >= col then
			old_suffix_len = prev_len - col + 1
		end
		local new_suffix_len = 0
		if visible_len >= col then
			new_suffix_len = visible_len - col + 1
		end
		local tail = old_suffix_len - new_suffix_len
		if tail > 0 then
			term.write(string.rep(self.cfg.blank, tail))
		end
	end

	self:sync_cursor()
	return true
end

local full_redraw = function(self)
	local s = self.__state
	self:clear_all()
	self:prompt_set({ lines = #s.lines, line = s.line })
	self:normalize_viewport("preserve")
	s.last_completion = 0
	local p_len, p = self:prompt_len()
	if p_len > 0 then
		term.write(p)
	end
	if self:buffer_empty() then
		self:snapshot_render_state()
		return true
	end
	local content = self:visible_slice()
	term.write(content)
	term.go(self.cfg.l, self.cfg.c + p_len + s.cursor - 1)
	self:snapshot_render_state()
	return true
end

local cursor_right = function(self, count)
	local s = self.__state
	count = count or 1
	local mw = self:max_width()
	if s.cursor + count < mw then
		-- Simple case: cursor stays within visible area
		s.cursor = s.cursor + count
	else
		s.offset = s.offset + (s.cursor + count - mw)
		s.cursor = mw
	end
end

local cursor_left = function(self)
	local s = self.__state
	if s.cursor > 1 then
		-- Simple case: cursor moves left within visible area
		s.cursor = s.cursor - 1
	elseif s.offset > 0 then
		s.offset = s.offset - 1
	end
end

local move_right = function(self)
	local s = self.__state
	local line_len = std.utf.len(s.lines[s.line])
	local pos = s.offset + s.cursor
	if pos <= line_len then
		local old_offset = s.offset
		self:completion_reset_visual(true)
		self:cursor_right()
		if s.offset == old_offset then
			term.move("right")
		else
			term.hide_cursor()
			self:render_visible_line(true)
			term.show_cursor()
		end
		self:snapshot_render_state()
		return false
	elseif #s.lines > 1 then
		-- Move to next line if available
		if s.line < #s.lines then
			self:completion_reset_visual(true)
			s.line = s.line + 1
			self:start_of_line()
			return true
		end
	end
end

local move_left = function(self)
	local s = self.__state
	if s.cursor > 1 then
		-- Simple case: move cursor left within visible area
		self:completion_reset_visual(true)
		term.move("left")
		self:cursor_left()
		self:snapshot_render_state()
		return false
	end
	if s.offset > 0 then
		-- Complex case: scroll content right to show earlier text
		self:completion_reset_visual(true)
		self:cursor_left()
		term.hide_cursor()
		self:render_visible_line(true)
		term.show_cursor()
		self:snapshot_render_state()
		return false
	end
	if s.line > 1 then
		-- Move to previous line if available
		self:completion_reset_visual(true)
		s.line = s.line - 1
		self:end_of_line()
		return true
	end
end

-- TODO: implement handling the cases when
-- distance is bigger than the visible part
local move_to_previous_space = function(self)
	local s = self.__state
	local old_cursor = s.cursor
	local old_offset = s.offset
	local pos = s.offset + s.cursor
	local line_upto_cursor = std.utf.sub(s.lines[s.line], 1, pos - 1)
	if line_upto_cursor:match("%s") then
		local spaces = std.utf.find_all_spaces(line_upto_cursor)
		if #spaces > 0 then
			local last_space = spaces[#spaces]
			local distance = pos - last_space
			if s.cursor > distance then
				self:completion_reset_visual(true)
				s.cursor = s.cursor - distance
				if s.offset ~= old_offset then
					term.hide_cursor()
					self:render_visible_line(true)
					term.show_cursor()
				else
					local delta = old_cursor - s.cursor
					if delta > 0 then
						term.move("left", delta)
					end
				end
				self:snapshot_render_state()
				return false
			end
		end
	end
	return false
end

local move_to_next_space = function(self)
	local s = self.__state
	local old_cursor = s.cursor
	local old_offset = s.offset
	local pos = s.offset + s.cursor
	local line_from_cursor = std.utf.sub(s.lines[s.line], pos + 1)
	if line_from_cursor:match("%s") then
		local spaces = std.utf.find_all_spaces(line_from_cursor)
		local next_space = spaces[1] or math.huge
		if s.cursor + next_space < self:max_width() then
			self:completion_reset_visual(true)
			s.cursor = s.cursor + next_space
			if s.offset ~= old_offset then
				term.hide_cursor()
				self:render_visible_line(true)
				term.show_cursor()
			else
				local delta = s.cursor - old_cursor
				if delta > 0 then
					term.move("right", delta)
				end
			end
			self:snapshot_render_state()
			return false
		end
	end
	return false
end

local sync_cursor = function(self)
	local s = self.__state
	local pl = self:prompt_len()
	term.go(self.cfg.l, self.cfg.c + pl + s.cursor - 1)
end

local insert = function(self, char)
	local s = self.__state
	local line_len = std.utf.len(s.lines[s.line])
	local pos = s.offset + s.cursor
	local old_cursor = s.cursor
	local old_offset = s.offset

	if pos > line_len + 1 then
		return false
	end

	self:completion_reset_visual(true)

	if pos == line_len + 1 then
		s.lines[s.line] = s.lines[s.line] .. char
	else
		local p = std.utf.sub(s.lines[s.line], 1, pos - 1)
		local suffix = std.utf.sub(s.lines[s.line], pos, line_len)
		s.lines[s.line] = p .. char .. suffix
	end

	self:cursor_right()

	term.hide_cursor()
	if s.offset == old_offset then
		self:render_from_column(old_cursor, true)
	else
		self:render_visible_line(true)
	end
	self:search_completion()
	self:draw_completion()
	self:snapshot_render_state()
	term.show_cursor()

	return false
end

local backspace = function(self)
	local s = self.__state
	local line_len = std.utf.len(s.lines[s.line])
	local pos = s.offset + s.cursor

	if pos == 1 and line_len == 0 and s.line > 1 then
		table.remove(s.lines, s.line)
		s.line = s.line - 1
		self:end_of_line()
		return true
	end

	if pos == line_len + 1 and line_len > 0 then
		local old_offset = s.offset
		self:completion_reset_visual(true)
		s.lines[s.line] = std.utf.sub(s.lines[s.line], 1, pos - 2)
		self:cursor_left()
		term.hide_cursor()
		if s.offset == old_offset then
			self:render_from_column(s.cursor, true)
		else
			self:render_visible_line(true)
		end
		self:snapshot_render_state()
		term.show_cursor()
		return false
	end

	if pos <= line_len and pos > 1 then
		local old_offset = s.offset
		self:completion_reset_visual(true)
		local p = std.utf.sub(s.lines[s.line], 1, pos - 2)
		local suffix = std.utf.sub(s.lines[s.line], pos, line_len)
		s.lines[s.line] = p .. suffix
		self:cursor_left()
		term.hide_cursor()
		if s.offset == old_offset then
			self:render_from_column(s.cursor, true)
		else
			self:render_visible_line(true)
		end
		self:snapshot_render_state()
		term.show_cursor()
		return false
	end

	return false
end

local scroll_completion = function(self, direction)
	if not self.__completion or not self.__completion:available() then
		return false
	end

	direction = direction or "down"
	local total = completion_count(self.__completion)
	local idx = completion_chosen_index(self.__completion)

	if direction == "down" then
		idx = idx + 1
		if idx > total then
			idx = 1
		end
	else
		idx = idx - 1
		if idx < 1 then
			idx = total
		end
	end
	completion_set_chosen_index(self.__completion, idx)
	term.hide_cursor()
	self:draw_completion()
	self:snapshot_render_state()
	term.show_cursor()
	return false
end

local promote_completion = function(self)
	local s = self.__state
	if not self.__completion or not self.__completion:available() then
		return false
	end

	local promoted = self.__completion:get(true)
	local metadata = completion_meta_at(self.__completion, completion_chosen_index(self.__completion))

	metadata = metadata or {}
	if metadata.replace_prompt then
		if metadata.trim_promotion then
			promoted = promoted:gsub("^%s+", "")
		elseif metadata.reduce_spaces then
			promoted = promoted:gsub("(%s+)", " ")
		end
		-- For now let's assume that completions work on one line level...
		s.lines[s.line] = metadata.replace_prompt .. promoted
	else
		s.lines[s.line] = s.lines[s.line] .. promoted
	end
	self.__completion:flush()
	self:clear_completion()
	if metadata.exec_on_prom then
		self:clear_from_prompt()
		term.write(s.lines[s.line])
		return "execute"
	end
	self:end_of_line()
	term.hide_cursor()
	self:render_visible_line(true)
	self:snapshot_render_state()
	term.show_cursor()
	return false
end

local search_completion = function(self)
	local s = self.__state
	if not self.__completion then
		return false
	end
	if not cursor_is_at_eol(self) then
		self.__completion:flush()
		return false
	end
	-- once again, we've chosen to do it on line level
	-- not really sure how it will play out =)
	if s.lines[s.line]:match("%s$") then
		self.__completion:flush()
		return false
	end
	return self.__completion:search(s.lines[s.line], self.__history)
end

local external_editor = function(self)
	local s = self.__state
	local editor = os.getenv("EDITOR") or "vi"
	local stdin = std.ps.pipe()
	local stdout = std.ps.pipe()
	stdin:write(self:get_content())
	stdin:close_inn()
	local pid = std.ps.launch(editor, stdin.out, stdout.inn, nil, "-")
	local _, status = std.ps.wait(pid)
	stdin:close_out()
	stdout:close_inn()
	local result = stdout:read() or "can't get editor output"
	stdout:close_out()
	self:completion_reset_visual(true)
	s.lines = std.txt.lines(result)
	s.line = #s.lines
	self:prompt_set({ lines = #s.lines, line = s.line })
	self:end_of_line()
	self:display()
end

local insert_last_arg = function(self)
	local s = self.__state
	if not self.__history or history_count(self.__history) == 0 then
		return false
	end

	local last_arg = self.__history:last_arg()
	if not last_arg or last_arg == "" then
		return false
	end

	-- Insert the last arg at cursor position
	local pos = s.offset + s.cursor
	local line_len = std.utf.len(s.lines[s.line])
	local p = std.utf.sub(s.lines[s.line], 1, pos - 1)
	local suffix = std.utf.sub(s.lines[s.line], pos, line_len)
	s.lines[s.line] = p .. last_arg .. suffix

	-- Move cursor to end of inserted text
	self:cursor_right(std.utf.len(last_arg))

	return true
end

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
	config = config or {}
	local user_rss = config.rss or {}
	local win_l, win_c = term.window_size()
	local default_config = {
		l = 1,
		c = 1,
		width = win_c - 1,
		tss = style.merge(default_rss, user_rss),
		blank = " ",
		tab_timing = tonumber(os.getenv("LILUSH_QUICK_PRESS")) or 0.093,
	}
	config = std.tbl.merge(default_config, config)
	config.rss = nil
	config.w = win_c -- Since we rely on `config.w` and `config.h` to reflect
	config.h = win_l -- window size, we don't want user to override them.

	local input = {
		-- Config
		cfg = config,
		-- State
		__state = {
			lines = { "" },
			line = 1,
			cursor = 1,
			offset = 0,
			last_completion = 0,
			render = {
				last_prompt = "",
				last_prompt_len = 0,
				last_visible = "",
				last_visible_len = 0,
				last_line = 1,
				last_offset = 0,
				last_cursor = 1,
				last_mw = 1,
				last_completion = 0,
				ready = false,
			},
			tab_long = false,
			tab_state = {
				start = nil,
				last_release = nil,
				long = false,
				double_tap = false,
			},
		},
		-- Optional collaborator objects
		__completion = config.completion,
		__history = config.history,
		__prompt = config.prompt,
		-- Methods
		handle_tab_state = handle_tab_state,
		handle_ctl = handle_ctl,
		event = event,
		run = run,
		newline = newline,
		insert = insert,
		backspace = backspace,
		cursor_right = cursor_right,
		cursor_left = cursor_left,
		move_right = move_right,
		move_left = move_left,
		move_to_previous_space = move_to_previous_space,
		move_to_next_space = move_to_next_space,
		clear_all = clear_all,
		clear_from_cursor = clear_from_cursor,
		clear_from_prompt = clear_from_prompt,
		clear_completion = clear_completion,
		search_completion = search_completion,
		scroll_completion = scroll_completion,
		promote_completion = promote_completion,
		external_editor = external_editor,
		insert_last_arg = insert_last_arg,
		draw_completion = draw_completion,
		visible_slice = visible_slice,
		normalize_viewport = normalize_viewport,
		snapshot_render_state = snapshot_render_state,
		completion_reset_visual = completion_reset_visual,
		render_visible_line = render_visible_line,
		render_from_column = render_from_column,
		sync_cursor = sync_cursor,
		full_redraw = full_redraw,
		display = function(self, force)
			local s = self.__state
			self:prompt_set({ lines = #s.lines, line = s.line })
			self:normalize_viewport("preserve")
			local prompt_len, prompt = self:prompt_len()
			local render = s.render or {}
			local hard_redraw = force == true
			if not hard_redraw then
				if not render.ready then
					hard_redraw = true
				elseif render.last_prompt ~= prompt or render.last_prompt_len ~= prompt_len then
					hard_redraw = true
				elseif render.last_line ~= s.line then
					hard_redraw = true
				end
			end

			term.hide_cursor()
			if hard_redraw then
				self:full_redraw()
			else
				self:completion_reset_visual(false)
				self:render_visible_line(true)
				self:snapshot_render_state()
			end
			term.show_cursor()
		end,
		buffer_empty = function(self)
			local s = self.__state
			if #s.lines == 1 and s.lines[1] == "" then
				return true
			end
			return false
		end,
		prompt_len = function(self)
			local len = 0
			local prompt = ""
			if self.__prompt then
				prompt = self.__prompt:get() or ""
				len = std.utf.len(prompt)
			end
			return len, prompt
		end,
		max_width = function(self)
			local available_width = self.cfg.w - self.cfg.c - self:prompt_len()
			local width = math.min(self.cfg.width, self.cfg.w)
			return math.max(1, math.min(available_width, width))
		end,
		update_window_size = function(self, h, w)
			self.cfg.h = h
			self.cfg.w = w
			-- Track terminal width
			self.cfg.width = w - 1
			local s = self.__state
			self:prompt_set({ lines = #s.lines, line = s.line })
			self:normalize_viewport("preserve")
		end,
		set_position = function(self, l, c)
			if type(l) == "number" then
				self.cfg.l = l
			end
			if type(c) == "number" then
				self.cfg.c = c
			end
		end,
		get_content = function(self)
			return table.concat(self.__state.lines, "\n")
		end,
		set_content = function(self, text)
			local s = self.__state
			self:completion_reset_visual(true)
			s.lines = std.txt.lines(text or "")
			s.line = #s.lines
			self:prompt_set({ lines = #s.lines, line = s.line })
			self:end_of_line()
		end,
		prompt_set = function(self, options)
			if self.__prompt then
				self.__prompt:set(options)
			end
		end,
		prompt_get = function(self)
			if self.__prompt then
				return self.__prompt:get()
			end
			return ""
		end,
		prompt_toggle_block = function(self, name)
			if self.__prompt then
				self.__prompt:toggle_block(name)
			end
		end,
		prompt_blocks = function(self)
			if self.__prompt then
				if self.__prompt.get_blocks then
					return self.__prompt:get_blocks()
				end
			end
			return {}
		end,
		prompt_set_blocks = function(self, blocks)
			if self.__prompt then
				if self.__prompt.set_blocks then
					self.__prompt:set_blocks(blocks)
				end
			end
		end,
		completion_update = function(self)
			if self.__completion then
				self.__completion:update()
			end
		end,
		completion_update_source = function(self, name, ...)
			if self.__completion then
				local src = self.__completion:source(name)
				if src and src.update then
					src:update(...)
				end
			end
		end,
		lookup_binary = function(self, cmd)
			if self.__completion then
				local src = self.__completion:source("bin")
				if src then
					if src.binaries then
						return src.binaries[cmd]
					end
					if src.__state and src.__state.binaries then
						return src.__state.binaries[cmd]
					end
				end
			end
			return nil
		end,
		add_to_history = function(self)
			if self.__history and not self:buffer_empty() then
				self.__history:add(self:get_content())
			end
		end,
		history_up = function(self)
			local s = self.__state
			if not self.__history then
				return false
			end
			if self.__history:up() then
				self:completion_reset_visual(true)
				if not self:buffer_empty() and history_position(self.__history) == history_count(self.__history) then
					self.__history:stash(self:get_content())
				end
				s.lines = std.txt.lines(self.__history:get())
				s.line = #s.lines
				self:prompt_set({ lines = #s.lines, line = s.line })
				self:end_of_line()
				return true
			end
			return false
		end,
		history_down = function(self)
			local s = self.__state
			if not self.__history then
				return false
			end
			if self.__history:down() then
				self:completion_reset_visual(true)
				s.lines = std.txt.lines(self.__history:get())
				s.line = #s.lines
				self:prompt_set({ lines = #s.lines, line = s.line })
				self:end_of_line()
				return true
			end
		end,
		end_of_line = function(self)
			return self:normalize_viewport("end")
		end,
		start_of_line = function(self)
			return self:normalize_viewport("start")
		end,
		flush = function(self)
			local s = self.__state
			s.lines = { "" }
			s.line = 1
			s.offset = 0
			s.cursor = 1
			s.render = {
				last_prompt = "",
				last_prompt_len = 0,
				last_visible = "",
				last_visible_len = 0,
				last_line = 1,
				last_offset = 0,
				last_cursor = 1,
				last_mw = 1,
				last_completion = 0,
				ready = false,
			}
			s.last_completion = 0
			if self.__completion then
				self.__completion:flush()
			end
		end,
	}
	return input
end

return { new = new }
