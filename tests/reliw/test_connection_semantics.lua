-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== web.server connection semantics ==")

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
	helpers.clear_modules({ "web.server" })
	local web_server = helpers.load_module_from_src("web.server", "src/web/server.lua")
	local srv, err = web_server.new(config or {}, handle_fn)
	testimony.assert_not_nil(srv, err)
	return srv
end

testify:that("treats HTTP/1.1 Connection token case-insensitively", function()
	local srv = new_server({
		log_level = 100,
	}, function()
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)

	local client = new_client({
		"GET / HTTP/1.1",
		"Host: example.com",
		"Connection: Close",
		"",
	})

	local state, err = srv:process_request(client, "127.0.0.1", 1)
	testimony.assert_nil(err)
	testimony.assert_equal("close", state)
	testimony.assert_match("connection: close", client:sent_payload():lower())
end)

testify:that("defaults HTTP/1.0 connections to close", function()
	local srv = new_server({
		log_level = 100,
	}, function()
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)

	local client = new_client({
		"GET / HTTP/1.0",
		"Host: example.com",
		"",
	})

	local state, err = srv:process_request(client, "127.0.0.1", 1)
	testimony.assert_nil(err)
	testimony.assert_equal("close", state)
	testimony.assert_match("connection: close", client:sent_payload():lower())
end)

testify:that("keeps HTTP/1.0 connection alive only when explicitly requested", function()
	local srv = new_server({
		log_level = 100,
	}, function()
		return "ok", 200, { ["content-type"] = "text/plain" }
	end)

	local client = new_client({
		"GET / HTTP/1.0",
		"Host: example.com",
		"Connection: Keep-Alive",
		"",
	})

	local state, err = srv:process_request(client, "127.0.0.1", 1)
	testimony.assert_nil(err)
	testimony.assert_equal("keep-alive", state)
	testimony.assert_true(client:sent_payload():lower():find("connection: keep-alive", 1, true) ~= nil)
end)

testify:conclude()
