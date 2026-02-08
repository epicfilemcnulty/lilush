-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== llm templates/pricing ==")

local setup_templates = function()
	helpers.clear_modules({
		"std",
		"llm.templates",
	})

	helpers.stub_module("std", {
		tbl = {
			merge = function(dst, src)
				local out = {}
				for k, v in pairs(dst or {}) do
					out[k] = v
				end
				for k, v in pairs(src or {}) do
					if type(v) == "table" and type(out[k]) == "table" then
						local nested = {}
						for nk, nv in pairs(out[k]) do
							nested[nk] = nv
						end
						for nk, nv in pairs(v) do
							nested[nk] = nv
						end
						out[k] = nested
					else
						out[k] = v
					end
				end
				return out
			end,
		},
	})

	return helpers.load_module_from_src("llm.templates", "src/llm/llm/templates.lua")
end

testify:that("templates apply stringifies non-string content and tool blocks", function()
	local templates = setup_templates()

	local output = templates.apply({
		system = { prefix = "<S>", suffix = "</S>" },
		user = { prefix = "<U>", suffix = "</U>" },
		llm = { prefix = "<A>", suffix = "</A>" },
	}, {
		{ role = "system", content = { policy = "strict" } },
		{ role = "user", content = 42 },
		{ role = "assistant", content = { summary = "ok" } },
	}, { { type = "function", ["function"] = { name = "read" } } }, false)

	testimony.assert_match("<S>", output)
	testimony.assert_match('"policy"', output)
	testimony.assert_match("<tools>", output)
	testimony.assert_match("read", output)
	testimony.assert_match("<U>42</U>", output)
	testimony.assert_match('"summary"', output)
	testimony.assert_match("<A>$", output)
end)

testify:that("templates apply honors dont_start and tool_response encoding", function()
	local templates = setup_templates()

	local output = templates.apply({
		user = { prefix = "[", suffix = "]" },
		llm = { prefix = ">>", suffix = "<<" },
	}, {
		{
			role = "user",
			tool_responses = {
				{ name = "bash", exit_code = 0 },
			},
		},
	}, nil, true)

	testimony.assert_match("<tool_response>", output)
	testimony.assert_false(output:match(">>$") ~= nil)
end)

local setup_pricing = function()
	helpers.clear_modules({ "llm.pricing" })
	return helpers.load_module_from_src("llm.pricing", "src/llm/llm/pricing.lua")
end

local assert_near = function(actual, expected, eps)
	eps = eps or 1e-12
	local delta = math.abs((actual or 0) - (expected or 0))
	if delta > eps then
		error(string.format("expected %.12f ~= %.12f (delta %.12f)", actual or -1, expected or -1, delta))
	end
end

testify:that("pricing handles numeric strings, clamps negatives, and stable copies", function()
	local pricing = setup_pricing()
	pricing.clear_custom_prices()

	pricing.set_custom_prices({
		["custom-a"] = { input = "1.2", output = "2.3", cached = "-4" },
		[""] = { input = 1, output = 1 },
		invalid = "oops",
	})

	local p1 = pricing.get_price("custom-a")
	testimony.assert_equal(1.2, p1.input)
	testimony.assert_equal(2.3, p1.output)
	testimony.assert_nil(p1.cached)

	-- Returned value is a copy (external mutation should not leak back).
	p1.input = 999
	local p2 = pricing.get_price("custom-a")
	testimony.assert_equal(1.2, p2.input)

	local cost = pricing.calculate_cost("custom-a", "1000", -50, "500")
	assert_near(cost, ((1000 * 1.2) + (500 * 0)) / 1000000)
end)

testify:that("pricing list/format/is_free behave as expected", function()
	local pricing = setup_pricing()
	pricing.clear_custom_prices()
	pricing.set_custom_prices({
		["zzz-model"] = { input = 0, output = 0 },
	})

	local models = pricing.list_models()
	testimony.assert_true(#models > 0)
	testimony.assert_true(models[#models] == "zzz-model")

	testimony.assert_true(pricing.is_free("zzz-model"))
	testimony.assert_equal("$0.00", pricing.format_cost(-1))
	testimony.assert_equal("$0.0004", pricing.format_cost(0.0004))
	testimony.assert_equal("$0.004", pricing.format_cost(0.004))
	testimony.assert_equal("$1.23", pricing.format_cost(1.234))
end)

testify:conclude()
