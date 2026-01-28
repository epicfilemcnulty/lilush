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
  we call (or don't) the `input:display()` method (which is
  just a wrapper for `input:full_redraw()` function at the moment)

  Input object instance with default config for reference:
  {
    -- Geometry stuff for positioning =)
    __cfg = {
	  l = 1,
	  c = 1,
      w = window_width,
      h = window_height,
	  width = w - 1,
	  blank = " ",
	  tab_timing = 0.093,
	},
    -- Input state
	lines = { "" },
	line = 1,
	cursor = 1,
	offset = 0, -- current position in line is offset + cursor
    last_completion = 0, -- keeping length for clearing purposes
	-- Tab state
	tab_long = false,
	tab_state = {
	  start = nil, last_release = nil,
	  long = false,
	  double_tap = false,
	},
    -- optional prompt, history and completion objects
    -- plus input methods would go below
    ...
  }

]]

-- We recognize two kinds of TAB presses -- long and short,
-- and also there is `double_tap` event (which is not even used), hence all the mumbo jumbo
-- with this function and tab_state table...
-- This all cries for refactoring, at the very least we could get rid of that standalone tab_long field...
local handle_tab_state = function(self, event)
	if event == 2 then
		return nil
	end
	if event == 1 then
		if not self.tab_state.start then
			self.tab_state.start = socket.gettime()
		end
		return nil
	end
	if event == 3 then
		local now = socket.gettime()
		self.tab_state.long = false

		if self.tab_state.start then
			if now - self.tab_state.start > self.__cfg.tab_timing then
				self.tab_state.long = true
			end
		end

		self.tab_state.start = nil

		if self.tab_state.last_release then
			self.tab_state.double_tap = (now - self.tab_state.last_release <= self.__cfg.tab_timing * 2)
		end

		self.tab_state.last_release = now
		return self.tab_state.long
	end
	return nil
end

-- All control events are handled here
local handle_ctl = function(self, shortcut)
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

	if shortcut == "CTRL+LEFT" then
		return self:move_to_previous_space()
	end
	if shortcut == "CTRL+RIGHT" then
		return self:move_to_next_space()
	end

	if shortcut == "HOME" then
		self.line = 1
		return self:start_of_line()
	end
	if shortcut == "CTRL+a" then
		return self:start_of_line()
	end

	if shortcut == "END" then
		self.line = #self.lines
		return self:end_of_line()
	end
	if shortcut == "CTRL+e" then
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
		if self.completion and self.completion:available() then
			local metadata = self.completion.__meta[self.completion.__chosen]
			if metadata and metadata.exec_on_prom then
				return self:promote_completion()
			end
		end
		-- If buffer is empty just increment line and redraw
		if self:buffer_empty() then
			self.__cfg.l = self.__cfg.l + 1
			if self.__cfg.l > self.__cfg.h then
				self.__cfg.l = self.__cfg.h
			end
			return true
		end

		self:add_to_history()
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
	local key, mods, event, shifted, base = term.get()
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
		local b = buffer.new()
		b:put(key)
		local rest = io.read("*a")
		if rest then
			b:put(rest)
		end
		for i, line in ipairs(std.txt.lines(b:get())) do
			if i == 1 then
				local p = std.utf.sub(self.lines[self.line], 1, self.offset + self.cursor)
				local s = std.utf.sub(self.lines[self.line], self.offset + self.cursor)
				self.lines[self.line] = p .. line .. s
				self:cursor_right(std.utf.len(line))
			else
				self:newline()
				self.lines[self.line] = line
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
			if h ~= self.__cfg.h or w ~= self.__cfg.w then
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
	-- If we are at the beginning of the line, we'll
	-- insert the new line before the current one
	if self.cursor == 1 and self.offset == 0 then
		table.insert(self.lines, self.line, "")
	elseif self.cursor + self.offset == #self.lines[self.line] + 1 then
		--  If we are at the end, insert the new line
		-- after the current one
		self.line = self.line + 1
		table.insert(self.lines, self.line, "")
	else
		-- Middle of the line case
		local p = std.utf.sub(self.lines[self.line], 1, self.offset + self.cursor - 1)
		local s = std.utf.sub(self.lines[self.line], self.offset + self.cursor, #self.lines[self.line])
		self.lines[self.line] = p
		self.line = self.line + 1
		table.insert(self.lines, self.line, "")
		table.insert(self.lines, self.line + 1, s)
	end
	return self:start_of_line()
end

local clear_all = function(self)
	term.go(self.__cfg.l, self.__cfg.c)
	-- Since we want to clear the whole input box,
	-- we use `__cfg.width` here rather than `self:max_width()` —
	-- max_width()'s value is dynamic, which is not what we want here
	term.write(string.rep(self.__cfg.blank, self.__cfg.width))
	term.go(self.__cfg.l, self.__cfg.c)
end

local clear_from_prompt = function(self)
	local pl, _ = self:prompt_len()
	if pl == 0 then
		return self:clear_all()
	end
	term.go(self.__cfg.l, self.__cfg.c + pl)
	term.write(string.rep(self.__cfg.blank, self:max_width()))
	term.go(self.__cfg.l, self.__cfg.c + pl)
end

local clear_from_cursor = function(self)
	local pl, _ = self:prompt_len()
	term.go(self.__cfg.l, self.__cfg.c + pl + self.cursor - 1)
	local count = self:max_width() - self.cursor
	term.write(string.rep(self.__cfg.blank, count))
	term.move("left", count)
end

local clear_completion = function(self)
	if self.last_completion > 0 then
		term.write(string.rep(self.__cfg.blank, self.last_completion))
		term.move("left", self.last_completion)
		self.last_completion = 0
	end
end

local draw_completion = function(self)
	if self.completion and self.completion:available() then
		local completion = self.completion:get()
		local len = std.utf.len(completion)
		if completion ~= "" and len <= self:max_width() - self.cursor then
			self:clear_completion()
			term.write(self.__cfg.tss:apply("completion", completion))
			self.last_completion = len
			term.move("left", len)
		end
	end
end

local full_redraw = function(self)
	self:clear_all()
	self:prompt_set({ lines = #self.lines, line = self.line })
	local p_len, p = self:prompt_len()
	if p_len > 0 then
		term.write(p)
	end
	if self:buffer_empty() then
		return true
	end
	local mw = self:max_width()
	local content = self.lines[self.line]
	if self.offset > 0 then
		content = std.utf.sub(self.lines[self.line], self.offset + 1)
	end
	if #content > mw then
		content = std.utf.sub(content, 1, mw)
	end
	term.write(content)
	term.go(self.__cfg.l, self.__cfg.c + p_len + self.cursor - 1)
	return true
end

local cursor_right = function(self, count)
	count = count or 1
	local mw = self:max_width()
	if self.cursor + count < mw then
		-- Simple case: cursor stays within visible area
		self.cursor = self.cursor + count
	else
		self.offset = self.offset + (self.cursor + count - mw)
		self.cursor = mw
	end
end

local cursor_left = function(self)
	if self.cursor > 1 then
		-- Simple case: cursor moves left within visible area
		self.cursor = self.cursor - 1
	elseif self.offset > 0 then
		self.offset = self.offset - 1
	end
end

local move_right = function(self)
	local line_len = std.utf.len(self.lines[self.line])
	local pos = self.offset + self.cursor
	if pos <= line_len then
		self:cursor_right()
		if pos <= self:max_width() then
			term.move("right")
			return false
		else
			return true
		end
	elseif #self.lines > 1 then
		-- Move to next line if available
		if self.line < #self.lines then
			self.line = self.line + 1
			self:start_of_line()
			return true
		end
	end
end

local move_left = function(self)
	if self.cursor > 1 then
		-- Simple case: move cursor left within visible area
		term.move("left")
		self:cursor_left()
		return false
	end
	if self.offset > 0 then
		-- Complex case: scroll content right to show earlier text
		self:cursor_left()
		return true
	end
	if self.line > 1 then
		-- Move to previous line if available
		self.line = self.line - 1
		self:end_of_line()
		return true
	end
end

-- TODO: implement handling the cases when
-- distance is bigger than the visible part
local move_to_previous_space = function(self)
	local pos = self.offset + self.cursor
	local line_upto_cursor = std.utf.sub(self.lines[self.line], 1, pos - 1)
	if line_upto_cursor:match("%s") then
		local spaces = std.utf.find_all_spaces(line_upto_cursor)
		if #spaces > 0 then
			local last_space = spaces[#spaces]
			local distance = pos - last_space
			if self.cursor > distance then
				self.cursor = self.cursor - distance
				return true
			end
		end
	end
	return false
end

local move_to_next_space = function(self)
	local pos = self.offset + self.cursor
	local line_from_cursor = std.utf.sub(self.lines[self.line], pos + 1)
	if line_from_cursor:match("%s") then
		local spaces = std.utf.find_all_spaces(line_from_cursor)
		local next_space = spaces[1] or math.huge
		if self.cursor + next_space < self:max_width() then
			self.cursor = self.cursor + next_space
			return true
		end
	end
	return false
end

local sync_cursor = function(self)
	local pl = self:prompt_len()
	term.go(self.__cfg.l, self.__cfg.c + pl + self.cursor - 1)
end

local insert = function(self, char)
	local line_len = std.utf.len(self.lines[self.line])
	local pos = self.offset + self.cursor

	-- The simplest case first: we are right after the last character in the line
	-- or in the very beginning of an empty line
	if pos == line_len + 1 then
		self.lines[self.line] = self.lines[self.line] .. char
		if pos <= self:max_width() then
			term.hide_cursor()
			self:clear_completion()
			term.write(char)
			self:cursor_right()
			self:search_completion()
			self:draw_completion()
			-- Ensure terminal cursor is positioned correctly when no new completion is drawn
			-- This fixes the bug where cursor doesn't move on the last character of a completion,
			-- but it's kinda an ad hoc solution...
			if self.last_completion == 0 then
				self:sync_cursor()
			end
			term.show_cursor()
			return false
		end
		self:cursor_right()
		return true
	end

	-- We are at the position of the last character or before
	if pos <= line_len then
		local p = std.utf.sub(self.lines[self.line], 1, pos - 1)
		local s = std.utf.sub(self.lines[self.line], pos, line_len)
		self.lines[self.line] = p .. char .. s
		self:cursor_right()
		return true
	end
end

local backspace = function(self)
	local line_len = std.utf.len(self.lines[self.line])
	local pos = self.offset + self.cursor

	if pos == 1 and line_len == 0 and self.line > 1 then
		table.remove(self.lines, self.line)
		self.line = self.line - 1
		self:end_of_line()
		return true
	end

	if (pos == line_len + 1 or pos == line_len) and line_len > 0 then
		self:clear_completion()
		self.lines[self.line] = std.utf.sub(self.lines[self.line], 1, pos - 2)
		if self.cursor > 1 then
			self:cursor_left()
			term.write("\b \b")
			return false
		end
		self:cursor_left()
		return true
	end

	if pos <= line_len and pos > 1 then
		local p = std.utf.sub(self.lines[self.line], 1, pos - 2)
		local s = std.utf.sub(self.lines[self.line], pos, line_len)
		self.lines[self.line] = p .. s
		self:cursor_left()
		return true
	end
end

local scroll_completion = function(self, direction)
	if not self.completion or not self.completion:available() then
		return false
	end

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
	term.hide_cursor()
	self:draw_completion()
	term.show_cursor()
	return false
end

local promote_completion = function(self)
	if not self.completion or not self.completion:available() then
		return false
	end

	local promoted = self.completion:get(true)
	local metadata = self.completion.__meta[self.completion.__chosen]

	if metadata.replace_prompt then
		if metadata.trim_promotion then
			promoted = promoted:gsub("^%s+", "")
		elseif metadata.reduce_spaces then
			promoted = promoted:gsub("(%s+)", " ")
		end
		-- For now let's assume that completions work on one line level...
		self.lines[self.line] = metadata.replace_prompt .. promoted
	else
		self.lines[self.line] = self.lines[self.line] .. promoted
	end
	self.completion:flush()
	if metadata.exec_on_prom then
		self:add_to_history()
		self:clear_from_prompt()
		term.write(self.lines[self.line])
		return "execute"
	end
	self:end_of_line()
	return true
end

local search_completion = function(self)
	if not self.completion then
		return false
	end
	-- once again, we've chosen to do it on line level
	-- not really sure how it will play out =)
	if self.lines[self.line]:match("%s$") then
		self.completion:flush()
		return false
	end
	return self.completion:search(self.lines[self.line], self.history)
end

local external_editor = function(self)
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
	self.lines = std.txt.lines(result)
	self.line = #self.lines
	self:end_of_line()
	self:display()
end

local insert_last_arg = function(self)
	if not self.history or #self.history.entries == 0 then
		return false
	end

	local last_arg = self.history:last_arg()
	if not last_arg or last_arg == "" then
		return false
	end

	-- Insert the last arg at cursor position
	local pos = self.offset + self.cursor
	local line_len = std.utf.len(self.lines[self.line])
	local p = std.utf.sub(self.lines[self.line], 1, pos - 1)
	local s = std.utf.sub(self.lines[self.line], pos, line_len)
	self.lines[self.line] = p .. last_arg .. s

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
		-- Config & State
		__cfg = config,
		lines = { "" },
		line = 1,
		cursor = 1,
		offset = 0,
		last_completion = 0,
		tab_long = false,
		-- Tab state
		tab_state = {
			start = nil,
			last_release = nil,
			long = false,
			double_tap = false,
		},
		-- Optional objects
		completion = config.completion,
		history = config.history,
		prompt = config.prompt,
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
		sync_cursor = sync_cursor,
		full_redraw = full_redraw,
		display = function(self)
			term.hide_cursor()
			self:full_redraw()
			term.show_cursor()
		end,
		buffer_empty = function(self)
			if #self.lines == 1 and self.lines[1] == "" then
				return true
			end
			return false
		end,
		prompt_len = function(self)
			local len = 0
			local prompt = ""
			if self.prompt then
				prompt = self.prompt:get() or ""
				len = std.utf.len(prompt)
			end
			return len, prompt
		end,
		max_width = function(self)
			local available_width = self.__cfg.w - self.__cfg.c - self:prompt_len()
			local width = math.min(self.__cfg.width, self.__cfg.w)
			return math.min(available_width, width)
		end,
		update_window_size = function(self, h, w)
			self.__cfg.h = h
			self.__cfg.w = w
			-- Adjust visible width if needed
			if w < self.__cfg.width then
				self.__cfg.width = w
			end
			-- Ensure cursor position is valid
			local max_w = self:max_width()
			if self.cursor > max_w then
				self.cursor = max_w
				local line_len = std.utf.len(self.lines[self.line])
				if line_len > max_w then
					-- offset is 0-indexed: position in buffer = offset + cursor
					self.offset = math.max(0, line_len - max_w + 1)
				end
			end
		end,
		set_position = function(self, l, c)
			if type(l) == "number" then
				self.__cfg.l = l
			end
			if type(c) == "number" then
				self.__cfg.c = c
			end
		end,
		get_content = function(self)
			return table.concat(self.lines, "\n")
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
		add_to_history = function(self)
			if self.history and not self:buffer_empty() then
				self.history:add(self:get_content())
			end
		end,
		history_up = function(self)
			if not self.history then
				return false
			end
			if self.history:up() then
				if not self:buffer_empty() and self.history.position == #self.history.entries then
					self.history:stash(self:get_content())
				end
				self.lines = std.txt.lines(self.history:get())
				self.line = #self.lines
				self:end_of_line()
				return true
			end
			return false
		end,
		history_down = function(self)
			if not self.history then
				return false
			end
			if self.history:down() then
				self.lines = std.txt.lines(self.history:get())
				self.line = #self.lines
				self:end_of_line()
				return true
			end
		end,
		end_of_line = function(self)
			local line_len = std.utf.len(self.lines[self.line])
			local mw = self:max_width()
			if line_len < mw then
				-- cursor is 1-indexed: position after last character
				self.cursor = line_len + 1
			else
				-- offset is 0-indexed: position in buffer = offset + cursor
				-- cursor at max width, offset adjusted to show end of line
				self.offset = line_len - mw + 1
				self.cursor = mw
			end
			return true
		end,
		start_of_line = function(self)
			-- Move to beginning: cursor at position 1, no horizontal scroll
			self.cursor = 1
			self.offset = 0 -- offset is 0-indexed
			return true
		end,
		flush = function(self)
			self.lines = { "" }
			self.line = 1
			self.offset = 0
			self.cursor = 1
			if self.completion then
				self.completion:flush()
				self.last_completion = 0
			end
		end,
	}
	return input
end

return { new = new }
