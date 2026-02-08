-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== agent.stream ==")

local setup_stream = function()
	helpers.clear_modules({
		"agent.stream",
	})
	return helpers.load_module_from_src("agent.stream", "src/agent/agent/stream.lua")
end

testify:that("stream emits text immediately and buffers fenced code", function()
	local mod = setup_stream()
	local out = {}
	local stream = mod.new({
		on_text = function(text)
			table.insert(out, { t = "text", text = text })
		end,
		on_code = function(lang, code)
			table.insert(out, { t = "code", lang = lang, code = code })
		end,
	})

	stream:push("hello")
	testimony.assert_equal(1, #out)
	testimony.assert_equal("text", out[1].t)
	testimony.assert_equal("hello", out[1].text)
	testimony.assert_true(stream:had_output())
	testimony.assert_false(stream:had_output())

	stream:push("\n```lua\nprint(1)\n")
	testimony.assert_equal(2, #out)
	testimony.assert_equal("text", out[2].t)

	stream:push("```\nbye")
	testimony.assert_equal(4, #out)
	testimony.assert_equal("code", out[3].t)
	testimony.assert_equal("lua", out[3].lang)
	testimony.assert_equal("print(1)", out[3].code)
	testimony.assert_equal("text", out[4].t)
	testimony.assert_equal("bye", out[4].text)
end)

testify:that("stream handles split language line and flushes incomplete block", function()
	local mod = setup_stream()
	local out = {}
	local stream = mod.new({
		on_text = function(text)
			table.insert(out, { t = "text", text = text })
		end,
		on_code = function(lang, code)
			table.insert(out, { t = "code", lang = lang, code = code })
		end,
	})

	stream:push("pre\n```py")
	stream:push("thon\nprint('x')")
	stream:flush()

	testimony.assert_equal("text", out[1].t)
	testimony.assert_equal("pre\n", out[1].text)
	testimony.assert_equal("code", out[2].t)
	testimony.assert_equal("python", out[2].lang)
	testimony.assert_equal("print('x')", out[2].code)
end)

testify:that("stream ignores inline fences and reset clears output flag", function()
	local mod = setup_stream()
	local out = {}
	local stream = mod.new({
		on_text = function(text)
			table.insert(out, { t = "text", text = text })
		end,
		on_code = function(lang, code)
			table.insert(out, { t = "code", lang = lang, code = code })
		end,
	})

	stream:push("inline ```not-fence``` text")
	testimony.assert_equal(1, #out)
	testimony.assert_equal("text", out[1].t)
	testimony.assert_equal("inline ```not-fence``` text", out[1].text)
	testimony.assert_true(stream:had_output())

	stream:reset()
	testimony.assert_false(stream:had_output())
end)

testify:conclude()
