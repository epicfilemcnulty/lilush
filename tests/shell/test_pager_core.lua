-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== shell pager core ==")

local split_lines = function(text)
	local lines = {}
	for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines, #lines)
	end
	return lines
end

local setup_pager = function(input_content)
	helpers.clear_modules({
		"std",
		"cjson.safe",
		"markdown",
		"markdown.renderer.theme",
		"crypto",
		"term",
		"shell.theme",
		"term.tss",
		"term.input",
		"term.input.history",
		"shell.utils.pager",
	})

	helpers.stub_module("std", {
		tbl = {
			merge = function(dst, src)
				for k, v in pairs(src or {}) do
					dst[k] = v
				end
				return dst
			end,
		},
		txt = {
			lines = function(text)
				return split_lines(text)
			end,
			lines_of = function(text, width)
				local out = {}
				local line = tostring(text or "")
				if width <= 0 then
					return { line }
				end
				local i = 1
				while i <= #line do
					table.insert(out, line:sub(i, i + width - 1))
					i = i + width
				end
				return out
			end,
		},
		fs = {
			read_file = function(path)
				return ""
			end,
		},
		utf = {
			set_ts_width_mode = function(mode)
				return true
			end,
		},
	})
	helpers.stub_module("cjson.safe", {})
	helpers.stub_module("markdown", {
		render = function(text, opts)
			return { rendered = tostring(text or ""), elements = {} }
		end,
	})
	helpers.stub_module("markdown.renderer.theme", {
		DEFAULT_RSS = {},
	})
	helpers.stub_module("crypto", {
		b64_encode = function(text)
			return "ZW5jb2RlZA=="
		end,
	})
	helpers.stub_module("term", {
		window_size = function()
			return 24, 80
		end,
		cursor_position = function()
			return 1, 1
		end,
		raw_mode = function()
			return false
		end,
		has_ts = function()
			return false
		end,
		has_ts_combined = function()
			return false
		end,
		go = function() end,
		clear = function() end,
		clear_line = function() end,
		write = function() end,
		show_cursor = function() end,
		hide_cursor = function() end,
		simple_get = function()
			return "exit"
		end,
		alt_screen = function()
			return {
				done = function() end,
			}
		end,
	})
	helpers.stub_module("shell.theme", {
		builtins = {
			pager = {
				status_line = {
					search = {
						input = {},
					},
				},
			},
		},
	})
	helpers.stub_module("term.tss", {
		new = function()
			return {
				apply = function(self, key, value)
					if value == nil then
						return { text = "" }
					end
					return { text = tostring(value) }
				end,
			}
		end,
	})
	helpers.stub_module("term.input", {
		new = function(opts)
			return {
				display = function() end,
				run = function()
					return "execute"
				end,
				get_content = function()
					return input_content or ""
				end,
			}
		end,
	})
	helpers.stub_module("term.input.history", {
		new = function()
			return {
				add = function(self, value)
					return true
				end,
			}
		end,
	})

	local pager_mod = helpers.load_module_from_src("shell.utils.pager", "src/shell/shell/utils/pager.lua")
	return pager_mod.new({ wrap = 5, wrap_in_raw = true, status_line = false, exit_on_one_page = false })
end

testify:that("raw render mode uses cfg and updates rendered content", function()
	local pager = setup_pager()
	pager:set_content("hello world")
	pager:set_render_mode("raw")

	testimony.assert_equal("raw", pager.cfg.render_mode)
	testimony.assert_true(#pager.content.lines >= 2)
	testimony.assert_equal("hello", pager.content.lines[1])
end)

testify:that("toggle methods mutate cfg flags", function()
	local pager = setup_pager()
	pager:set_content("abc")
	pager:set_render_mode("raw")

	local line_nums_before = pager.cfg.line_nums
	local status_before = pager.cfg.status_line
	pager:toggle_line_nums()
	pager:toggle_status_line()
	testimony.assert_equal(not line_nums_before, pager.cfg.line_nums)
	testimony.assert_equal(not status_before, pager.cfg.status_line)
end)

testify:that("search input does not leak global event variable", function()
	local pager = setup_pager("")
	pager:set_content("line one\nline two")
	pager:set_render_mode("raw")

	local previous = _G.event
	_G.event = "sentinel"
	pager:search("/")
	testimony.assert_equal("sentinel", _G.event)
	_G.event = previous
end)

testify:conclude()
