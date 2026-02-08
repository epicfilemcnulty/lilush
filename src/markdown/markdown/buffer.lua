-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Streaming buffer for chunk boundary handling in markdown inline parsing.

When parsing markdown in streaming mode (e.g., from LLM output), chunks may
arrive at arbitrary boundaries, potentially splitting inline elements:
  - "**bo" + "ld**" should produce strong emphasis
  - "[lin" + "k](url)" should produce a link

This module provides buffering and heuristics to handle such cases:
  1. Buffer incomplete content until we can make decisions
  2. Emit text at safe boundaries (spaces when no unclosed delimiters)
  3. Timeout stale openers that are unlikely to close

The buffer integrates with the inline parser to track opener state and
make intelligent decisions about when to emit partial content.
]]

local inline = require("markdown.inline")

local byte = string.byte
local sub = string.sub
local find = string.find

-- Default configuration
local DEFAULT_CONFIG = {
	-- After this many chars without closing, emit opener as literal
	stale_opener_threshold = 50,
	-- Emit text at word boundaries when no unclosed delimiters
	emit_at_word_boundary = true,
}

-- Check if position is at a safe emission boundary
-- Safe means: at a space, and no unclosed delimiters that might close soon
local function is_safe_boundary(buffer, pos)
	local char = sub(buffer, pos, pos)
	if char ~= " " and char ~= "\t" then
		return false
	end
	return true
end

-- Find potential inline syntax characters that might be unclosed
local function has_unclosed_syntax(text)
	-- Check for potential unclosed emphasis/code/links
	-- This is a heuristic - we look for opening markers without matching closes

	-- Count unmatched backticks (simplified)
	local backtick_count = 0
	local i = 1
	while i <= #text do
		if sub(text, i, i) == "`" then
			local run_start = i
			while i <= #text and sub(text, i, i) == "`" do
				i = i + 1
			end
			local run_len = i - run_start
			-- Toggle: opening adds, closing (same length) subtracts
			-- This is imperfect but catches obvious cases
			backtick_count = backtick_count + 1
		else
			i = i + 1
		end
	end

	if backtick_count % 2 == 1 then
		return true -- Unclosed backtick run
	end

	-- Check for unclosed brackets
	local bracket_depth = 0
	for i = 1, #text do
		local c = sub(text, i, i)
		if c == "[" then
			bracket_depth = bracket_depth + 1
		elseif c == "]" then
			bracket_depth = bracket_depth - 1
		end
	end

	if bracket_depth > 0 then
		return true -- Unclosed brackets
	end

	-- Check for trailing emphasis markers that might be opening
	-- (e.g., "some text **" waiting for more)
	local trimmed = text:match("^(.-)%s*$") or text
	if trimmed:match("[%*_]+$") then
		return true
	end

	return false
end

-- Find the last safe emission point in the buffer
local function find_last_safe_point(text)
	-- If there's unclosed syntax, we can't safely emit
	if has_unclosed_syntax(text) then
		return nil
	end

	-- Find last space/tab
	for i = #text, 1, -1 do
		local c = sub(text, i, i)
		if c == " " or c == "\t" then
			return i
		end
	end

	return nil
end

-- Create a new streaming buffer
-- Options:
--   emit: callback function for events
--   link_refs: table of link reference definitions
--   footnote_tracker: table to track footnote usage
local parse_and_emit = function(self, content)
	if content == "" then
		return
	end

	local parser = inline.new({
		emit = self.__state.emit,
		link_refs = self.__state.link_refs,
		footnote_tracker = self.__state.footnote_tracker,
	})
	parser:parse(content)
	self.__state.chars_since_open = 0
end

local emit_buffered_as_text = function(self)
	if self.__state.buffer ~= "" then
		self.__state.emit({ type = "text", text = self.__state.buffer })
		self.__state.buffer = ""
		self.__state.chars_since_open = 0
	end
end

local feed = function(self, chunk)
	if not chunk or chunk == "" then
		return
	end

	self.__state.buffer = self.__state.buffer .. chunk
	self.__state.chars_since_open = self.__state.chars_since_open + #chunk

	-- First, try to find a safe emission point.
	-- This should happen BEFORE stale opener check so we parse what we can.
	if self.cfg.emit_at_word_boundary then
		local safe_point = find_last_safe_point(self.__state.buffer)
		if safe_point and safe_point > 1 then
			local to_emit = sub(self.__state.buffer, 1, safe_point)
			self.__state.buffer = sub(self.__state.buffer, safe_point + 1)
			parse_and_emit(self, to_emit)
			self.__state.chars_since_open = #self.__state.buffer
		end
	end

	-- Only check for stale openers if we still have buffered content
	-- that couldn't be emitted (likely unclosed syntax).
	if self.__state.chars_since_open > self.cfg.stale_opener_threshold then
		emit_buffered_as_text(self)
	end
end

local flush = function(self)
	if self.__state.buffer ~= "" then
		parse_and_emit(self, self.__state.buffer)
		self.__state.buffer = ""
		self.__state.chars_since_open = 0
	end
end

local reset = function(self)
	self.__state.buffer = ""
	self.__state.chars_since_open = 0
end

local get_buffer = function(self)
	return self.__state.buffer
end

local set_emit = function(self, emit)
	self.__state.emit = emit or function() end
end

local new = function(options)
	options = options or {}
	local cfg = {}
	for k, v in pairs(DEFAULT_CONFIG) do
		cfg[k] = options[k] or v
	end

	return {
		cfg = cfg,
		__state = {
			buffer = "",
			emit = options.emit or function() end,
			link_refs = options.link_refs or {},
			footnote_tracker = options.footnote_tracker or {},
			chars_since_open = 0,
		},
		feed = feed,
		flush = flush,
		reset = reset,
		get_buffer = get_buffer,
		set_emit = set_emit,
	}
end

return { new = new }
