-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== shell lua completion ==")

local make_std_stub = function()
	return {
		escape_magic_chars = function(text)
			return tostring(text or ""):gsub("([^%w])", "%%%1")
		end,
	}
end

local setup_modules = function()
	helpers.clear_modules({
		"std",
		"term.tss",
		"theme",
		"shell.completion.lua",
		"shell.completion.source.lua_keywords",
		"shell.completion.source.lua_symbols",
	})

	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("theme", {
		get = function(a, b)
			local section = b or a
			if section == "shell" then
				return { completion = {} }
			end
			return {}
		end,
	})
	helpers.stub_module("term.tss", {
		new = function()
			return {
				apply = function(self, key, value)
					return { text = tostring(value or "") }
				end,
			}
		end,
	})

	local completion_mod = helpers.load_module_from_src("shell.completion.lua", "src/shell/shell/completion/lua.lua")
	local keywords_mod = helpers.load_module_from_src(
		"shell.completion.source.lua_keywords",
		"src/shell/shell/completion/source/lua_keywords.lua"
	)
	local symbols_mod = helpers.load_module_from_src(
		"shell.completion.source.lua_symbols",
		"src/shell/shell/completion/source/lua_symbols.lua"
	)

	return completion_mod, keywords_mod, symbols_mod
end

local new_completion = function(completion_mod, keywords_source, symbols_source)
	local completion = {
		__sources = {
			lua_keywords = keywords_source,
			lua_symbols = symbols_source,
		},
		__candidates = {},
		__meta = {},
		__chosen = 0,
		flush = function(self)
			self.__candidates = {}
			self.__meta = {}
			self.__chosen = 0
		end,
		available = function(self)
			if #self.__candidates > 0 then
				if self.__chosen == 0 then
					self.__chosen = 1
				end
				return true
			end
			return false
		end,
		search = completion_mod.search,
		get = completion_mod.get,
	}
	return completion
end

testify:that("top-level symbol and keyword completion works", function()
	local completion_mod, keywords_mod, symbols_mod = setup_modules()
	local keywords = keywords_mod.new()
	local symbols = symbols_mod.new()
	symbols:update({
		print = print,
		project_count = 3,
	})

	local completion = new_completion(completion_mod, keywords, symbols)
	testimony.assert_true(completion:search("pro"))
	testimony.assert_equal("ject_count", completion:get(true))

	testimony.assert_true(completion:search("fun"))
	testimony.assert_equal("ction", completion:get(true))
end)

testify:that("member completion resolves nested tables", function()
	local completion_mod, keywords_mod, symbols_mod = setup_modules()
	local keywords = keywords_mod.new()
	local symbols = symbols_mod.new()
	symbols:update({
		math = {
			sin = function() end,
			sqrt = function() end,
		},
	})

	local completion = new_completion(completion_mod, keywords, symbols)
	testimony.assert_true(completion:search("math.si"))
	testimony.assert_equal("n", completion:get(true))
end)

testify:conclude()
