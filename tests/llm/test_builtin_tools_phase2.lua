-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== llm built-in tools phase2 ==")

local load_tool = function(mod_name, path, stubs)
	local mods = { mod_name }
	for stub_name, _ in pairs(stubs or {}) do
		table.insert(mods, stub_name)
	end
	helpers.clear_modules(mods)
	for stub_name, stub_value in pairs(stubs or {}) do
		helpers.stub_module(stub_name, stub_value)
	end
	return helpers.load_module_from_src(mod_name, path)
end

testify:that("built-ins return consistent envelope for missing required args", function()
	local read_file = load_tool("llm.tools.read_file", "src/llm/llm/tools/read_file.lua", {
		std = {},
	})
	local write_file = load_tool("llm.tools.write_file", "src/llm/llm/tools/write_file.lua", {
		std = {},
	})
	local edit_file = load_tool("llm.tools.edit_file", "src/llm/llm/tools/edit_file.lua", {
		std = {},
	})
	local bash = load_tool("llm.tools.bash", "src/llm/llm/tools/bash.lua", {
		std = {},
		["std.txt"] = {},
	})
	local web_search = load_tool("llm.tools.web_search", "src/llm/llm/tools/web_search.lua", {
		web = {},
		["cjson.safe"] = {},
	})
	local fetch_webpage = load_tool("llm.tools.fetch_webpage", "src/llm/llm/tools/fetch_webpage.lua", {
		std = {},
		web = {},
	})

	local r1 = read_file.execute({})
	local r2 = write_file.execute({})
	local r3 = edit_file.execute({})
	local r4 = bash.execute({})
	local r5 = web_search.execute({})
	local r6 = fetch_webpage.execute({})

	testimony.assert_equal("read", r1.name)
	testimony.assert_false(r1.ok)
	testimony.assert_equal("write", r2.name)
	testimony.assert_false(r2.ok)
	testimony.assert_equal("edit", r3.name)
	testimony.assert_false(r3.ok)
	testimony.assert_equal("bash", r4.name)
	testimony.assert_false(r4.ok)
	testimony.assert_equal("web_search", r5.name)
	testimony.assert_false(r5.ok)
	testimony.assert_equal("fetch_webpage", r6.name)
	testimony.assert_false(r6.ok)
end)

testify:that("read and write success envelopes include ok=true", function()
	local read_file = load_tool("llm.tools.read_file", "src/llm/llm/tools/read_file.lua", {
		std = {
			fs = {
				read_file = function()
					return "line1\nline2\n"
				end,
			},
		},
	})
	local write_file = load_tool("llm.tools.write_file", "src/llm/llm/tools/write_file.lua", {
		std = {
			fs = {
				file_exists = function()
					return false
				end,
				write_file = function()
					return true
				end,
			},
		},
	})

	local read_result = read_file.execute({ filepath = "README.md", offset = 1, limit = 1 })
	local write_result = write_file.execute({ filepath = "a.txt", content = "" })

	testimony.assert_true(read_result.ok)
	testimony.assert_equal("read", read_result.name)
	testimony.assert_equal("line2", read_result.content)
	testimony.assert_equal(2, read_result.lines.start)
	testimony.assert_equal(2, read_result.lines["end"])
	testimony.assert_true(write_result.ok)
	testimony.assert_equal("write", write_result.name)
	testimony.assert_equal(0, write_result.bytes_written)
end)

testify:that("web_search reports request failures in consistent envelope", function()
	local web_search = load_tool("llm.tools.web_search", "src/llm/llm/tools/web_search.lua", {
		web = {
			request = function()
				return nil, "network unavailable"
			end,
		},
		["cjson.safe"] = {
			encode = function(tbl)
				return "{}"
			end,
			decode = function()
				return {}
			end,
		},
	})

	local old_getenv = os.getenv
	os.getenv = function(key)
		if key == "LINKUP_API_TOKEN" then
			return "token"
		end
		return old_getenv(key)
	end

	local result = web_search.execute({ query = "lua" })
	os.getenv = old_getenv

	testimony.assert_equal("web_search", result.name)
	testimony.assert_false(result.ok)
	testimony.assert_match("network unavailable", result.error or "")
end)

testify:that("edit reports success with line and ok envelope", function()
	local written_content = nil
	local edit_file = load_tool("llm.tools.edit_file", "src/llm/llm/tools/edit_file.lua", {
		std = {
			fs = {
				read_file = function()
					return "alpha\nbeta\ngamma\n"
				end,
				write_file = function(path, content)
					written_content = content
					return true
				end,
			},
		},
	})

	local result = edit_file.execute({
		filepath = "x.txt",
		old_text = "beta",
		new_text = "delta",
	})

	testimony.assert_true(result.ok)
	testimony.assert_equal("edit", result.name)
	testimony.assert_equal(2, result.line)
	testimony.assert_match("delta", written_content or "")
end)

testify:that("bash reports success with normalized stdout envelope", function()
	local pipe_index = 0
	local make_pipe = function(data)
		return {
			inn = {},
			close_inn = function()
				return true
			end,
			close_out = function()
				return true
			end,
			read = function()
				return data
			end,
		}
	end

	local bash = load_tool("llm.tools.bash", "src/llm/llm/tools/bash.lua", {
		std = {
			utf = {
				len = function(text)
					return #(tostring(text or ""))
				end,
				sub = function(text, s, e)
					return tostring(text or ""):sub(s, e)
				end,
			},
			ps = {
				pipe = function()
					pipe_index = pipe_index + 1
					if pipe_index == 1 then
						return make_pipe("ok\n")
					end
					return make_pipe("")
				end,
				launch = function()
					return 42
				end,
				wait = function()
					return nil, 0
				end,
			},
		},
		["std.txt"] = {
			lines = function(text)
				local lines = {}
				for line in tostring(text or ""):gmatch("([^\n]*)\n?") do
					if line ~= "" then
						table.insert(lines, line)
					end
				end
				return lines
			end,
		},
	})

	local result = bash.execute({ command = "echo ok" })
	testimony.assert_true(result.ok)
	testimony.assert_equal("bash", result.name)
	testimony.assert_equal(0, result.exit_code)
	testimony.assert_equal("ok", result.stdout)
end)

testify:that("fetch_webpage and web_search success envelopes include ok=true", function()
	local web_search = load_tool("llm.tools.web_search", "src/llm/llm/tools/web_search.lua", {
		web = {
			request = function()
				return { status = 200, body = '{"answer":"ok"}' }
			end,
		},
		["cjson.safe"] = {
			encode = function()
				return "{}"
			end,
			decode = function(payload)
				if payload == '{"answer":"ok"}' then
					return { answer = "ok" }
				end
				return {}
			end,
		},
	})

	local fetch_webpage = load_tool("llm.tools.fetch_webpage", "src/llm/llm/tools/fetch_webpage.lua", {
		std = {
			nanoid = function()
				return "abc"
			end,
			fs = {
				write_file = function()
					return true
				end,
				remove = function()
					return true
				end,
			},
			ps = {
				exec_simple = function()
					return { status = 0, stdout = { "rendered page" }, stderr = {} }
				end,
			},
		},
		web = {
			request = function()
				return { status = 200, body = "<html>ok</html>" }
			end,
		},
	})

	local old_getenv = os.getenv
	os.getenv = function(key)
		if key == "LINKUP_API_TOKEN" then
			return "token"
		end
		return old_getenv(key)
	end

	local ws = web_search.execute({ query = "lua" })
	local fw = fetch_webpage.execute({ url = "https://example.com" })
	os.getenv = old_getenv

	testimony.assert_true(ws.ok)
	testimony.assert_equal("web_search", ws.name)
	testimony.assert_equal("ok", ws.results.answer)
	testimony.assert_true(fw.ok)
	testimony.assert_equal("fetch_webpage", fw.name)
	testimony.assert_match("rendered page", fw.page)
end)

testify:conclude()
