-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Agent mode prompt.

Displays:
- Mode indicator with provider/model
- Current working directory
- Token usage
- Optional status indicators
]]

local std = require("std")
local buffer = require("string.buffer")
local style = require("term.tss")
local theme = require("theme").get("agent")
local conversation_mod = require("agent.conversation")

local tss = style.new(theme)
local style_text = function(ctx, ...)
	return ctx:apply(...).text
end

-- Format token count for display (e.g., 1234 -> "1.2k")
local function format_tokens(count)
	if count >= 1000000 then
		return string.format("%.1fM", count / 1000000)
	elseif count >= 1000 then
		return string.format("%.1fk", count / 1000)
	else
		return tostring(count)
	end
end

local set = function(self, options)
	local state = self.__state
	options = options or {}
	for k, v in pairs(options) do
		-- Use false as sentinel to clear a value (since pairs() skips nil)
		if v == false and (k == "status" or k == "prompt_name") then
			state[k] = nil
		elseif k == "home" then
			self.cfg.home = v
		else
			state[k] = v
		end
	end
end

local get = function(self)
	local state = self.__state
	local buf = buffer.new()
	local mode_label = state.prompt_name or "Smith"

	-- Mode indicator: [Smith:model] or [prompt_name:model]
	buf:put(style_text(tss, "prompts.agent.mode.prefix"))
	buf:put(style_text(tss, "prompts.agent.mode.label", mode_label))

	if state.model then
		buf:put(style_text(tss, "prompts.agent.sep", ":"))
		buf:put(style_text(tss, "prompts.agent.mode.model", state.model))
	end

	buf:put(style_text(tss, "prompts.agent.mode.suffix"))

	-- Working directory
	local cwd = std.fs.cwd() or "?"
	local home = self.cfg.home or os.getenv("HOME") or ""
	cwd = cwd:gsub("^" .. std.escape_magic_chars(home), "~")

	buf:put(" ")
	buf:put(style_text(tss, "prompts.agent.dir", cwd))

	-- Token count and cost: (12.7k 34% $1.23)
	-- tokens = last context window usage
	local ctx = state.tokens or 0
	if ctx > 0 then
		buf:put(" ")
		buf:put(style_text(tss, "prompts.agent.tokens.prefix"))

		-- Color context tokens and pct based on context window usage
		local ctx_style = "prompts.agent.tokens.count"
		local pct = 0
		if state.max_tokens and state.max_tokens > 0 then
			pct = math.floor((ctx / state.max_tokens) * 100)
			local usage = ctx / state.max_tokens
			if usage > 0.9 then
				ctx_style = "prompts.agent.tokens.critical"
			elseif usage > 0.7 then
				ctx_style = "prompts.agent.tokens.warning"
			end
		end

		-- Context window tokens (color-coded)
		buf:put(style_text(tss, ctx_style, format_tokens(ctx)))

		-- Context percentage
		if state.max_tokens and state.max_tokens > 0 then
			buf:put(style_text(tss, ctx_style, " " .. tostring(pct) .. "%"))
		end

		-- Cost
		if state.cost and state.cost > 0 then
			buf:put(style_text(tss, "prompts.agent.cost.prefix"))
			buf:put(style_text(tss, "prompts.agent.cost.amount", conversation_mod.format_cost(state.cost)))
		end

		buf:put(style_text(tss, "prompts.agent.tokens.suffix"))
	elseif state.cost and state.cost > 0 then
		buf:put(" ")
		buf:put(style_text(tss, "prompts.agent.tokens.prefix"))
		buf:put(style_text(tss, "prompts.agent.cost.amount", conversation_mod.format_cost(state.cost)))
		buf:put(style_text(tss, "prompts.agent.tokens.suffix"))
	end

	-- Status indicator
	if state.status then
		buf:put(" ")
		local status_style = "prompts.agent.status." .. state.status
		buf:put(style_text(tss, status_style))
	end

	-- Multi-line indicator
	if state.lines and state.lines > 1 then
		buf:put(style_text(tss, "prompts.agent.sep", "["))
		buf:put(style_text(tss, "prompts.agent.sep", tostring(state.line or 1)))
		buf:put(style_text(tss, "prompts.agent.sep", "]"))
	end

	-- Cursor (on same line as prompt info)
	buf:put(" ")
	buf:put(style_text(tss, "prompts.agent.cursor"))

	return buf:get()
end

local new = function(options)
	local instance = {
		cfg = {
			home = os.getenv("HOME") or "/tmp",
		},
		__state = {
			model = nil,
			tokens = 0,
			max_tokens = 100000,
			cost = 0, -- Session cost in dollars
			prompt_name = nil, -- Active user prompt name (without extension)
			status = nil, -- nil, "streaming", "thinking", "error"
			lines = 1,
			line = 1,
		},
		get = get,
		set = set,
	}
	instance:set(options)
	return instance
end

return { new = new }
