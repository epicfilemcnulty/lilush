-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.auth malformed body ==")

testify:that("web.parse_args tolerates nil and non-string bodies", function()
	helpers.clear_modules({ "web" })
	local web = helpers.load_module_from_src("web", "src/luasocket/web.lua")

	local parsed_nil = web.parse_args(nil)
	testimony.assert_equal("table", type(parsed_nil))
	testimony.assert_equal(true, next(parsed_nil) == nil)

	local parsed_table = web.parse_args({})
	testimony.assert_equal("table", type(parsed_table))
	testimony.assert_equal(true, next(parsed_table) == nil)

	local parsed = web.parse_args("login=alice+smith&password=s3cret")
	testimony.assert_equal("alice smith", parsed.login)
	testimony.assert_equal("s3cret", parsed.password)
end)

testify:that("auth login POST with malformed body returns deterministic 401", function()
	helpers.clear_modules({ "crypto", "web", "reliw.auth" })
	helpers.stub_module("crypto", {
		hmac = function()
			return ""
		end,
		bin_to_hex = function()
			return ""
		end,
	})
	local web = helpers.load_module_from_src("web", "src/luasocket/web.lua")
	testimony.assert_not_nil(web)
	local auth = helpers.load_module_from_src("reliw.auth", "src/reliw/reliw/auth.lua")

	local seen_host = nil
	local seen_user = nil
	local store = {
		fetch_userinfo = function(self, host, user)
			seen_host = host
			seen_user = user
			return nil, "no user"
		end,
	}

	local ok, body, status = pcall(auth.login_page, store, "POST", "/login", nil, { host = "example.com:8080" }, nil)
	testimony.assert_true(ok)
	testimony.assert_equal("Wrong login/pass", body)
	testimony.assert_equal(401, status)
	testimony.assert_equal("example.com", seen_host)
	testimony.assert_equal("", seen_user)

	ok, body, status = pcall(auth.login_page, store, "POST", "/login", nil, { host = "example.com:8080" }, {})
	testimony.assert_true(ok)
	testimony.assert_equal("Wrong login/pass", body)
	testimony.assert_equal(401, status)
end)

testify:conclude()
