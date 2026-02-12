-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local std = require("std")
local term = require("term")
local input = require("term.input")

local testify = testimony.new("== term.input completion EOL gating ==")

local with_stubbed_term = function(fn)
	local original = {
		write = term.write,
		move = term.move,
		go = term.go,
		hide_cursor = term.hide_cursor,
		show_cursor = term.show_cursor,
		window_size = term.window_size,
	}

	local writes = {}
	term.write = function(text)
		table.insert(writes, text or "")
	end
	term.move = function()
		return nil
	end
	term.go = function()
		return nil
	end
	term.hide_cursor = function()
		return nil
	end
	term.show_cursor = function()
		return nil
	end
	term.window_size = function()
		return 24, 120
	end

	local ok, err = pcall(fn, writes)

	term.write = original.write
	term.move = original.move
	term.go = original.go
	term.hide_cursor = original.hide_cursor
	term.show_cursor = original.show_cursor
	term.window_size = original.window_size

	if not ok then
		error(err)
	end
end

local new_completion_stub = function(candidate)
	return {
		__state = {
			available = false,
			search_calls = 0,
			get_calls = 0,
			flush_calls = 0,
			search_lines = {},
			candidate = candidate or "[",
		},
		available = function(self)
			return self.__state.available
		end,
		search = function(self, line)
			self.__state.search_calls = self.__state.search_calls + 1
			table.insert(self.__state.search_lines, line)
			self.__state.available = true
			return true
		end,
		get = function(self)
			self.__state.get_calls = self.__state.get_calls + 1
			return self.__state.candidate
		end,
		flush = function(self)
			self.__state.flush_calls = self.__state.flush_calls + 1
			self.__state.available = false
		end,
		count = function(self)
			if self.__state.available then
				return 1
			end
			return 0
		end,
		chosen_index = function()
			return 1
		end,
		set_chosen_index = function()
			return nil
		end,
		meta_at = function()
			return {}
		end,
	}
end

testify:that("insert in the middle of line does not search or draw completion", function()
	with_stubbed_term(function()
		local completion = new_completion_stub("[")
		local inp = input.new({ completion = completion, width = 80, l = 1, c = 1 })
		local s = inp.__state

		s.lines[1] = "sudo  some_file /usr/bin/"
		s.cursor = 6
		s.offset = 0

		inp:insert("m")

		testimony.assert_equal("sudo m some_file /usr/bin/", s.lines[1])
		testimony.assert_equal(0, completion.__state.search_calls)
		testimony.assert_equal(0, completion.__state.get_calls)
		testimony.assert_equal(0, s.last_completion)
	end)
end)

testify:that("insert at end of line still searches and draws completion", function()
	with_stubbed_term(function()
		local completion = new_completion_stub("[")
		local inp = input.new({ completion = completion, width = 80, l = 1, c = 1 })
		local s = inp.__state

		local line = "sudo m some_file /usr/bin/"
		s.lines[1] = line
		s.cursor = std.utf.len(line) + 1
		s.offset = 0

		inp:insert("x")

		testimony.assert_equal(line .. "x", s.lines[1])
		testimony.assert_equal(1, completion.__state.search_calls)
		testimony.assert_equal(1, completion.__state.get_calls)
		testimony.assert_equal(1, s.last_completion)
		testimony.assert_equal(line .. "x", completion.__state.search_lines[1])
	end)
end)

testify:that("draw completion in middle of line clears stale tail and does not render", function()
	with_stubbed_term(function(writes)
		local completion = new_completion_stub("[")
		local inp = input.new({ completion = completion, width = 80, l = 1, c = 1 })
		local s = inp.__state

		s.lines[1] = "abc def"
		s.cursor = 2
		s.offset = 0
		s.last_completion = 3
		completion.__state.available = true

		inp:draw_completion()

		testimony.assert_equal(0, s.last_completion)
		testimony.assert_equal(0, completion.__state.get_calls)
		testimony.assert_match("   ", table.concat(writes, ""))
	end)
end)

testify:that("tab in middle of line flushes stale completion and does not promote", function()
	with_stubbed_term(function()
		local completion = new_completion_stub("X")
		local inp = input.new({ completion = completion, width = 80, l = 1, c = 1 })
		local s = inp.__state

		s.lines[1] = "sudo cp some_file /usr/bin/"
		s.cursor = 6
		s.offset = 0
		completion.__state.available = true
		local before = s.lines[1]

		local result = inp:handle_ctl("TAB")

		testimony.assert_nil(result)
		testimony.assert_equal(before, s.lines[1])
		testimony.assert_true(completion.__state.flush_calls >= 1)
		testimony.assert_equal(0, completion.__state.get_calls)
	end)
end)

testify:that("tab at end of line still promotes completion", function()
	with_stubbed_term(function()
		local completion = new_completion_stub("X")
		local inp = input.new({ completion = completion, width = 80, l = 1, c = 1 })
		local s = inp.__state

		s.lines[1] = "echo hi"
		s.cursor = std.utf.len(s.lines[1]) + 1
		s.offset = 0
		completion.__state.available = true

		local result = inp:handle_ctl("TAB")

		testimony.assert_equal(false, result)
		testimony.assert_equal("echo hiX", s.lines[1])
	end)
end)

testify:conclude()
