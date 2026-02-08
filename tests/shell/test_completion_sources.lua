-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== shell completion sources ==")

local contains = function(items, wanted)
	for _, item in ipairs(items or {}) do
		if item == wanted then
			return true
		end
	end
	return false
end

local setup_modules = function()
	helpers.clear_modules({
		"std",
		"shell.completion.source.builtins",
		"shell.completion.source.cmds",
		"shell.completion.source.env",
		"shell.completion.source.lua_keywords",
		"shell.completion.source.lua_symbols",
	})

	helpers.stub_module("std", {
		escape_magic_chars = function(text)
			return tostring(text or ""):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
		end,
		environ = function()
			return {
				HOME = "/tmp",
				HELLO = "1",
				HERO = "2",
			}
		end,
		tbl = {
			sort_by_str_len = function(items)
				table.sort(items, function(a, b)
					if #a == #b then
						return a < b
					end
					return #a < #b
				end)
				return items
			end,
			merge = function(dst, src)
				for k, v in pairs(src or {}) do
					dst[k] = v
				end
				return dst
			end,
		},
		fs = {
			list_files = function(path)
				if path:match("/%.kube/cfgs") then
					return { dev = true, prod = true }
				end
				return {}
			end,
			list_dir = function(path)
				return { "alpha", "beta" }
			end,
			read_file = function(path)
				if path:match("/%.ssh/config") then
					return "Host app\nHost db\n"
				end
				return ""
			end,
		},
	})

	local builtins_mod = helpers.load_module_from_src(
		"shell.completion.source.builtins",
		"src/shell/shell/completion/source/builtins.lua"
	)
	local cmds_mod =
		helpers.load_module_from_src("shell.completion.source.cmds", "src/shell/shell/completion/source/cmds.lua")
	local env_mod =
		helpers.load_module_from_src("shell.completion.source.env", "src/shell/shell/completion/source/env.lua")
	local keywords_mod = helpers.load_module_from_src(
		"shell.completion.source.lua_keywords",
		"src/shell/shell/completion/source/lua_keywords.lua"
	)
	local symbols_mod = helpers.load_module_from_src(
		"shell.completion.source.lua_symbols",
		"src/shell/shell/completion/source/lua_symbols.lua"
	)

	return builtins_mod, cmds_mod, env_mod, keywords_mod, symbols_mod
end

testify:that("builtins source merges builtin and alias candidates", function()
	local builtins_mod = setup_modules()
	local source = builtins_mod.new()
	source:update({ ali = "alias list" })

	local candidates = source:search("ali")
	testimony.assert_true(contains(candidates, "as "))
	testimony.assert_true(contains(candidates, " "))
end)

testify:that("cmds source resolves command-specific completions", function()
	local _, cmds_mod = setup_modules()
	local source = cmds_mod.new()

	local git = source:search("git", { "st" })
	testimony.assert_true(contains(git, "atus"))

	local ssh = source:search("ssh", { "a" })
	testimony.assert_true(contains(ssh, "pp"))
end)

testify:that("env source supports brace syntax", function()
	local _, _, env_mod = setup_modules()
	local source = env_mod.new()

	local candidates = source:search("${HE")
	testimony.assert_true(contains(candidates, "LLO} "))
	testimony.assert_true(contains(candidates, "RO} "))
end)

testify:that("lua keywords and symbols sources filter by prefix", function()
	local _, _, _, keywords_mod, symbols_mod = setup_modules()
	local keywords = keywords_mod.new()
	local symbols = symbols_mod.new()
	symbols:update({
		project = {
			name = "x",
			number = 1,
		},
		print = print,
	})

	local kw = keywords:search("fun")
	testimony.assert_true(contains(kw, "function"))

	local top = symbols:search("pr")
	testimony.assert_true(contains(top, "project"))
	testimony.assert_true(contains(top, "print"))

	local members = symbols:members("project", "na")
	testimony.assert_equal("project.name", members[1])
end)

testify:conclude()
