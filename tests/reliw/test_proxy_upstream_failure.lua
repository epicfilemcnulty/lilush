-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.proxy upstream failures ==")

local mode = "tcp_fail"
local close_count = 0

helpers.clear_modules({ "socket", "reliw.proxy" })
helpers.stub_module("socket", {
	tcp = function()
		if mode == "tcp_fail" then
			return nil, "cannot create socket"
		end

		local sock = {}
		sock.settimeout = function(self, timeout)
			return true
		end
		sock.connect = function(self, host, port)
			return nil, "connection refused"
		end
		sock.close = function(self)
			close_count = close_count + 1
			return true
		end
		return sock
	end,
})

local proxy = helpers.load_module_from_src("reliw.proxy", "src/reliw/reliw/proxy.lua")

local target = {
	scheme = "http",
	host = "127.0.0.1",
	port = 18080,
}

testify:that("returns error if socket creation fails", function()
	mode = "tcp_fail"
	close_count = 0

	local content, err = proxy.handle(nil, "GET", "/", { host = "example.com" }, nil, target)
	testimony.assert_nil(content)
	testimony.assert_match("failed to create upstream socket", err)
	testimony.assert_equal(0, close_count)
end)

testify:that("returns error if upstream connect fails without throwing", function()
	mode = "connect_fail"
	close_count = 0

	local content, err = proxy.handle(nil, "GET", "/", { host = "example.com" }, nil, target)
	testimony.assert_nil(content)
	testimony.assert_match("failed to connect upstream", err)
	testimony.assert_equal(1, close_count)
end)

testify:conclude()
