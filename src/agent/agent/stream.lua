-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Stream buffer for LLM response streaming with code block detection.

Text outside code blocks is emitted immediately.
Code blocks (``` fenced) are buffered until complete.
]]

local buffer = require("string.buffer")

local push_text
local push_code

local push = function(self, chunk)
	if not chunk or chunk == "" then
		return
	end

	if self.__state.state == "text" then
		self._push_text(self, chunk)
	else
		self._push_code(self, chunk)
	end
end

push_text = function(self, chunk)
	local state = self.__state
	local cfg = self.cfg

	-- Look for opening fence
	local fence_start = chunk:find("```")
	if not fence_start then
		-- No fence, emit immediately
		cfg.on_text(chunk)
		state.has_output = true
		return
	end

	-- Check if fence is at line start (position 1 or after newline)
	local at_line_start = (fence_start == 1) or (chunk:sub(fence_start - 1, fence_start - 1) == "\n")
	if not at_line_start then
		-- Not a real fence (e.g. inline code), emit all
		cfg.on_text(chunk)
		state.has_output = true
		return
	end

	-- Look for newline after fence to get language
	local line_end = chunk:find("\n", fence_start + 3)
	if not line_end then
		-- Incomplete fence line - buffer the fence part
		local before = chunk:sub(1, fence_start - 1)
		if before ~= "" then
			cfg.on_text(before)
			state.has_output = true
		end
		state.state = "code"
		state.code_lang = chunk:sub(fence_start + 3) -- partial lang, might be empty or incomplete
		state.lang_pending = true -- still waiting for newline to complete language line
		state.code_buf = buffer.new()
		return
	end

	-- Complete opening fence found
	local before = chunk:sub(1, fence_start - 1)
	if before ~= "" then
		cfg.on_text(before)
		state.has_output = true
	end

	local lang = chunk:sub(fence_start + 3, line_end - 1)
	state.state = "code"
	state.code_lang = lang ~= "" and lang or nil
	state.lang_pending = false
	state.code_buf = buffer.new()

	-- Process rest as code
	local rest = chunk:sub(line_end + 1)
	if rest ~= "" then
		self._push_code(self, rest)
	end
end

push_code = function(self, chunk)
	local state = self.__state
	local cfg = self.cfg

	-- If we're still waiting for the language line to complete,
	-- check if this chunk contains the newline
	if state.lang_pending then
		local line_end = chunk:find("\n")
		if not line_end then
			-- Still no newline, append to partial language
			state.code_lang = (state.code_lang or "") .. chunk
			return
		end
		-- Complete the language line
		local lang_rest = chunk:sub(1, line_end - 1)
		state.code_lang = (state.code_lang or "") .. lang_rest
		if state.code_lang == "" then
			state.code_lang = nil
		end
		state.lang_pending = false
		-- Continue with the rest as code content
		chunk = chunk:sub(line_end + 1)
		if chunk == "" then
			return
		end
	end

	state.code_buf:put(chunk)

	-- Check for closing fence
	local text = state.code_buf:get()

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

				cfg.on_code(state.code_lang, code)
				state.has_output = true

				state.state = "text"
				state.code_lang = nil
				state.code_buf = buffer.new()

				-- Continue with rest as text
				local rest = text:sub(i + 3 + (after == "\n" and 1 or 0))
				if rest ~= "" then
					self._push_text(self, rest)
				end
				return
			end
		end

		i = i + 1
	end

	-- No closing fence, keep buffering
	state.code_buf = buffer.new()
	state.code_buf:put(text)
end

local flush = function(self)
	local state = self.__state

	if state.state == "code" then
		local code = state.code_buf:get()
		if code ~= "" then
			if code:sub(-1) == "\n" then
				code = code:sub(1, -2)
			end
			self.cfg.on_code(state.code_lang, code)
			state.has_output = true
		end
		state.code_buf = buffer.new()
		state.code_lang = nil
		state.lang_pending = false
		state.state = "text"
	end
end

-- Check if output was emitted and reset the flag
local had_output = function(self)
	local state = self.__state
	local had = state.has_output
	state.has_output = false
	return had
end

local reset = function(self)
	local state = self.__state
	state.state = "text"
	state.code_buf = buffer.new()
	state.code_lang = nil
	state.lang_pending = false
	state.has_output = false
end

local function new(opts)
	opts = opts or {}

	local instance = {
		cfg = {
			on_text = opts.on_text or function() end,
			on_code = opts.on_code or function() end,
		},
		__state = {
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
		},
		push = push,
		_push_text = push_text,
		_push_code = push_code,
		flush = flush,
		had_output = had_output,
		reset = reset,
	}

	return instance
end

return { new = new }
