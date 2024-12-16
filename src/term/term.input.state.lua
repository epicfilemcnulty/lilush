local std = require("std")

-- Enum for operation types
local OP = {
	NONE = 0,
	INSERT = 1,
	DELETE = 2,
	CURSOR_MOVE = 3,
	FULL_CHANGE = 4, -- for history navigation, etc.
	COMPLETION_PROMOTION = 5,
	COMPLETION_SCROLL = 6,
	HISTORY_SCROLL = 7,
}

local new = function(config)
	local state = {
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
			position = 0, -- position in buffer where operation occurred
			last_line = config.l,
		},

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
			local max = self.config.width or self.window.w
			if self.prompt and self.prompt.get then
				return max - std.utf.len(self.prompt:get())
			end
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
			local max_width = self:max_visible_width()
			local buf_len = std.utf.len(self.buffer)

			if new_cursor < 0 then
				new_cursor = 0
			elseif new_cursor > buf_len then
				new_cursor = buf_len
			end

			self.last_op = { type = OP.CURSOR_MOVE }
			-- Adjust position if cursor would go beyond visible area
			if new_cursor > max_width then
				self.position = self.position + (new_cursor - max_width)
				self.cursor = max_width
				self.last_op = { type = OP.FULL_CHANGE }
			else
				self.cursor = new_cursor
			end
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

			if self.cursor == 0 then
				if self.position == 1 then
					self.buffer = char .. self.buffer
				else
					self.buffer = std.utf.sub(self.buffer, 1, self.position)
						.. char
						.. std.utf.sub(self.buffer, self.position + 1)
				end
				self.cursor = 1
				self.last_op = { type = OP.INSERT, position = 1 }
				return true
			end

			if buf_len == insert_pos then
				self.buffer = self.buffer .. char
				self.cursor = self.cursor + 1
				self.last_op = { type = OP.INSERT, position = insert_pos + 1 }
				return true
			end

			self.buffer = std.utf.sub(self.buffer, 1, insert_pos) .. char .. std.utf.sub(self.buffer, insert_pos + 1)
			self.cursor = self.cursor + 1
			self.last_op = { type = OP.INSERT, position = insert_pos + 1 }
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

			if self.cursor == 0 then
				if self.position > 1 then
					-- Move position back and delete from there
					self.position = self.position - 1
					delete_pos = self.position
					self.buffer = std.utf.sub(self.buffer, 1, delete_pos - 1)
						.. std.utf.sub(self.buffer, delete_pos + 1)
					self.last_op = { type = OP.DELETE, position = delete_pos }
					return true
				end
				return false
			end

			if delete_pos == buf_len then
				self.buffer = std.utf.sub(self.buffer, 1, buf_len - 1)
				self.cursor = self.cursor - 1
				self.last_op = { type = OP.DELETE, position = delete_pos }
				return true
			end

			self.buffer = std.utf.sub(self.buffer, 1, delete_pos - 1) .. std.utf.sub(self.buffer, delete_pos + 1)
			self.cursor = self.cursor - 1
			self.last_op = { type = OP.DELETE, position = delete_pos }
			return true
		end,

		move_left = function(self)
			if self.cursor > 0 then
				self:update_cursor(self.cursor - 1)
				return true
			elseif self.position > 1 then
				self.position = self.position - 1
				self.last_op = { type = OP.CURSOR_MOVE }
				return true
			end
			return false
		end,

		move_right = function(self)
			local buf_len = std.utf.len(self.buffer)
			if self.position + self.cursor - 1 < buf_len then
				self:update_cursor(self.cursor + 1)
				return true
			end
			return false
		end,

		end_of_line = function(self)
			-- TODO: Check if we are already at the end of the line
			local buf_len = std.utf.len(self.buffer)
			local max = self:max_visible_width()
			self.position = 1
			self:update_cursor(buf_len)
			return true
		end,

		start_of_line = function(self)
			if self.cursor > 0 then
				self.position = 1
				self:update_cursor(0)
				return true
			end
			return false
		end,

		history_up = function(self)
			if not self.history then
				return false
			end

			if self.history:up() then
				if #self.buffer > 0 and self.history.position == #self.history.entries then
					self.history:stash(self.buffer)
				end
				self.buffer = self.history:get()
				self.cursor = std.utf.len(self.buffer)
				self.position = 1
				self.last_op = { type = OP.HISTORY_SCROLL }
				return true
			end
			return false
		end,

		history_down = function(self)
			if not self.history then
				return false
			end

			if self.history:down() then
				self.buffer = self.history:get()
				self.cursor = std.utf.len(self.buffer)
				self.position = 1
				self.last_op = { type = OP.HISTORY_SCROLL }
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
			self.last_op = { type = OP.COMPLETION_SCROLL }
			return true
		end,

		promote_completion = function(self)
			if not self.completion or not self.completion:available() then
				return false
			end

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
			self.cursor = std.utf.len(self.buffer)
			self.position = 1
			self.last_op = { type = OP.COMPLETION_PROMOTION }
			return metadata.exec_on_prom and "execute" or true
		end,

		search_completion = function(self)
			if not self.completion then
				return false
			end
			self.completion:search(self.buffer, self.history)
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
			self.last_op = { type = OP.FULL_CHANGE }
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
						type = OP.FULL_CHANGE, -- Changed from CURSOR_MOVE to FULL_CHANGE
						last_line = self.config.l - 1, -- Store previous line
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
	}
	return state
end

return { new = new, OP = OP }
