-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local completion_mod = require("term.input.completion")

local testify = testimony.new("== agent.slash completion ==")

local function new_agent_completion(saved_names)
	local completion, err = completion_mod.new({
		path = "agent.completion.slash",
		sources = { "agent.completion.source.slash" },
	})
	testimony.assert_nil(err)
	testimony.assert_not_nil(completion)

	local source = completion:source("slash")
	testimony.assert_not_nil(source)
	source:update({
		list_commands = function()
			return { "/help", "/save", "/load", "/list", "/prompt" }
		end,
		list_saved_conversations = function()
			return saved_names or { "alpha", "bravo" }
		end,
	})

	return completion
end

local function assert_candidates(completion, input, expected)
	local available = completion:search(input)
	if #expected == 0 then
		testimony.assert_false(available)
		testimony.assert_equal(0, #completion.__candidates)
		return
	end

	testimony.assert_true(available)
	testimony.assert_equal(#expected, #completion.__candidates)
	for i = 1, #expected do
		testimony.assert_equal(expected[i], completion.__candidates[i])
	end
end

testify:that("completes /list command prefix", function()
	local completion = new_agent_completion()
	assert_candidates(completion, "/li", { "st " })
end)

testify:that("/load supports trailing-space argument completion", function()
	local completion = new_agent_completion({ "alpha", "bravo" })
	assert_candidates(completion, "/load ", { "alpha ", "bravo " })
	assert_candidates(completion, "/load a", { "lpha " })
end)

testify:that("/save supports trailing-space argument completion", function()
	local completion = new_agent_completion({ "alpha", "bravo" })
	assert_candidates(completion, "/save ", { "alpha ", "bravo " })
	assert_candidates(completion, "/save b", { "ravo " })
end)

testify:that("/list with a trailing space has no argument suggestions", function()
	local completion = new_agent_completion()
	assert_candidates(completion, "/list ", {})
end)

testify:conclude()
