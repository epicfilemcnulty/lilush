-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.handle rate limit ip source ==")

local load_handle = function(captured)
	local db = {
		close = function(self)
			return true
		end,
	}

	helpers.clear_modules({
		"reliw.handle",
		"reliw.store",
		"reliw.api",
		"reliw.auth",
		"reliw.templates",
		"reliw.metrics",
	})

	helpers.stub_module("reliw.store", {
		new = function()
			return db
		end,
	})
	helpers.stub_module("reliw.api", {
		check_waf = function()
			return false
		end,
		proxy_config = function()
			return nil
		end,
		get_userdata = function()
			return nil
		end,
		entry_index = function()
			return "entry-1"
		end,
		entry_metadata = function()
			return {
				methods = { GET = true },
				rate_limit = {
					GET = { limit = 100, period = 60 },
				},
			}
		end,
		check_rate_limit = function(self, host, method, query, remote_ip, period)
			captured.ip = remote_ip
			return 0
		end,
		get_content = function()
			return "body", "etag", "4", "text/plain", "Title"
		end,
	})
	helpers.stub_module("reliw.auth", {
		authorized = function()
			return true
		end,
	})
	helpers.stub_module("reliw.templates", {
		error_page = function(status)
			return "error-" .. tostring(status)
		end,
		render_page = function(content)
			return content
		end,
		markdown_to_html = function(content)
			return content
		end,
	})
	helpers.stub_module("reliw.metrics", {
		update = function()
			return 1
		end,
	})

	local handle = helpers.load_module_from_src("reliw.handle", "src/reliw/reliw/handle.lua")
	return handle,
		{
			cfg = { process = "server_ipv4" },
			logger = {
				log = function(self, msg, level)
					return true
				end,
			},
		}
end

testify:that("prefers x-client-ip for rate limiting", function()
	local captured = {}
	local handle, ctx = load_handle(captured)

	local body, status = handle.func("GET", "/post", nil, {
		host = "example.com",
		["x-client-ip"] = "10.0.0.5",
		["x-real-ip"] = "198.51.100.4",
	}, nil, ctx)

	testimony.assert_equal("body", body)
	testimony.assert_equal(200, status)
	testimony.assert_equal("10.0.0.5", captured.ip)
end)

testify:that("falls back to x-real-ip when x-client-ip is absent", function()
	local captured = {}
	local handle, ctx = load_handle(captured)

	local body, status = handle.func("GET", "/post", nil, {
		host = "example.com",
		["x-real-ip"] = "198.51.100.4",
	}, nil, ctx)

	testimony.assert_equal("body", body)
	testimony.assert_equal(200, status)
	testimony.assert_equal("198.51.100.4", captured.ip)
end)

testify:conclude()
