-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local theme = require("shell.theme")
local tss_gen = require("term.tss")
local tss = tss_gen.new(theme)
local buffer = require("string.buffer")
local style_text = function(ctx, ...)
	return ctx:apply(...).text
end

local get = function(self)
	local prompt = buffer.new()
	prompt:put(
		style_text(tss, "prompts.shell.sep", "("),
		style_text(tss, "prompts.lua.logo"),
		style_text(tss, "prompts.shell.sep", ")")
	)
	if self.__state.lines and self.__state.lines > 1 then
		prompt:put(style_text(tss, "prompts.shell.sep", "["))
		prompt:put(style_text(tss, "prompts.shell.sep", tostring(self.__state.line)))
		prompt:put(style_text(tss, "prompts.shell.sep", "]"))
	end
	prompt:put(" ")
	return prompt:get()
end

local set = function(self, options)
	for key, value in pairs(options or {}) do
		self.__state[key] = value
	end
end

local new = function(config)
	local prompt = {
		cfg = config or {},
		__state = {
			lines = 1,
			line = 1,
		},
		get = get,
		set = set,
	}
	return prompt
end

return {
	new = new,
}
