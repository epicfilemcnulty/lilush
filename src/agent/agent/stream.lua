-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Markdown streaming bridge for agent output.

Feeds chunked LLM text into the markdown parser and streaming renderer.
]]

local term = require("term")
local parser_mod = require("markdown.parser")
local renderer_mod = require("markdown.renderer.streaming")

local init_pipeline

local detect_width = function()
	if term and type(term.window_size) == "function" then
		local _, width = term.window_size()
		if type(width) == "number" and width > 0 then
			return width
		end
	end
	return 80
end

init_pipeline = function(self)
	local state = self.__state
	local cfg = self.cfg

	local renderer = renderer_mod.new({
		width = cfg.width,
		rss = cfg.rss,
		supports_ts = cfg.supports_ts,
		output_fn = function(text)
			if text and text ~= "" then
				state.has_output = true
				cfg.output_fn(text)
			end
		end,
	})

	local parser = parser_mod.new({
		on_event = function(event)
			renderer:render_event(event)
		end,
		inline = true,
		-- Prefer correctness over aggressive incremental inline parsing in agent output.
		streaming_inline = false,
	})

	state.renderer = renderer
	state.parser = parser
end

local push = function(self, chunk)
	if not chunk or chunk == "" then
		return
	end

	local state = self.__state
	state.parser:feed(chunk)
end

local checkpoint = function(self)
	local state = self.__state
	if state.renderer then
		state.renderer:finish()
	end
end

local finalize = function(self)
	local state = self.__state
	if state.parser then
		state.parser:finish()
	end
	if state.renderer then
		state.renderer:finish()
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
	self.__state.has_output = false
	init_pipeline(self)
end

local function new(opts)
	opts = opts or {}

	local width = opts.width or detect_width()

	local instance = {
		cfg = {
			width = width,
			rss = opts.rss,
			supports_ts = opts.supports_ts,
			output_fn = opts.output_fn or io.write,
		},
		__state = {
			has_output = false,
			parser = nil,
			renderer = nil,
		},
		push = push,
		checkpoint = checkpoint,
		finalize = finalize,
		had_output = had_output,
		reset = reset,
	}

	init_pipeline(instance)

	return instance
end

return { new = new }
