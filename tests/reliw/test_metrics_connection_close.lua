-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.metrics connection handling ==")

local state = {
	fail_new = false,
	close_count = 0,
	fetch_count = 0,
	log_count = 0,
}

helpers.clear_modules({ "reliw.store", "reliw.metrics" })
helpers.stub_module("reliw.store", {
	new = function()
		if state.fail_new then
			return nil, "redis down"
		end
		return {
			fetch_metrics = function(self)
				state.fetch_count = state.fetch_count + 1
				return "# TYPE http_requests_total counter\n"
			end,
			close = function(self)
				state.close_count = state.close_count + 1
			end,
		}
	end,
})

local metrics = helpers.load_module_from_src("reliw.metrics", "src/reliw/reliw/metrics.lua")

local logger = {
	log = function(self, msg, level)
		state.log_count = state.log_count + 1
	end,
}

testify:that("closes store for metrics and non-metrics paths", function()
	state.fail_new = false
	state.close_count = 0
	state.fetch_count = 0

	local body, status, headers = metrics.show("GET", "/metrics", nil, {}, nil, { cfg = {}, logger = logger })
	testimony.assert_equal(200, status)
	testimony.assert_equal("text/plain", headers["content-type"])
	testimony.assert_match("http_requests_total", body)
	testimony.assert_equal(1, state.fetch_count)
	testimony.assert_equal(1, state.close_count)

	body, status, headers = metrics.show("GET", "/nope", nil, {}, nil, { cfg = {}, logger = logger })
	testimony.assert_equal("Not Found", body)
	testimony.assert_equal(404, status)
	testimony.assert_equal("text/plain", headers["content-type"])
	testimony.assert_equal(2, state.close_count)
end)

testify:that("returns 503 on store init failure", function()
	state.fail_new = true
	state.log_count = 0

	local body, status, headers = metrics.show("GET", "/metrics", nil, {}, nil, { cfg = {}, logger = logger })
	testimony.assert_equal("db connection error", body)
	testimony.assert_equal(503, status)
	testimony.assert_equal("text/plain", headers["content-type"])
	testimony.assert_true(state.log_count > 0)
end)

testify:conclude()
