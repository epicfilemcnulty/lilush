-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")
local std = require("std")

local testify = testimony.new("== reliw path sanitization and traversal protection ==")

local ensure_dir = function(path)
	if std.fs.dir_exists(path) then
		return true
	end
	return std.fs.mkdir(path)
end

local load_handle = function(state)
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
			return {
				close = function(self)
					state.close_count = state.close_count + 1
				end,
			}
		end,
	})
	helpers.stub_module("reliw.api", {
		check_waf = function()
			state.check_waf_calls = state.check_waf_calls + 1
			return false
		end,
		proxy_config = function()
			return nil
		end,
		get_userdata = function()
			return nil
		end,
		entry_index = function()
			return nil
		end,
		entry_metadata = function()
			return nil
		end,
		get_content = function()
			return nil
		end,
		check_rate_limit = function()
			return nil
		end,
	})
	helpers.stub_module("reliw.auth", {})
	helpers.stub_module("reliw.templates", {
		error_page = function(code)
			return tostring(code)
		end,
	})
	helpers.stub_module("reliw.metrics", {
		update = function()
			return 1
		end,
	})

	return helpers.load_module_from_src("reliw.handle", "src/reliw/reliw/handle.lua")
end

testify:that("rejects malformed host before downstream processing", function()
	local state = {
		close_count = 0,
		check_waf_calls = 0,
		log_count = 0,
	}
	local handle = load_handle(state)
	local logger = {
		log = function()
			state.log_count = state.log_count + 1
		end,
	}

	local body, status, headers = handle.func("GET", "/", nil, { host = "bad:host:123" }, nil, {
		cfg = { process = "server_ipv4" },
		logger = logger,
	})

	testimony.assert_equal("Bad Request", body)
	testimony.assert_equal(400, status)
	testimony.assert_equal("text/plain", headers["content-type"])
	testimony.assert_equal(1, state.close_count)
	testimony.assert_equal(0, state.check_waf_calls)
	testimony.assert_true(state.log_count > 0)
end)

testify:that("rejects suspicious encoded traversal query before downstream processing", function()
	local state = {
		close_count = 0,
		check_waf_calls = 0,
		log_count = 0,
	}
	local handle = load_handle(state)
	local logger = {
		log = function()
			state.log_count = state.log_count + 1
		end,
	}

	local body, status, headers = handle.func("GET", "/%2e%2e/secret.txt", nil, { host = "example.com" }, nil, {
		cfg = { process = "server_ipv4" },
		logger = logger,
	})

	testimony.assert_equal("Bad Request", body)
	testimony.assert_equal(400, status)
	testimony.assert_equal("text/plain", headers["content-type"])
	testimony.assert_equal(1, state.close_count)
	testimony.assert_equal(0, state.check_waf_calls)
	testimony.assert_true(state.log_count > 0)
end)

testify:that("store fetch_content blocks traversal and keeps reads under allowed roots", function()
	local test_dir = string.format("/tmp/reliw_phase3_%d_%d", os.time(), math.random(100000, 999999))
	testimony.assert_true(ensure_dir(test_dir))
	testimony.assert_true(ensure_dir(test_dir .. "/example.com"))
	testimony.assert_true(ensure_dir(test_dir .. "/__"))
	testimony.assert_true(std.fs.write_file(test_dir .. "/example.com/safe.txt", "safe-content"))
	testimony.assert_true(std.fs.write_file(test_dir .. "/__/fallback.txt", "fallback-content"))
	testimony.assert_true(std.fs.write_file(test_dir .. "/escape.txt", "must-not-be-read"))

	helpers.clear_modules({ "redis", "reliw.store" })
	helpers.stub_module("redis", {
		connect = function(cfg)
			local red = {}
			red.cmd = function(self, cmd, ...)
				if cmd == "HEXISTS" then
					return 0
				end
				if cmd == "HGET" then
					return nil
				end
				return true
			end
			red.close = function()
				return true
			end
			return red
		end,
	})

	local store_mod = helpers.load_module_from_src("reliw.store", "src/reliw/reliw/store.lua")
	local store, err = store_mod.new({
		data_dir = test_dir,
		cache_max_size = 1024,
		redis = {
			host = "127.0.0.1",
			port = 6379,
			prefix = "RLW",
		},
	})
	testimony.assert_true(store ~= nil)
	testimony.assert_nil(err)

	local content = store:fetch_content("example.com", "/ignored", { file = "/safe.txt" })
	testimony.assert_equal("safe-content", content)

	local fallback = store:fetch_content("example.com", "/fallback.txt", {})
	testimony.assert_equal("fallback-content", fallback)

	local blocked, blocked_err = store:fetch_content("example.com", "/ignored", { file = "../escape.txt" })
	testimony.assert_nil(blocked)
	testimony.assert_match("invalid file path", blocked_err)

	local blocked_query, blocked_query_err = store:fetch_content("example.com", "/../escape.txt", {})
	testimony.assert_nil(blocked_query)
	testimony.assert_match("invalid file path", blocked_query_err)

	testimony.assert_true(std.fs.remove(test_dir, true))
end)

testify:conclude()
