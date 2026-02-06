-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== web_server fork limit overload handling ==")

testify:that("accepts and closes overloaded clients with 503", function()
	helpers.clear_modules({ "std", "socket", "ssl", "web_server" })

	local sent_payload = ""
	local client_close_count = 0
	local accept_calls = 0
	local fork_calls = 0
	local select_calls = 0
	local logs = {}

	local fake_client = {
		send = function(self, payload)
			sent_payload = sent_payload .. payload
			return #payload
		end,
		close = function(self)
			client_close_count = client_close_count + 1
			return true
		end,
	}

	local fake_server = {
		setoption = function(self, option, value)
			return true
		end,
		bind = function(self, ip, port)
			return true
		end,
		listen = function(self, backlog)
			return true
		end,
		settimeout = function(self, timeout)
			return true
		end,
		getsockname = function(self)
			return "127.0.0.1", 8080
		end,
		accept = function(self)
			accept_calls = accept_calls + 1
			return fake_client
		end,
		close = function(self)
			return true
		end,
	}

	helpers.stub_module("std", {
		fs = {
			file_exists = function(path)
				return true
			end,
		},
		tbl = {
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
					set_level = function(self, next_level)
						return true
					end,
					level = function(self)
						return 100
					end,
					level_str = function(self)
						return "debug"
					end,
					log = function(self, msg, msg_level)
						table.insert(logs, { msg = msg, msg_level = msg_level })
						return true
					end,
				}
			end,
		},
		ps = {
			waitpid = function(pid)
				return nil
			end,
			fork = function()
				fork_calls = fork_calls + 1
				return -1
			end,
		},
	})

	helpers.stub_module("socket", {
		tcp = function()
			return fake_server
		end,
		select = function(read, write, timeout)
			select_calls = select_calls + 1
			if select_calls == 1 then
				return { fake_server }, nil, nil
			end
			error("stop-loop")
		end,
	})

	helpers.stub_module("ssl", {})

	local web_server = helpers.load_module_from_src("web_server", "src/luasocket/web_server.lua")
	local srv, err = web_server.new({ fork_limit = 0, log_level = 100 }, function()
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)
	testimony.assert_not_nil(srv, err)

	local ok, run_err = pcall(function()
		srv:serve()
	end)

	testimony.assert_false(ok)
	testimony.assert_true(tostring(run_err):find("stop-loop", 1, true) ~= nil)
	testimony.assert_equal(1, accept_calls)
	testimony.assert_equal(0, fork_calls)
	testimony.assert_equal(1, client_close_count)
	testimony.assert_true(sent_payload:find("HTTP/1.1 503", 1, true) ~= nil)
	testimony.assert_true(sent_payload:find("Connection: close", 1, true) ~= nil)

	local saw_overload_log = false
	for _, entry in ipairs(logs) do
		if entry.msg == "fork limit reached" then
			saw_overload_log = true
			break
		end
	end
	testimony.assert_true(saw_overload_log)
end)

testify:conclude()
