-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.handle store init failure ==")

testify:that("returns 503 when store init fails", function()
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
			return nil, "redis down"
		end,
	})
	helpers.stub_module("reliw.api", {})
	helpers.stub_module("reliw.auth", {})
	helpers.stub_module("reliw.templates", {})
	helpers.stub_module("reliw.metrics", {})

	local handle = helpers.load_module_from_src("reliw.handle", "src/reliw/reliw/handle.lua")
	local logs = {}
	local logger = {
		log = function(self, msg, level)
			table.insert(logs, { msg = msg, level = level })
		end,
	}

	local ok, body, status, headers = pcall(handle.func, "GET", "/", nil, { host = "example.com" }, nil, {
		cfg = { process = "server_ipv4" },
		logger = logger,
	})
	testimony.assert_true(ok)
	testimony.assert_equal("Service Unavailable", body)
	testimony.assert_equal(503, status)
	testimony.assert_equal("text/plain", headers["content-type"])
	testimony.assert_true(#logs >= 1)
	testimony.assert_equal("store init failed", logs[1].msg.msg)
end)

testify:conclude()
