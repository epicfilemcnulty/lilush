-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
Stream buffer for LLM response streaming with code block detection.

Text outside code blocks is emitted immediately.
Code blocks (``` fenced) are buffered until complete.
]]

local buffer = require("string.buffer")

local function new(opts)
	opts = opts or {}

	local self = {
		on_text = opts.on_text or function() end,
		on_code = opts.on_code or function() end,

		-- State: "text" or "code"
		state = "text",

		-- Buffer for code blocks
		code_buf = buffer.new(),
		code_lang = nil,

		-- Track if we're still waiting for the language line to complete
		-- (fence was found but newline after language hasn't arrived yet)
		lang_pending = false,

		-- Track if we've emitted any output (for adding separators)
		has_output = false,
	}

	function self:push(chunk)
		if not chunk or chunk == "" then
			return
		end

		if self.state == "text" then
			self:_push_text(chunk)
		else
			self:_push_code(chunk)
		end
	end

	function self:_push_text(chunk)
		-- Look for opening fence
		local fence_start = chunk:find("```")
		if not fence_start then
			-- No fence, emit immediately
			self.on_text(chunk)
			self.has_output = true
			return
		end

		-- Check if fence is at line start (position 1 or after newline)
		local at_line_start = (fence_start == 1) or (chunk:sub(fence_start - 1, fence_start - 1) == "\n")
		if not at_line_start then
			-- Not a real fence (e.g. inline code), emit all
			self.on_text(chunk)
			self.has_output = true
			return
		end

		-- Look for newline after fence to get language
		local line_end = chunk:find("\n", fence_start + 3)
		if not line_end then
			-- Incomplete fence line - buffer the fence part
			local before = chunk:sub(1, fence_start - 1)
			if before ~= "" then
				self.on_text(before)
				self.has_output = true
			end
			self.state = "code"
			self.code_lang = chunk:sub(fence_start + 3) -- partial lang, might be empty or incomplete
			self.lang_pending = true -- still waiting for newline to complete language line
			self.code_buf = buffer.new()
			return
		end

		-- Complete opening fence found
		local before = chunk:sub(1, fence_start - 1)
		if before ~= "" then
			self.on_text(before)
			self.has_output = true
		end

		local lang = chunk:sub(fence_start + 3, line_end - 1)
		self.state = "code"
		self.code_lang = lang ~= "" and lang or nil
		self.lang_pending = false
		self.code_buf = buffer.new()

		-- Process rest as code
		local rest = chunk:sub(line_end + 1)
		if rest ~= "" then
			self:_push_code(rest)
		end
	end

	function self:_push_code(chunk)
		-- If we're still waiting for the language line to complete,
		-- check if this chunk contains the newline
		if self.lang_pending then
			local line_end = chunk:find("\n")
			if not line_end then
				-- Still no newline, append to partial language
				self.code_lang = (self.code_lang or "") .. chunk
				return
			end
			-- Complete the language line
			local lang_rest = chunk:sub(1, line_end - 1)
			self.code_lang = (self.code_lang or "") .. lang_rest
			if self.code_lang == "" then
				self.code_lang = nil
			end
			self.lang_pending = false
			-- Continue with the rest as code content
			chunk = chunk:sub(line_end + 1)
			if chunk == "" then
				return
			end
		end

		self.code_buf:put(chunk)

		-- Check for closing fence
		local text = self.code_buf:get()

		-- Look for ``` at start of line
		local i = 1
		while i <= #text - 2 do
			local at_line_start = (i == 1) or (text:sub(i - 1, i - 1) == "\n")

			if at_line_start and text:sub(i, i + 2) == "```" then
				-- Check if followed by newline or end
				local after = text:sub(i + 3, i + 3)
				if after == "" or after == "\n" then
					-- Complete closing fence
					local code = text:sub(1, i - 1)
					if code:sub(-1) == "\n" then
						code = code:sub(1, -2)
					end

					self.on_code(self.code_lang, code)
					self.has_output = true

					self.state = "text"
					self.code_lang = nil
					self.code_buf = buffer.new()

					-- Continue with rest as text
					local rest = text:sub(i + 3 + (after == "\n" and 1 or 0))
					if rest ~= "" then
						self:_push_text(rest)
					end
					return
				end
			end

			i = i + 1
		end

		-- No closing fence, keep buffering
		self.code_buf = buffer.new()
		self.code_buf:put(text)
	end

	function self:flush()
		if self.state == "code" then
			local code = self.code_buf:get()
			if code ~= "" then
				if code:sub(-1) == "\n" then
					code = code:sub(1, -2)
				end
				self.on_code(self.code_lang, code)
				self.has_output = true
			end
			self.code_buf = buffer.new()
			self.code_lang = nil
			self.lang_pending = false
			self.state = "text"
		end
	end

	-- Check if output was emitted and reset the flag
	function self:had_output()
		local had = self.has_output
		self.has_output = false
		return had
	end

	function self:reset()
		self.state = "text"
		self.code_buf = buffer.new()
		self.code_lang = nil
		self.lang_pending = false
		self.has_output = false
	end

	return self
end

return { new = new }
