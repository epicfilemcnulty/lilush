-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.proxy https and chunk extensions ==")

local scenario = {}
local close_count = 0
local wrap_calls = 0
local handshake_calls = 0
local last_tls_cfg = nil
local sent_requests = {}

helpers.clear_modules({ "socket", "ssl", "reliw.proxy" })
helpers.stub_module("socket", {
	tcp = function()
		local sock = {}
		sock.settimeout = function(self, timeout)
			scenario.last_timeout = timeout
			return true
		end
		sock.connect = function(self, host, port)
			scenario.connected_host = host
			scenario.connected_port = port
			if scenario.connect_err then
				return nil, scenario.connect_err
			end
			return true
		end
		sock.send = function(self, request)
			table.insert(sent_requests, request)
			return #request
		end
		sock.receive = function(self, pattern)
			local value = table.remove(scenario.receive_values, 1)
			if value == nil then
				return nil, "eof"
			end
			return value
		end
		sock.close = function(self)
			close_count = close_count + 1
			return true
		end
		return sock
	end,
})
helpers.stub_module("ssl", {
	wrap = function(sock, cfg)
		wrap_calls = wrap_calls + 1
		last_tls_cfg = cfg
		if scenario.wrap_err then
			return nil, scenario.wrap_err
		end
		local tls_sock = {}
		tls_sock.settimeout = function(self, timeout)
			scenario.last_timeout = timeout
			return true
		end
		tls_sock.dohandshake = function(self)
			handshake_calls = handshake_calls + 1
			if scenario.handshake_err then
				return nil, scenario.handshake_err
			end
			return true
		end
		tls_sock.send = function(self, request)
			table.insert(sent_requests, request)
			return #request
		end
		tls_sock.receive = function(self, pattern)
			local value = table.remove(scenario.receive_values, 1)
			if value == nil then
				return nil, "eof"
			end
			return value
		end
		tls_sock.close = function(self)
			close_count = close_count + 1
			return true
		end
		return tls_sock
	end,
})

local proxy = helpers.load_module_from_src("reliw.proxy", "src/reliw/reliw/proxy.lua")

testify:that("proxies HTTPS upstreams with TLS and chunk extensions", function()
	scenario = {
		receive_values = {
			"HTTP/1.1 200 OK",
			"Transfer-Encoding: chunked",
			"",
			"4;foo=bar",
			"Wiki",
			"",
			"5;bar=baz",
			"pedia",
			"",
			"0;fin=true",
			"X-Trace: done",
			"",
		},
	}
	close_count = 0
	wrap_calls = 0
	handshake_calls = 0
	last_tls_cfg = nil
	sent_requests = {}

	local content, status, headers = proxy.handle(nil, "GET", "/", { host = "example.com" }, nil, {
		scheme = "https",
		host = "upstream.example",
		tls_insecure = true,
	})

	testimony.assert_equal("Wikipedia", content)
	testimony.assert_equal(200, status)
	testimony.assert_equal("9", headers["content-length"])
	testimony.assert_nil(headers["transfer-encoding"])
	testimony.assert_equal(1, wrap_calls)
	testimony.assert_equal(1, handshake_calls)
	testimony.assert_equal("upstream.example", last_tls_cfg.server_name)
	testimony.assert_equal(true, last_tls_cfg.no_verify_mode)
	testimony.assert_match("host: upstream%.example", sent_requests[1])
	testimony.assert_equal(1, close_count)
end)

testify:that("returns controlled error when TLS handshake fails", function()
	scenario = {
		handshake_err = "self-signed cert",
		receive_values = {},
	}
	close_count = 0
	wrap_calls = 0
	handshake_calls = 0
	last_tls_cfg = nil
	sent_requests = {}

	local content, err = proxy.handle(nil, "GET", "/", { host = "example.com" }, nil, {
		scheme = "https",
		host = "upstream.example",
	})

	testimony.assert_nil(content)
	testimony.assert_match("TLS handshake failed", err)
	testimony.assert_equal(1, wrap_calls)
	testimony.assert_equal(1, handshake_calls)
	testimony.assert_equal(1, close_count)
end)

testify:that("does not wrap plain HTTP upstream sockets", function()
	scenario = {
		receive_values = {
			"HTTP/1.1 200 OK",
			"Content-Length: 2",
			"",
			"ok",
		},
	}
	close_count = 0
	wrap_calls = 0
	handshake_calls = 0
	last_tls_cfg = nil
	sent_requests = {}

	local content, status = proxy.handle(nil, "GET", "/", { host = "example.com" }, nil, {
		scheme = "http",
		host = "upstream.example",
		port = 8080,
	})

	testimony.assert_equal("ok", content)
	testimony.assert_equal(200, status)
	testimony.assert_equal(0, wrap_calls)
	testimony.assert_equal(0, handshake_calls)
	testimony.assert_equal(1, close_count)
end)

testify:that("uses x-client-ip as x-forwarded-for when provided", function()
	scenario = {
		receive_values = {
			"HTTP/1.1 200 OK",
			"Content-Length: 2",
			"",
			"ok",
		},
	}
	close_count = 0
	wrap_calls = 0
	handshake_calls = 0
	last_tls_cfg = nil
	sent_requests = {}

	local content, status = proxy.handle(
		nil,
		"GET",
		"/",
		{
			host = "example.com",
			["x-client-ip"] = "10.10.10.10",
			["x-real-ip"] = "203.0.113.77",
		},
		nil,
		{
			scheme = "http",
			host = "upstream.example",
			port = 8080,
		}
	)

	testimony.assert_equal("ok", content)
	testimony.assert_equal(200, status)
	testimony.assert_match("x%-forwarded%-for: 10%.10%.10%.10", sent_requests[1])
	testimony.assert_equal(1, close_count)
end)

testify:conclude()
