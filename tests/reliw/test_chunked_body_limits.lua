-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== web.server chunked body limits ==")

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

local new_server = function(max_body_size, handle_fn)
	helpers.clear_modules({ "web.server" })
	local web_server = helpers.load_module_from_src("web.server", "src/web/server.lua")
	local srv, err = web_server.new({
		max_body_size = max_body_size,
		log_level = 100,
	}, handle_fn)
	testimony.assert_true(srv ~= nil)
	testimony.assert_nil(err)
	return srv
end

testify:that("rejects oversized chunked bodies with 413", function()
	local handle_called = false
	local srv = new_server(8, function()
		handle_called = true
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)

	local client = new_client({
		"POST /upload HTTP/1.1",
		"Host: example.com",
		"Transfer-Encoding: chunked",
		"",
		"5",
		"hello",
		"",
		"5",
		"world",
		"",
		"0",
		"",
	})

	local state, err = srv:process_request(client, "127.0.0.1", 1)
	testimony.assert_nil(state)
	testimony.assert_match("max_body_size limit violation", err)
	testimony.assert_match("HTTP/1.1 413", client:sent_payload())
	testimony.assert_true(not handle_called)
end)

testify:that("accepts chunked bodies within max_body_size", function()
	local captured_body = nil
	local srv = new_server(8, function(method, query, args, headers, body)
		captured_body = body
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)

	local client = new_client({
		"POST /upload HTTP/1.1",
		"Host: example.com",
		"Transfer-Encoding: chunked",
		"Connection: close",
		"",
		"3",
		"abc",
		"",
		"0",
		"",
	})

	local state, err = srv:process_request(client, "127.0.0.1", 1)
	testimony.assert_nil(err)
	testimony.assert_equal("close", state)
	testimony.assert_equal("abc", captured_body)
	testimony.assert_match("HTTP/1.1 200", client:sent_payload())
end)

testify:conclude()
