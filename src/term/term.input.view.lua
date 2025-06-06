local term = require("term")
local std = require("std")

local new = function(input_obj)
	local view = {
		input = input_obj,

		update_cursor = function(self)
			local prompt_len = self:get_prompt_info()
			term.go(self.input.config.l, self.input.config.c + self.input.cursor + prompt_len)
		end,

		get_prompt_info = function(self)
			local prompt = ""
			local prompt_len = 0
			if self.input.prompt then
				prompt_len, prompt = self.input:prompt_len()
			end
			return prompt_len, prompt
		end,

		draw_prompt = function(self)
			local prompt_len, prompt = self:get_prompt_info()
			if prompt_len > 0 then
				term.go(self.input.config.l, self.input.config.c)
				term.write(prompt)
			end
			return prompt_len
		end,

		draw_content = function(self, content)
			if self.input.config.escape_newlines then
				content = content:gsub("\n", "␤")
			end
			term.write(self.input.config.tss:apply("input", content))
		end,

		draw_completion = function(self)
			if self.input.completion and self.input.completion:available() then
				local completion = self.input.completion:get()
				if completion ~= "" then
					term.write(self.input.config.tss:apply("completion", completion))
				end
			end
		end,

		clear_line = function(self, mode, max_width)
			local mode = mode or "all"
			local width = self.input:max_visible_width()
			local prompt_len = self:get_prompt_info()
			local blank = self.input.config.tss:apply("input.blank", self.input.config.blank)
			local buf_len = std.utf.len(self.input.buffer)
			if self.input.last_op.len then
				buf_len = self.input.last_op.len
			end

			local count = buf_len + prompt_len
			local start = self.input.config.c

			if max_width then
				count = width
			end

			if mode == "from_prompt" then
				start = start + prompt_len
				count = count - prompt_len
			end

			if mode == "from_cursor" then
				start = start + prompt_len + self.input.cursor
				count = count - prompt_len - self.input.cursor
			end

			-- Not used anywhere so far, shall we delete it?..
			if mode == "from_position" then
				start = start + prompt_len + self.input.last_op.position
				count = count - prompt_len - self.input.last_op.position
			end

			if self.input.completion then
				local completion_len = std.utf.len(self.input.completion:get())
				count = count + completion_len
			end

			if self.input.last_op.type == self.input.OP.DELETE then
				-- account for the deleted from the buffer,
				-- but not yet cleared character
				count = count + 1
			end

			count = math.min(width, count)
			term.go(self.input.config.l, start)
			term.write(string.rep(blank, count))
			self:update_cursor()
		end,

		clear_completion = function(self, completion)
			if self.input.completion then
				local completion = completion or self.input.completion:get()
				if completion ~= "" then
					local prompt_len = self:get_prompt_info()
					local count = std.utf.len(completion)
					local blank = self.input.config.tss:apply("input.blank", self.input.config.blank)
					term.go(self.input.config.l, self.input.config.c + self.input.cursor + prompt_len)
					term.write(string.rep(blank, count))
					self:update_cursor()
				end
			end
		end,

		handle_redraw = function(self, mode)
			local mode = mode or "partial"
			term.hide_cursor()
			if mode == "full" then
				self:clear_line("all", true)
				self:draw_prompt()
			elseif mode == "partial" then
				self:clear_line("from_prompt")
			else
				self:clear_line("from_prompt", true)
				self.input:start_of_line()
				self:update_cursor()
			end
			local max = self.input:max_visible_width()
			local buf_len = std.utf.len(self.input.buffer)
			local visible_end = math.min(max - 1, buf_len)

			-- if visible_end >= self.input.position then
			local content = std.utf.sub(self.input.buffer, self.input.position, visible_end)
			if content and #content > 0 then
				self:draw_content(content)
			end
			-- end
			term.show_cursor()
		end,

		handle_completion = function(self)
			if self.input.completion then
				local previous_completion = self.input.completion:get()
				term.hide_cursor()
				if self.input:search_completion() then
					local new_completion = self.input.completion:get()
					if new_completion ~= previous_completion then
						self:clear_completion(previous_completion)
						self:draw_completion()
						self:update_cursor()
					end
				else
					self:clear_completion(previous_completion)
				end
				term.show_cursor()
			end
		end,

		handle_completion_promotion = function(self, full)
			local max = self.input:max_visible_width()
			local buf_len = std.utf.len(self.input.buffer)
			local visible_end = math.min(max - 1, buf_len)
			if full then
				self:clear_completion(self.input.last_op.completion)
				self.input:start_of_line()
				self:clear_line("from_prompt")
			end
			local content = std.utf.sub(self.input.buffer, self.input.position + self.input.cursor, visible_end)
			if content and #content > 0 then
				self:draw_content(content)
				self.input:end_of_line()
			end
		end,

		handle_completion_scroll = function(self)
			term.hide_cursor()
			self:clear_completion(self.input.last_op.completion)
			self:draw_completion()
			self:update_cursor()
			term.show_cursor()
		end,

		handle_insert = function(self)
			local pos = self.input.last_op.position
			local max = self.input:max_visible_width()
			local buf_len = std.utf.len(self.input.buffer)

			-- If we're at the end of the input, but not at the end of the visible part,
			-- we don't clear the line
			if pos >= buf_len and self.input.cursor < max then
				local char = std.utf.sub(self.input.buffer, pos, pos)
				self:draw_content(char)
				return
			end

			-- For insertion in the middle or at max:
			-- Clear from cursor to end and redraw the affected part
			term.hide_cursor()
			self:clear_line("from_cursor") -- clear from cursor to end
			local visible_end = math.min(self.input.position + max - 1, buf_len)
			local content = std.utf.sub(self.input.buffer, pos, visible_end)
			term.move("left")
			self:draw_content(content)
			self:update_cursor()
			term.show_cursor()
		end,

		handle_delete = function(self)
			local pos = self.input.last_op.position
			local buf_len = std.utf.len(self.input.buffer)
			local max = self.input:max_visible_width()

			-- If we deleted from the end, then we are done
			if pos >= buf_len then
				self:clear_line("from_cursor")
				return
			end
			term.hide_cursor()
			self:clear_line("from_cursor")
			-- For deletion in the middle:
			local visible_end = math.min(self.input.position + max, buf_len)
			local content = std.utf.sub(self.input.buffer, pos, visible_end)
			self:draw_content(content)
			self:update_cursor()
			term.show_cursor()
		end,

		-- Main display method that checks last operation and renders accordingly
		display = function(self, force_redraw)
			local force_redraw = force_redraw or false

			-- Check if we need to redraw prompt based on operation type
			if self.input.last_op.type == self.input.OP.FULL_CHANGE then
				force_redraw = true
			end

			if force_redraw then
				self:handle_redraw("full")
				return true
			end

			local op = self.input.last_op
			if op.type == self.input.OP.INSERT then
				self:handle_insert()
				self:handle_completion()
			elseif op.type == self.input.OP.DELETE then
				self:handle_delete()
			elseif op.type == self.input.OP.CURSOR_MOVE then
				self:update_cursor()
			elseif op.type == self.input.OP.COMPLETION_PROMOTION then
				self:handle_completion_promotion()
			elseif op.type == self.input.OP.COMPLETION_PROMOTION_FULL then
				self:handle_completion_promotion(true)
			elseif op.type == self.input.OP.HISTORY_SCROLL then
				self:handle_redraw()
				self.input:end_of_line()
			elseif op.type == self.input.OP.COMPLETION_SCROLL then
				self:handle_completion_scroll()
			elseif op.type == self.input.OP.POSITION_CHANGE then
				self:handle_redraw("with_cursor")
				self.input:end_of_line()
			elseif op.type == self.input.OP.FULL_CHANGE then
				self:handle_redraw("full")
				self:handle_completion()
			end
		end,
	}
	return view
end

return { new = new }
