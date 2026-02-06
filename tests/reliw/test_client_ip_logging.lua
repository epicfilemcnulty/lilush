-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== web_server client ip logging ==")

local new_client = function(receive_queue)
	local client = {
		receive_queue = receive_queue,
		sent = {},
	}

	client.settimeout = function(self, timeout)
		self.last_timeout = timeout
		return true
	end

	client.receive = function(self, pattern)
		local next_value = table.remove(self.receive_queue, 1)
		if next_value == nil then
			return nil, "closed"
		end
		return next_value
	end

	client.send = function(self, payload)
		table.insert(self.sent, payload)
		return #payload
	end

	client.sent_payload = function(self)
		return table.concat(self.sent)
	end

	return client
end

local new_server = function(config, handle_fn)
	helpers.clear_modules({ "web_server" })
	local web_server = helpers.load_module_from_src("web_server", "src/luasocket/web_server.lua")
	local srv, err = web_server.new(config or {}, handle_fn)
	testimony.assert_not_nil(srv, err)
	return srv
end

testify:that("always logs client_ip and keeps forwarded context separate", function()
	local logs = {}
	local srv = new_server({
		log_level = 10,
		log_headers = {},
	}, function()
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)
	srv.__config.log_headers = {}
	srv.logger = {
		level = function(self)
			return 10
		end,
		log = function(self, msg, level)
			table.insert(logs, msg)
		end,
	}

	local client = new_client({
		"GET / HTTP/1.1",
		"Host: example.com",
		"X-Forwarded-For: 203.0.113.10",
		"X-Real-IP: 203.0.113.11",
		"Connection: close",
		"",
	})

	local state, err = srv:process_request(client, "10.0.0.5", 1)
	testimony.assert_nil(err)
	testimony.assert_equal("close", state)
	testimony.assert_match("HTTP/1.1 200", client:sent_payload())
	testimony.assert_equal(1, #logs)
	testimony.assert_equal("10.0.0.5", logs[1].client_ip)
	testimony.assert_equal("203.0.113.10", logs[1].forwarded_for)
	testimony.assert_equal("203.0.113.11", logs[1].forwarded_real_ip)
	testimony.assert_nil(logs[1]["x-real-ip"])
end)

testify:that("injects x-client-ip and applies x-real-ip fallback only when missing", function()
	local captured = {}
	local srv = new_server({
		log_level = 100,
	}, function(method, query, args, headers, body)
		captured = headers
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)

	local client = new_client({
		"GET / HTTP/1.1",
		"Host: example.com",
		"Connection: close",
		"",
	})
	local state, err = srv:process_request(client, "192.0.2.8", 1)
	testimony.assert_nil(err)
	testimony.assert_equal("close", state)
	testimony.assert_equal("192.0.2.8", captured["x-client-ip"])
	testimony.assert_equal("192.0.2.8", captured["x-real-ip"])

	client = new_client({
		"GET / HTTP/1.1",
		"Host: example.com",
		"X-Real-IP: 198.51.100.2",
		"Connection: close",
		"",
	})
	state, err = srv:process_request(client, "192.0.2.8", 1)
	testimony.assert_nil(err)
	testimony.assert_equal("close", state)
	testimony.assert_equal("192.0.2.8", captured["x-client-ip"])
	testimony.assert_equal("198.51.100.2", captured["x-real-ip"])
end)

testify:conclude()
