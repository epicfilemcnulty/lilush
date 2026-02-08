-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.redis._helpers")

local testify = testimony.new("== redis caller compatibility ==")

local make_std_stub = function()
	return {
		hostname = function()
			return "test-host"
		end,
		tbl = {
			merge = function(dst, src)
				for k, v in pairs(src or {}) do
					dst[k] = v
				end
				return dst
			end,
		},
		fs = {
			read_file = function()
				return ""
			end,
			list_dir = function()
				return {}
			end,
		},
		mime = {
			type = function()
				return "text/plain"
			end,
		},
		nanoid = function()
			return "nanoid"
		end,
	}
end

testify:that("shell.store uses redis.connect(url) and redis cmd/close methods", function()
	local state = {
		connect_arg = nil,
		close_count = 0,
		cmd_calls = {},
	}

	helpers.clear_modules({
		"std",
		"cjson.safe",
		"redis",
		"shell.store",
	})

	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("cjson.safe", {
		encode = function(v)
			return "{}", nil
		end,
		decode = function(v)
			return {}
		end,
	})
	helpers.stub_module("redis", {
		connect = function(arg)
			state.connect_arg = arg
			return {
				cmd = function(self, cmd, ...)
					table.insert(state.cmd_calls, { cmd = cmd, args = { ... } })
					return 1
				end,
				close = function(self)
					state.close_count = state.close_count + 1
					return true
				end,
			}
		end,
	})

	local store_mod = helpers.load_module_from_src("shell.store", "src/shell/shell/store.lua")
	local store = store_mod.new({
		redis_url = "10.10.10.10:6379",
		key_prefix = "llsh:",
		key_suffix = ":user",
		storage_dir = "/tmp/lilush_test",
	})
	store:write("payload")
	local closed = store:close()

	testimony.assert_equal("10.10.10.10:6379", state.connect_arg)
	testimony.assert_equal("PUBLISH", state.cmd_calls[1].cmd)
	testimony.assert_equal("llsh:debug:user", state.cmd_calls[1].args[1])
	testimony.assert_equal("payload", state.cmd_calls[1].args[2])
	testimony.assert_equal(1, state.close_count)
	testimony.assert_equal(true, closed)
end)

testify:that("shell.store fallback keeps cmd/close contract when redis is down", function()
	helpers.clear_modules({
		"std",
		"cjson.safe",
		"redis",
		"shell.store",
	})

	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("cjson.safe", {
		encode = function(v)
			return "{}", nil
		end,
		decode = function(v)
			return {}
		end,
	})
	helpers.stub_module("redis", {
		connect = function()
			return nil, "redis down"
		end,
	})

	local store_mod = helpers.load_module_from_src("shell.store", "src/shell/shell/store.lua")
	local store = store_mod.new()
	local ok, err = store:save_vault_token("t", 30)
	testimony.assert_nil(ok)
	testimony.assert_equal("can't connect to redis: redis down", err)
	testimony.assert_equal(true, store:close())
end)

testify:that("shell.store falls back when redis client contract is invalid", function()
	helpers.clear_modules({
		"std",
		"cjson.safe",
		"redis",
		"shell.store",
	})

	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("cjson.safe", {
		encode = function(v)
			return "{}", nil
		end,
		decode = function(v)
			return {}
		end,
	})
	helpers.stub_module("redis", {
		connect = function()
			return {}
		end,
	})

	local store_mod = helpers.load_module_from_src("shell.store", "src/shell/shell/store.lua")
	local store = store_mod.new()
	local ok, err = store:save_vault_token("t", 30)
	testimony.assert_nil(ok)
	testimony.assert_equal("invalid redis client: missing cmd method", err)
	testimony.assert_equal(true, store:close())
end)

testify:that("reliw.store uses redis.connect(table) and close delegates to redis client", function()
	local state = {
		connect_arg = nil,
		close_count = 0,
		cmd_calls = {},
	}
	helpers.clear_modules({
		"std",
		"redis",
		"cjson.safe",
		"crypto",
		"reliw.store",
	})

	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("cjson.safe", {
		decode = function(v)
			return {}
		end,
		encode = function(v)
			return "{}", nil
		end,
	})
	helpers.stub_module("crypto", {
		sha256 = function(v)
			return "hash"
		end,
		bin_to_hex = function(v)
			return "deadbeef"
		end,
	})
	helpers.stub_module("redis", {
		connect = function(arg)
			state.connect_arg = arg
			return {
				cmd = function(self, cmd, ...)
					table.insert(state.cmd_calls, { cmd = cmd, args = { ... } })
					if cmd == "GET" then
						return "{}", nil
					end
					return 1
				end,
				close = function(self)
					state.close_count = state.close_count + 1
					return true
				end,
			}
		end,
	})

	local cfg = {
		redis = {
			host = "127.0.0.1",
			port = 6379,
			db = 13,
			prefix = "RLW",
		},
		data_dir = "/www",
		cache_max_size = 4096,
	}

	local store_mod = helpers.load_module_from_src("reliw.store", "src/reliw/reliw/store.lua")
	local store, err = store_mod.new(cfg)
	testimony.assert_not_nil(store, err)
	local proxy_cfg = store:fetch_proxy_config("example.com")
	testimony.assert_not_nil(proxy_cfg)
	store:close()

	testimony.assert_equal(cfg.redis, state.connect_arg)
	testimony.assert_equal("GET", state.cmd_calls[1].cmd)
	testimony.assert_equal("RLW:PROXY:example.com", state.cmd_calls[1].args[1])
	testimony.assert_equal(1, state.close_count)
end)

testify:that("reliw.store returns error on invalid redis client contract", function()
	helpers.clear_modules({
		"std",
		"redis",
		"cjson.safe",
		"crypto",
		"reliw.store",
	})

	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("cjson.safe", {
		decode = function(v)
			return {}
		end,
		encode = function(v)
			return "{}", nil
		end,
	})
	helpers.stub_module("crypto", {
		sha256 = function(v)
			return "hash"
		end,
		bin_to_hex = function(v)
			return "deadbeef"
		end,
	})
	helpers.stub_module("redis", {
		connect = function(arg)
			return {}
		end,
	})

	local cfg = {
		redis = {
			host = "127.0.0.1",
			port = 6379,
			db = 13,
			prefix = "RLW",
		},
		data_dir = "/www",
		cache_max_size = 4096,
	}

	local store_mod = helpers.load_module_from_src("reliw.store", "src/reliw/reliw/store.lua")
	local store, err = store_mod.new(cfg)
	testimony.assert_nil(store)
	testimony.assert_equal("invalid redis client: missing cmd method", err)
end)

testify:conclude()
