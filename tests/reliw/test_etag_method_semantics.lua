-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.handle etag method semantics ==")

local load_handle = function()
	local close_count = 0
	local metric_statuses = {}
	local db = {
		close = function(self)
			close_count = close_count + 1
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
				methods = { GET = true, HEAD = true, POST = true },
				cache_control = "max-age=60",
			}
		end,
		get_content = function()
			return "fresh-body", "etag-1", "10", "text/plain", "Title"
		end,
		check_rate_limit = function()
			return nil
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
		update = function(self, host, method, query, status)
			table.insert(metric_statuses, status)
			return 1
		end,
	})

	local handle = helpers.load_module_from_src("reliw.handle", "src/reliw/reliw/handle.lua")
	local ctx = {
		cfg = { process = "server_ipv4" },
		logger = {
			log = function(self, msg, level)
				return true
			end,
		},
	}

	return handle, ctx, metric_statuses, function()
		return close_count
	end
end

testify:that("GET with matching If-None-Match returns 304", function()
	local handle, ctx, metric_statuses, get_close_count = load_handle()
	local body, status, headers = handle.func("GET", "/post", nil, {
		host = "example.com",
		["if-none-match"] = "etag-1",
	}, nil, ctx)

	testimony.assert_equal("", body)
	testimony.assert_equal(304, status)
	testimony.assert_equal("etag-1", headers["etag"])
	testimony.assert_equal(1, #metric_statuses)
	testimony.assert_equal(304, metric_statuses[1])
	testimony.assert_equal(1, get_close_count())
end)

testify:that("HEAD stays bodyless and does not emit 304", function()
	local handle, ctx, metric_statuses, get_close_count = load_handle()
	local body, status = handle.func("HEAD", "/post", nil, {
		host = "example.com",
		["if-none-match"] = "etag-1",
	}, nil, ctx)

	testimony.assert_equal("", body)
	testimony.assert_equal(200, status)
	testimony.assert_equal(1, #metric_statuses)
	testimony.assert_equal(200, metric_statuses[1])
	testimony.assert_equal(1, get_close_count())
end)

testify:that("POST with matching If-None-Match does not short-circuit to 304", function()
	local handle, ctx, metric_statuses, get_close_count = load_handle()
	local body, status, headers = handle.func("POST", "/post", nil, {
		host = "example.com",
		["if-none-match"] = "etag-1",
	}, nil, ctx)

	testimony.assert_equal("fresh-body", body)
	testimony.assert_equal(200, status)
	testimony.assert_equal("etag-1", headers["etag"])
	testimony.assert_equal(1, #metric_statuses)
	testimony.assert_equal(200, metric_statuses[1])
	testimony.assert_equal(1, get_close_count())
end)

testify:conclude()
