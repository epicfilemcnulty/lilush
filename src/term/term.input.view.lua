local term = require("term")
local std = require("std")
local state = require("term.input.state")

local new = function(state_obj)
	local view = {
		state = state_obj,

		get_prompt_info = function(self)
			local prompt = ""
			local prompt_len = 0
			if self.state.prompt then
				prompt_len, prompt = self.state:prompt_len()
			end
			return prompt_len, prompt
		end,

		draw_content = function(self, content)
			if self.state.config.escape_newlines then
				content = content:gsub("\n", "␊")
			end
			if self.state.config.tss then
				term.write(self.state.config.tss:apply("input", content))
			else
				term.write(content)
			end
		end,

		draw_completion = function(self)
			if self.state.completion and self.state.completion:available() then
				local completion = self.state.completion:get()
				if completion ~= "" then
					term.clear_line(0) -- from cursor till the EOL
					if self.state.config.tss then
						term.write(self.state.config.tss:apply("completion", completion))
					else
						term.write(completion)
					end
					self:update_cursor()
				end
			end
		end,

		handle_completion = function(self)
			if self.state.completion then
				self.state.completion:search(self.state.buffer, self.state.history)
				self:draw_completion()
			end
		end,

		update_cursor = function(self)
			local prompt_len = self:get_prompt_info()
			term.go(self.state.config.l, self.state.config.c + self.state.cursor + prompt_len)
		end,

		handle_insert = function(self, pos)
			local prompt_len = self:get_prompt_info()
			local max = self.state:max_visible_width()
			local buf_len = std.utf.len(self.state.buffer)

			-- If we're at the end of the visible buffer, just write the new char
			if pos >= buf_len then
				local char = std.utf.sub(self.state.buffer, pos, pos)
				self:draw_content(char)
				self:update_cursor()
				return
			end

			-- For insertion in the middle:
			-- Clear from cursor to end and redraw the affected part
			term.clear_line(0) -- clear from cursor to end
			local visible_end = math.min(self.state.position + max, buf_len)
			local content = std.utf.sub(self.state.buffer, pos, visible_end)
			self:draw_content(content)
			self:draw_completion()
			self:update_cursor()
		end,

		handle_delete = function(self, pos)
			local buf_len = std.utf.len(self.state.buffer)
			local max = self.state:max_visible_width()

			-- If we deleted from the end, just clear one char
			if pos >= buf_len then
				term.move("left")
				term.clear_line(0)
				self:draw_completion()
				return
			end

			-- For deletion in the middle:
			-- Clear from deletion point to end and redraw
			term.move("left")
			term.clear_line(0)
			local visible_end = math.min(self.state.position + max, buf_len)
			local content = std.utf.sub(self.state.buffer, pos, visible_end)
			self:draw_content(content)
			self:draw_completion()
			self:update_cursor()
		end,

		full_redraw = function(self, redraw_prompt)
			-- First, let's clear everything
			term.clear_line(2) -- Clear entire line

			local prompt_len, prompt = self:get_prompt_info()

			if redraw_prompt and prompt_len > 0 then
				-- Position cursor and write prompt
				term.go(self.state.config.l, self.state.config.c)
				term.write(prompt)
			end

			-- Position for content
			term.go(self.state.config.l, self.state.config.c + prompt_len)

			local max = self.state:max_visible_width()
			local buf_len = std.utf.len(self.state.buffer)
			local visible_end = math.min(self.state.position + max - 1, buf_len)

			if visible_end >= self.state.position then
				local content = std.utf.sub(self.state.buffer, self.state.position, visible_end)
				if content and #content > 0 then
					self:draw_content(content)
				end
			end

			self:draw_completion()
			self:update_cursor()
		end,
		-- Main display method that checks last operation and renders accordingly
		display = function(self, force_redraw)
			local needs_prompt = force_redraw

			-- Check if we need to redraw prompt based on operation type
			if self.state.last_op.type == state.OP.FULL_CHANGE then
				needs_prompt = true
			end

			-- Check if cursor moved to new line
			if self.state.last_op.type == state.OP.CURSOR_MOVE then
				local old_line = self.state.last_op.last_line
				if old_line and old_line ~= self.state.config.l then
					needs_prompt = true
				end
			end
			if needs_prompt then
				return self:full_redraw(true)
			end

			local op = self.state.last_op
			if op.type == state.OP.INSERT then
				self:handle_insert(op.position)
				self:handle_completion()
			elseif op.type == state.OP.DELETE then
				self:handle_delete(op.position)
				self:handle_completion()
			elseif op.type == state.OP.CURSOR_MOVE then
				self:update_cursor()
			elseif op.type == state.OP.FULL_CHANGE then
				self:full_redraw(false)
				self:handle_completion()
			end
		end,
	}
	return view
end

return { new = new }
