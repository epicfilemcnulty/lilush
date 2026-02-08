-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== shell jobs ==")

local setup_jobs = function()
	local state = {
		kill_calls = {},
		waitpid_calls = {},
		close_calls = {},
		attach_calls = {},
	}

	helpers.clear_modules({
		"std",
		"std.core",
		"shell.jobs",
	})

	helpers.stub_module("std", {
		nanoid = function()
			return "nanoid"
		end,
		ps = {
			waitpid = function(pid)
				table.insert(state.waitpid_calls, pid)
				if pid == 11 then
					return 11, 9
				end
				return 0, 0
			end,
			kill = function(pid, signal)
				table.insert(state.kill_calls, { pid = pid, signal = signal })
				return true
			end,
			pty_attach = function(master, detach_key)
				table.insert(state.attach_calls, { master = master, detach_key = detach_key })
				return true
			end,
		},
	})
	helpers.stub_module("std.core", {
		close = function(fd)
			table.insert(state.close_calls, fd)
			return true
		end,
	})

	local jobs_mod = helpers.load_module_from_src("shell.jobs", "src/shell/shell/jobs.lua")
	return jobs_mod.new({ detach_key = 20 }), state
end

testify:that("poll marks exited jobs and reap removes them", function()
	local jobs, state = setup_jobs()

	jobs.__state.entries[1] = {
		id = 1,
		pid = 11,
		status = "running",
		master = 7,
		logger_pid = 77,
	}
	jobs.__state.order = { 1 }

	jobs:poll()

	testimony.assert_equal("exited", jobs.__state.entries[1].status)
	testimony.assert_equal(9, jobs.__state.entries[1].exit_status)
	testimony.assert_nil(jobs.__state.entries[1].master)
	testimony.assert_equal(7, state.close_calls[1])

	jobs:reap()
	testimony.assert_nil(jobs.__state.entries[1])
	testimony.assert_equal(0, #jobs.__state.order)
end)

testify:that("kill validates missing and existing jobs", function()
	local jobs = setup_jobs()

	local ok, err = jobs:kill(404, 15)
	testimony.assert_nil(ok)
	testimony.assert_equal("no such job", err)

	jobs.__state.entries[2] = { id = 2, pid = 22, status = "running" }
	ok, err = jobs:kill(2, 9)
	testimony.assert_true(ok)
	testimony.assert_nil(err)
end)

testify:that("attach pauses logger and uses configured detach key", function()
	local jobs, state = setup_jobs()

	jobs.__state.entries[3] = {
		id = 3,
		pid = 33,
		status = "running",
		master = 5,
		logger_pid = 55,
	}

	local ok, err = jobs:attach(3)
	testimony.assert_true(ok)
	testimony.assert_nil(err)
	testimony.assert_equal(2, #state.kill_calls)
	testimony.assert_equal(19, state.kill_calls[1].signal)
	testimony.assert_equal(18, state.kill_calls[2].signal)
	testimony.assert_equal(5, state.attach_calls[1].master)
	testimony.assert_equal(20, state.attach_calls[1].detach_key)
end)

testify:conclude()
