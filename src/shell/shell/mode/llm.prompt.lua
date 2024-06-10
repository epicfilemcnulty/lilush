-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local term = require("term")
local buffer = require("string.buffer")
local theme = require("shell.theme")
local style = require("term.tss")
local tss = style.new(theme)

local llm_prompt = function(self)
	local buf = buffer.new()
	buf:put(tss:apply("prompts.shell.sep", "("), tss:apply("prompts.llm.endpoint.chat"))
	buf:put(tss:apply("prompts.llm.ctx", self.ctx))
	if self.model_name ~= "" then
		buf:put(tss:apply("prompts.llm.model", self.model))
	end
	if self.preset ~= "" then
		buf:put(tss:apply("prompts.llm.preset", self.preset))
	else
		buf:put(tss:apply("prompts.llm.backend", self.backend), tss:apply("prompts.llm.prompt", self.prompt))
	end
	buf:put(tss:apply("prompts.llm.temperature", self.temperature), tss:apply("prompts.llm.tokens", self.tokens))
	buf:put(tss:apply("prompts.llm.rate", string.format("%.2f", self.rate)))
	if self.backend:match("^%u") then
		buf:put(tss:apply("prompts.llm.total_cost", string.format("%.5f", self.total_cost)))
	end
	buf:put(tss:apply("prompts.shell.sep", ")"), "$ ")
	return buf:get()
end

local get = function(self)
	return llm_prompt(self)
end

local set = function(self, options)
	for k, v in pairs(options) do
		self[k] = v
	end
end

return {
	get = get,
	set = set,
}
