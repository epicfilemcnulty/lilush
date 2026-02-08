-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== theme registry ==")

local function deep_copy(tbl)
	if type(tbl) ~= "table" then
		return tbl
	end
	local out = {}
	for k, v in pairs(tbl) do
		out[k] = deep_copy(v)
	end
	return out
end

local function merge_tables(dst, src)
	dst = dst or {}
	for k, v in pairs(src or {}) do
		if type(v) == "table" and type(dst[k]) == "table" then
			merge_tables(dst[k], v)
		else
			dst[k] = v
		end
	end
	return dst
end

local function setup_theme(options)
	options = options or {}
	local files = options.files or {}
	local decode_map = options.decode_map or {}

	helpers.clear_modules({ "std", "cjson.safe", "theme" })

	helpers.stub_module("std", {
		fs = {
			read_file = function(path)
				local rel = path:match("/%.config/lilush/theme/(.+)$")
				if rel then
					return files[rel]
				end
				return nil, "missing"
			end,
		},
		tbl = {
			copy = deep_copy,
			merge = merge_tables,
		},
	})

	helpers.stub_module("cjson.safe", {
		decode = function(raw)
			local decoded = decode_map[raw]
			if decoded == nil then
				return nil, "decode error"
			end
			return deep_copy(decoded)
		end,
	})

	return helpers.load_module_from_src("theme", "src/theme/theme.lua")
end

testify:that("returns default shell section when override files are missing", function()
	local theme = setup_theme()
	local shell = theme.get("shell")
	testimony.assert_not_nil(shell.widget)
	testimony.assert_not_nil(shell.errors)
	testimony.assert_not_nil(shell.builtin)
	testimony.assert_not_nil(shell.prompt)
	testimony.assert_not_nil(shell.repl)
	testimony.assert_not_nil(shell.completion)
end)

testify:that("loads and merges shell/markdown/agent override files", function()
	local theme = setup_theme({
		files = {
			["shell.json"] = "shell-json",
			["markdown.json"] = "markdown-json",
			["agent.json"] = "agent-json",
		},
		decode_map = {
			["shell-json"] = {
				widget = {
					shell = {
						title = { fg = 123 },
					},
				},
			},
			["markdown-json"] = {
				wrap = 90,
				code = { fg = 100 },
			},
			["agent-json"] = {
				agent = {
					error = { fg = 160 },
				},
			},
		},
	})

	local shell = theme.get("shell")
	testimony.assert_equal(123, shell.widget.shell.title.fg)

	local markdown = theme.get("markdown")
	testimony.assert_equal(90, markdown.wrap)
	testimony.assert_equal(100, markdown.code.fg)

	local agent = theme.get("agent")
	testimony.assert_equal(160, agent.agent.error.fg)
end)

testify:that("applies precedence as defaults then user overrides then call-site overrides", function()
	local theme = setup_theme({
		files = {
			["markdown.json"] = "markdown-json",
		},
		decode_map = {
			["markdown-json"] = {
				wrap = 90,
				code = { fg = 100 },
			},
		},
	})

	local markdown = theme.get("markdown", {
		wrap = 70,
		code = { fg = 101 },
	})
	testimony.assert_equal(70, markdown.wrap)
	testimony.assert_equal(101, markdown.code.fg)
end)

testify:that("returns deep copies from get", function()
	local theme = setup_theme()
	local shell_a = theme.get("shell")
	shell_a.widget.shell.title.fg = 1

	local shell_b = theme.get("shell")
	testimony.assert_true(shell_b.widget.shell.title.fg ~= 1)
end)

testify:that("ignores decode failures and keeps defaults", function()
	local theme = setup_theme({
		files = {
			["shell.json"] = "broken-json",
		},
		decode_map = {
			-- broken-json intentionally missing to trigger decode failure
		},
	})

	local shell = theme.get("shell")
	testimony.assert_not_nil(shell.widget.shell.title)
end)

testify:that("ignores legacy split shell files when shell.json is absent", function()
	local theme = setup_theme({
		files = {
			["widgets.json"] = "legacy-widgets-json",
		},
		decode_map = {
			["legacy-widgets-json"] = {
				shell = {
					title = { fg = 1 },
				},
			},
		},
	})

	local shell = theme.get("shell")
	testimony.assert_true(shell.widget.shell.title.fg ~= 1)
end)

testify:conclude()
