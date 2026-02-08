-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== web.server socket option startup tolerance ==")

local setup_common_modules = function(logs)
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
				return -1
			end,
		},
	})
	helpers.stub_module("ssl", {})
end

testify:that("continues startup when reuse socket options are unsupported", function()
	helpers.clear_modules({ "std", "socket", "ssl", "web.server" })

	local logs = {}
	local select_calls = 0

	setup_common_modules(logs)

	local fake_server = {
		setoption = function(self, option, value)
			if option == "reuseaddr" or option == "reuseport" then
				return nil, "setsockopt failed"
			end
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
		close = function(self)
			return true
		end,
	}

	helpers.stub_module("socket", {
		tcp = function()
			return fake_server
		end,
		select = function(read, write, timeout)
			select_calls = select_calls + 1
			if select_calls == 1 then
				return nil, nil, "timeout"
			end
			error("stop-loop")
		end,
	})

	local web_server = helpers.load_module_from_src("web.server", "src/web/server.lua")
	local srv, err = web_server.new({ log_level = 100 }, function()
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)
	testimony.assert_not_nil(srv, err)

	local ok, run_err = pcall(function()
		srv:serve()
	end)
	testimony.assert_false(ok)
	testimony.assert_true(tostring(run_err):find("stop-loop", 1, true) ~= nil)
	testimony.assert_true(select_calls >= 2)

	local saw_reuseaddr_warn = false
	local saw_reuseport_warn = false
	for _, entry in ipairs(logs) do
		if type(entry.msg) == "table" and entry.msg.msg == "failed to set socket option; continuing" then
			if entry.msg.option == "reuseaddr" then
				saw_reuseaddr_warn = true
			end
			if entry.msg.option == "reuseport" then
				saw_reuseport_warn = true
			end
		end
	end
	testimony.assert_true(saw_reuseaddr_warn)
	testimony.assert_true(saw_reuseport_warn)
end)

testify:that("still fails startup when bind fails", function()
	helpers.clear_modules({ "std", "socket", "ssl", "web.server" })

	local logs = {}

	setup_common_modules(logs)

	local fake_server = {
		setoption = function(self, option, value)
			return true
		end,
		bind = function(self, ip, port)
			return nil, "address already in use"
		end,
		listen = function(self, backlog)
			return true
		end,
		settimeout = function(self, timeout)
			return true
		end,
		close = function(self)
			return true
		end,
	}

	helpers.stub_module("socket", {
		tcp = function()
			return fake_server
		end,
		select = function(read, write, timeout)
			error("select should not be called when bind fails")
		end,
	})

	local web_server = helpers.load_module_from_src("web.server", "src/web/server.lua")
	local srv, err = web_server.new({ log_level = 100 }, function()
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)
	testimony.assert_not_nil(srv, err)

	local ok, serve_err = srv:serve()
	testimony.assert_nil(ok)
	testimony.assert_true(tostring(serve_err):find("failed to bind", 1, true) ~= nil)
	testimony.assert_true(tostring(serve_err):find("address already in use", 1, true) ~= nil)

	local saw_warn = false
	for _, entry in ipairs(logs) do
		if entry.msg_level == "warn" then
			saw_warn = true
			break
		end
	end
	testimony.assert_false(saw_warn)
end)

testify:conclude()
