-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local term = require("term")
local tty = require("shell.tty")

local testify = testimony.new("== shell.tty transitions ==")

local with_stubbed_term = function(fn)
	local original = {
		write = term.write,
		disable_kkbp = term.disable_kkbp,
		enable_kkbp = term.enable_kkbp,
		disable_bracketed_paste = term.disable_bracketed_paste,
		enable_bracketed_paste = term.enable_bracketed_paste,
		set_sane_mode = term.set_sane_mode,
		set_raw_mode = term.set_raw_mode,
	}

	local calls = {}
	local mark = function(name)
		table.insert(calls, name)
	end

	term.write = function(text)
		mark("write:" .. tostring(text or ""))
	end
	term.disable_kkbp = function()
		mark("disable_kkbp")
	end
	term.enable_kkbp = function()
		mark("enable_kkbp")
	end
	term.disable_bracketed_paste = function()
		mark("disable_bracketed_paste")
	end
	term.enable_bracketed_paste = function()
		mark("enable_bracketed_paste")
	end
	term.set_sane_mode = function()
		mark("set_sane_mode")
	end
	term.set_raw_mode = function()
		mark("set_raw_mode")
	end

	local ok, err = pcall(fn, calls)

	term.write = original.write
	term.disable_kkbp = original.disable_kkbp
	term.enable_kkbp = original.enable_kkbp
	term.disable_bracketed_paste = original.disable_bracketed_paste
	term.enable_bracketed_paste = original.enable_bracketed_paste
	term.set_sane_mode = original.set_sane_mode
	term.set_raw_mode = original.set_raw_mode

	if not ok then
		error(err)
	end
end

testify:that("enter_exec_mode disables kkbp before switching to sane mode", function()
	with_stubbed_term(function(calls)
		tty.enter_exec_mode({ newline = true })
		testimony.assert_equal({
			"disable_kkbp",
			"disable_bracketed_paste",
			"write:\r\n",
			"set_sane_mode",
		}, calls)
	end)
end)

testify:that("enter_exec_mode omits newline by default", function()
	with_stubbed_term(function(calls)
		tty.enter_exec_mode()
		testimony.assert_equal({
			"disable_kkbp",
			"disable_bracketed_paste",
			"set_sane_mode",
		}, calls)
	end)
end)

testify:that("leave_exec_mode restores raw mode then terminal enhancements", function()
	with_stubbed_term(function(calls)
		tty.leave_exec_mode()
		testimony.assert_equal({
			"set_raw_mode",
			"enable_kkbp",
			"enable_bracketed_paste",
		}, calls)
	end)
end)

testify:that("run_in_sane_mode keeps transitions balanced and returns handler value", function()
	with_stubbed_term(function(calls)
		local result = tty.run_in_sane_mode(function()
			table.insert(calls, "handler")
			return "ok"
		end)
		testimony.assert_equal("ok", result)
		testimony.assert_equal({
			"disable_kkbp",
			"disable_bracketed_paste",
			"set_sane_mode",
			"handler",
			"set_raw_mode",
			"enable_kkbp",
			"enable_bracketed_paste",
		}, calls)
	end)
end)

testify:that("run_in_sane_mode restores terminal state even when handler errors", function()
	with_stubbed_term(function(calls)
		local ok, err = pcall(function()
			tty.run_in_sane_mode(function()
				table.insert(calls, "handler")
				error("boom")
			end)
		end)

		testimony.assert_false(ok)
		testimony.assert_match("boom", tostring(err))
		testimony.assert_equal({
			"disable_kkbp",
			"disable_bracketed_paste",
			"set_sane_mode",
			"handler",
			"set_raw_mode",
			"enable_kkbp",
			"enable_bracketed_paste",
		}, calls)
	end)
end)

testify:that("run_in_raw_passthrough_mode toggles raw state without re-enabling kkbp", function()
	with_stubbed_term(function(calls)
		local result = tty.run_in_raw_passthrough_mode(function()
			table.insert(calls, "handler")
			return "ok"
		end)
		testimony.assert_equal("ok", result)
		testimony.assert_equal({
			"disable_kkbp",
			"disable_bracketed_paste",
			"set_raw_mode",
			"handler",
			"set_sane_mode",
		}, calls)
	end)
end)

testify:that("run_in_raw_passthrough_mode restores sane mode on error", function()
	with_stubbed_term(function(calls)
		local ok, err = pcall(function()
			tty.run_in_raw_passthrough_mode(function()
				table.insert(calls, "handler")
				error("boom")
			end)
		end)

		testimony.assert_false(ok)
		testimony.assert_match("boom", tostring(err))
		testimony.assert_equal({
			"disable_kkbp",
			"disable_bracketed_paste",
			"set_raw_mode",
			"handler",
			"set_sane_mode",
		}, calls)
	end)
end)

testify:conclude()
