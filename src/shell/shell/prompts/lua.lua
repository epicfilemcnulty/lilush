-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local term = require("term")
local theme = require("shell.theme")
local tss_gen = require("term.tss")
local tss = tss_gen.new(theme)

local lua_prompt = function(self)
	return tss:apply("prompts.shell.sep", "(") .. tss:apply("prompts.lua.logo") .. tss:apply("prompts.shell.sep", ")")
end

local get = function(self)
	return lua_prompt(self) .. " "
end

return {
	get = get,
}
