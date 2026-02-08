-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.store acme challenge helpers ==")

local state = {}

local reset_state = function()
	state = {
		calls = {},
		close_count = 0,
	}
end

helpers.clear_modules({
	"std",
	"redis",
	"cjson.safe",
	"crypto",
	"reliw.store",
})

helpers.stub_module("std", {
	nanoid = function()
		return "nanoid"
	end,
})
helpers.stub_module("cjson.safe", {
	decode = function(v)
		return {}
	end,
})
helpers.stub_module("crypto", {})
helpers.stub_module("redis", {
	connect = function(cfg)
		return {
			cmd = function(self, cmd, ...)
				local args = { ... }
				table.insert(state.calls, { cmd = cmd, args = args })
				if cmd == "SET" then
					return "OK"
				end
				if cmd == "DEL" then
					return 1
				end
				return nil, "unexpected command: " .. tostring(cmd)
			end,
			close = function(self)
				state.close_count = state.close_count + 1
				return true
			end,
		}
	end,
})

local store_mod = helpers.load_module_from_src("reliw.store", "src/reliw/reliw/store.lua")

local new_store = function()
	local store, err = store_mod.new({
		redis = {
			host = "127.0.0.1",
			port = 6379,
			db = 13,
			prefix = "RLW",
		},
		data_dir = "/www",
		cache_max_size = 1024,
		metrics = {},
	})
	testimony.assert_not_nil(store, err)
	return store
end

testify:that("provisions and cleans up acme challenges under DATA namespace", function()
	reset_state()
	local store = new_store()

	local ok, err = store:provision_acme_challenge("Example.com", "abc_123-xyz", "token.thumbprint")
	testimony.assert_equal("OK", ok)
	testimony.assert_nil(err)
	testimony.assert_equal("SET", state.calls[1].cmd)
	testimony.assert_equal("RLW:DATA:example.com:.well-known/acme-challenge/abc_123-xyz", state.calls[1].args[1])
	testimony.assert_equal("token.thumbprint", state.calls[1].args[2])

	local deleted, cleanup_err = store:cleanup_acme_challenge("example.com", "abc_123-xyz")
	testimony.assert_equal(1, deleted)
	testimony.assert_nil(cleanup_err)
	testimony.assert_equal("DEL", state.calls[2].cmd)
	testimony.assert_equal("RLW:DATA:example.com:.well-known/acme-challenge/abc_123-xyz", state.calls[2].args[1])
end)

testify:that("rejects invalid acme challenge args", function()
	reset_state()
	local store = new_store()

	local ok, err = store:provision_acme_challenge("example.com:443", "abc", "value")
	testimony.assert_nil(ok)
	testimony.assert_equal("domain has invalid separators", err)

	ok, err = store:provision_acme_challenge("example.com", "bad/token", "value")
	testimony.assert_nil(ok)
	testimony.assert_equal("token has invalid separators", err)

	ok, err = store:provision_acme_challenge("example.com", "abc", "")
	testimony.assert_nil(ok)
	testimony.assert_equal("value must be a non-empty string", err)

	testimony.assert_nil(state.calls[1])
end)

testify:conclude()
