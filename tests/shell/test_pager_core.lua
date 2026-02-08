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

local setup_pager = function(options)
	if type(options) ~= "table" then
		options = { input_content = options }
	end

	local input_content = options.input_content
	local markdown_render = options.markdown_render
	local fs_read_file = options.fs_read_file
	local fs_file_exists = options.fs_file_exists
	local pager_config = options.pager_config
		or { wrap = 5, wrap_in_raw = true, status_line = false, exit_on_one_page = false }

	helpers.clear_modules({
		"std",
		"cjson.safe",
		"markdown",
		"markdown.renderer.theme",
		"crypto",
		"term",
		"theme",
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
				if fs_read_file then
					return fs_read_file(path)
				end
				return ""
			end,
			file_exists = function(path, mode)
				if fs_file_exists then
					return fs_file_exists(path, mode)
				end
				return false
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
			if markdown_render then
				return markdown_render(text, opts)
			end
			return { rendered = tostring(text or ""), elements = options.markdown_elements or {} }
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
	helpers.stub_module("theme", {
		get = function(a, b)
			local section = b or a
			if section == "shell" then
				return {
					builtin = {
						pager = {
							status_line = {
								search = {
									input = {},
								},
							},
						},
					},
				}
			end
			if section == "markdown" then
				return {}
			end
			return {}
		end,
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
	return pager_mod.new(pager_config)
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

testify:that("build_focusable_elements keeps container range for links", function()
	local pager = setup_pager({
		markdown_elements = {
			links = {
				{
					line = 3,
					url = "./doc.md",
					container = { start_line = 2, end_line = 6 },
				},
			},
		},
	})

	pager:set_content("table text", "docs/a.md")
	pager:set_render_mode("markdown")

	testimony.assert_equal(1, #pager.__state.navigation.elements)
	testimony.assert_equal(2, pager.__state.navigation.elements[1].start_line)
	testimony.assert_equal(6, pager.__state.navigation.elements[1].end_line)
end)

testify:that("activate_element follows focused local markdown link", function()
	local files = {
		["docs/a.md"] = "Doc A",
		["docs/b.md"] = "Doc B",
	}
	local pager = setup_pager({
		fs_read_file = function(path)
			if files[path] then
				return files[path]
			end
			return nil, "missing"
		end,
		fs_file_exists = function(path)
			return files[path] ~= nil
		end,
		markdown_render = function(text)
			if text == "Doc A" then
				return {
					rendered = "Doc A",
					elements = { links = { { line = 1, url = "./b.md", title = nil } } },
				}
			end
			return {
				rendered = tostring(text or ""),
				elements = { links = {} },
			}
		end,
	})

	pager:load_content("docs/a.md")
	pager:set_render_mode("markdown")
	pager.__state.navigation.focused_idx = 1

	local ok = pager:activate_element()
	testimony.assert_true(ok)
	testimony.assert_equal("docs/b.md", pager.__state.history[#pager.__state.history])
	testimony.assert_equal("Doc B", pager.content.raw)
	testimony.assert_equal(1, #pager.__state.navigation.doc_back_stack)
end)

testify:that("backspace action returns from footnote before document history", function()
	local pager = setup_pager()
	pager:set_content("current", "docs/current.md")
	pager:set_render_mode("raw")
	pager.__state.top_line = 5
	pager.__state.navigation.return_position = 2
	pager.__state.navigation.doc_back_stack = {
		{
			raw = "previous",
			name = "docs/prev.md",
			render_mode = "raw",
			top_line = 1,
			focused_idx = 0,
		},
	}

	local ok = pager:return_from_footnote()
	testimony.assert_true(ok)
	testimony.assert_equal(2, pager.__state.top_line)
	testimony.assert_nil(pager.__state.navigation.return_position)
	testimony.assert_equal(1, #pager.__state.navigation.doc_back_stack)
end)

testify:that("backspace action restores previous document when footnote return is empty", function()
	local pager = setup_pager()
	pager:set_content("current", "docs/current.md")
	pager:set_render_mode("raw")
	pager.__state.navigation.doc_back_stack = {
		{
			raw = "previous",
			name = "docs/prev.md",
			render_mode = "raw",
			top_line = 1,
			focused_idx = 0,
		},
	}

	local ok = pager:return_from_footnote()
	testimony.assert_true(ok)
	testimony.assert_equal("previous", pager.content.raw)
	testimony.assert_equal("docs/prev.md", pager.__state.history[#pager.__state.history])
	testimony.assert_equal(0, #pager.__state.navigation.doc_back_stack)
end)

testify:that("activate_element does not follow non-local link", function()
	local pager = setup_pager({
		markdown_elements = {
			links = {
				{ line = 1, url = "https://example.com" },
			},
		},
	})
	pager:set_content("doc", "docs/a.md")
	pager:set_render_mode("markdown")
	pager.__state.navigation.focused_idx = 1

	local ok = pager:activate_element()
	testimony.assert_false(ok)
	testimony.assert_equal(0, #pager.__state.navigation.doc_back_stack)
	testimony.assert_equal("docs/a.md", pager.__state.history[#pager.__state.history])
end)

testify:conclude()
