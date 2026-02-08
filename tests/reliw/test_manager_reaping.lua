-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw manager process reaping ==")

testify:that("waits on any child and drains exited siblings when primary exits", function()
	helpers.clear_modules({
		"std",
		"cjson.safe",
		"web.server",
		"reliw",
		"reliw.handle",
		"reliw.metrics",
		"reliw.store",
	})

	local fork_pids = { 301, 101, 202 } -- metrics, ipv4(primary), ipv6
	local wait_events = { 202, 101 } -- non-primary exits first, then primary
	local waitpid_events = { 301, 0 } -- drain already-exited sibling
	local wait_args = {}
	local waitpid_args = {}
	local decode_calls = 0
	local serve_calls = 0

	helpers.stub_module("std", {
		fs = {
			file_exists = function(path)
				return true
			end,
			read_file = function(path)
				return "{}"
			end,
		},
		tbl = {
			copy = function(t)
				local out = {}
				for k, v in pairs(t or {}) do
					if type(v) == "table" then
						local inner = {}
						for ik, iv in pairs(v) do
							inner[ik] = iv
						end
						out[k] = inner
					else
						out[k] = v
					end
				end
				return out
			end,
			merge = function(dst, src)
				for k, v in pairs(src or {}) do
					if type(v) == "table" and type(dst[k]) == "table" then
						for ik, iv in pairs(v) do
							dst[k][ik] = iv
						end
					else
						dst[k] = v
					end
				end
				return dst
			end,
		},
		logger = {
			new = function(level)
				return {
					level = function(self)
						return level or 10
					end,
					log = function(self, msg, msg_level)
						return true
					end,
				}
			end,
		},
		ps = {
			fork = function()
				return table.remove(fork_pids, 1)
			end,
			wait = function(pid)
				table.insert(wait_args, pid)
				local event_pid = table.remove(wait_events, 1)
				if event_pid == nil then
					return nil, "no children"
				end
				return event_pid, 0
			end,
			waitpid = function(pid)
				table.insert(waitpid_args, pid)
				local event_pid = table.remove(waitpid_events, 1)
				if event_pid == nil then
					return nil, "no children"
				end
				return event_pid
			end,
		},
	})

	helpers.stub_module("cjson.safe", {
		decode = function(raw)
			decode_calls = decode_calls + 1
			return {
				ip = "127.0.0.1",
				port = 8080,
				ipv6 = "::1",
				log_level = 10,
				metrics = { ip = "127.0.0.1", port = 9101 },
				redis = { host = "127.0.0.1", port = 6379, db = 13, prefix = "RLW" },
			}
		end,
	})

	helpers.stub_module("web.server", {
		new = function(cfg, handler)
			return {
				serve = function(self)
					serve_calls = serve_calls + 1
					return true
				end,
			}
		end,
	})
	helpers.stub_module("reliw.handle", { func = function() end })
	helpers.stub_module("reliw.metrics", { show = function() end })
	helpers.stub_module("reliw.store", {
		new = function(cfg)
			return { close = function(self) end }
		end,
	})

	local reliw = helpers.load_module_from_src("reliw", "src/reliw/reliw.lua")
	local app, err = reliw.new()
	testimony.assert_not_nil(app, err)
	testimony.assert_equal(false, app:has_child_pid(101))

	app:run()

	testimony.assert_equal(2, #wait_args)
	testimony.assert_equal(-1, wait_args[1])
	testimony.assert_equal(-1, wait_args[2])
	testimony.assert_true(#waitpid_args >= 1)
	testimony.assert_equal(-1, waitpid_args[1])
	testimony.assert_equal(0, serve_calls)
	testimony.assert_equal(false, app:has_child_pid(101))
	testimony.assert_equal(false, app:has_child_pid(202))
	testimony.assert_equal(false, app:has_child_pid(301))
	local child_pids = app:list_child_pids()
	testimony.assert_nil(next(child_pids))
	testimony.assert_equal(1, decode_calls)
end)

testify:conclude()
