-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Agent mode prompt.

Displays:
- Mode indicator with backend/model
- Current working directory
- Token usage
- Optional status indicators
]]

local std = require("std")
local buffer = require("string.buffer")
local style = require("term.tss")
local theme = require("theme").get("agent")

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

-- Get the short model name (e.g., "claude-sonnet-4-20250514" -> "sonnet-4")
local function short_model_name(model)
	if not model then
		return "unknown"
	end

	-- Common patterns for model name shortening
	local patterns = {
		-- Anthropic
		{ "claude%-(%w+)%-(%d+)%-", "%1-%2" }, -- claude-sonnet-4-20250514 -> sonnet-4
		{ "claude%-(%d+%.?%d*)%-(%w+)", "%2-%1" }, -- claude-3.5-sonnet -> sonnet-3.5
		{ "claude%-(%w+)", "%1" }, -- claude-opus -> opus
		-- OpenAI
		{ "gpt%-(%d+)%-?(%w*)", "gpt%1%2" }, -- gpt-4-turbo -> gpt4turbo
		{ "gpt%-(%d+)", "gpt%1" }, -- gpt-4 -> gpt4
		-- Generic: take last meaningful segment
		{ ".*/([^/]+)$", "%1" }, -- path/to/model -> model
	}

	for _, p in ipairs(patterns) do
		local short = model:gsub(p[1], p[2])
		if short ~= model then
			return short
		end
	end

	-- Fallback: truncate if too long
	if std.utf.len(model) > 20 then
		return std.utf.sub(model, 1, 17) .. "..."
	end

	return model
end

local set = function(self, options)
	local state = self.__state
	options = options or {}
	for k, v in pairs(options) do
		-- Use false as sentinel to clear a value (since pairs() skips nil)
		if v == false and (k == "status") then
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

	-- Mode indicator: [agent:model]
	buf:put(style_text(tss, "prompts.agent.mode.prefix"))
	buf:put(style_text(tss, "prompts.agent.mode.label"))

	if state.model then
		buf:put(style_text(tss, "prompts.agent.sep", ":"))
		buf:put(style_text(tss, "prompts.agent.mode.model", short_model_name(state.model)))
	end

	buf:put(style_text(tss, "prompts.agent.mode.suffix"))

	-- Working directory
	local cwd = std.fs.cwd() or "?"
	local home = self.cfg.home or os.getenv("HOME") or ""
	cwd = cwd:gsub("^" .. std.escape_magic_chars(home), "~")

	buf:put(" ")
	buf:put(style_text(tss, "prompts.agent.dir", cwd))

	-- Token count and cost
	if state.tokens and state.tokens > 0 then
		buf:put(" ")
		buf:put(style_text(tss, "prompts.agent.tokens.prefix"))

		-- Color based on usage percentage
		local token_style = "prompts.agent.tokens.count"
		if state.max_tokens and state.max_tokens > 0 then
			local usage = state.tokens / state.max_tokens
			if usage > 0.9 then
				token_style = "prompts.agent.tokens.critical"
			elseif usage > 0.7 then
				token_style = "prompts.agent.tokens.warning"
			end
		end

		buf:put(style_text(tss, token_style, format_tokens(state.tokens)))
		buf:put(style_text(tss, "prompts.agent.tokens.unit"))

		-- Show cost if available
		if state.cost and state.cost > 0 then
			local pricing = require("llm.pricing")
			buf:put(style_text(tss, "prompts.agent.cost.prefix"))
			buf:put(style_text(tss, "prompts.agent.cost.amount", pricing.format_cost(state.cost)))
		end

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
			backend = nil,
			tokens = 0,
			max_tokens = 100000,
			cost = 0, -- Session cost in dollars
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
