-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.reliw._helpers")

local testify = testimony.new("== reliw.store metrics scan ==")

local state = {}

local reset_state = function()
	state = {
		calls = {},
		close_count = 0,
		scan = {},
		hgetall = {},
	}
end

helpers.clear_modules({
	"std",
	"redis",
	"cjson.safe",
	"crypto",
	"reliw.store",
})

helpers.stub_module("std", {})
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
				if cmd == "SCAN" then
					local cursor = tostring(args[1])
					local resp = state.scan[cursor]
					if not resp then
						return { "0", {} }
					end
					return { tostring(resp[1]), resp[2] }
				end
				if cmd == "HGETALL" then
					return state.hgetall[args[1]]
				end
				return nil, "unexpected command: " .. tostring(cmd)
			end,
			close = function(self)
				state.close_count = state.close_count + 1
			end,
		}
	end,
})

local store_mod = helpers.load_module_from_src("reliw.store", "src/reliw/reliw/store.lua")

local new_store = function(metrics_cfg)
	local store, err = store_mod.new({
		redis = {
			host = "127.0.0.1",
			port = 6379,
			db = 13,
			prefix = "RLW",
		},
		data_dir = "/www",
		cache_max_size = 1024,
		metrics = metrics_cfg or {},
	})
	testimony.assert_not_nil(store, err)
	return store
end

testify:that("uses SCAN and preserves metrics output format", function()
	reset_state()
	state.scan["0"] = {
		"10",
		{
			"RLW:METRICS:bb.test:total",
		},
	}
	state.scan["10"] = {
		"0",
		{
			"RLW:METRICS:aa.test:total",
		},
	}
	state.hgetall["RLW:METRICS:aa.test:total"] = { "200", "5" }
	state.hgetall["RLW:METRICS:aa.test:by_method"] = { "GET", "4", "POST", "1" }
	state.hgetall["RLW:METRICS:bb.test:total"] = { "404", "2" }
	state.hgetall["RLW:METRICS:bb.test:by_method"] = { "GET", "2" }

	local store = new_store()
	local payload = store:fetch_metrics()

	testimony.assert_match("# TYPE http_requests_total counter", payload)
	testimony.assert_match("# TYPE http_requests_by_method counter", payload)
	testimony.assert_match([[http_requests_total{host="aa.test",code="200"} 5]], payload)
	testimony.assert_match([[http_requests_total{host="bb.test",code="404"} 2]], payload)
	testimony.assert_match([[http_requests_by_method{host="aa.test",method="GET"} 4]], payload)
	testimony.assert_match([[http_requests_by_method{host="aa.test",method="POST"} 1]], payload)
	testimony.assert_match([[http_requests_by_method{host="bb.test",method="GET"} 2]], payload)

	local saw_keys = false
	local scan_calls = 0
	for _, call in ipairs(state.calls) do
		if call.cmd == "KEYS" then
			saw_keys = true
		end
		if call.cmd == "SCAN" then
			scan_calls = scan_calls + 1
			testimony.assert_equal("RLW:METRICS:*:total", call.args[3])
			testimony.assert_equal("COUNT", call.args[4])
			testimony.assert_equal("100", call.args[5])
		end
	end
	testimony.assert_equal(false, saw_keys)
	testimony.assert_equal(2, scan_calls)
end)

testify:that("applies scan limit and count bounds from config", function()
	reset_state()
	state.scan["0"] = {
		"0",
		{
			"RLW:METRICS:first.test:total",
			"RLW:METRICS:second.test:total",
		},
	}
	state.hgetall["RLW:METRICS:first.test:total"] = { "200", "9" }
	state.hgetall["RLW:METRICS:first.test:by_method"] = { "GET", "9" }
	state.hgetall["RLW:METRICS:second.test:total"] = { "200", "11" }
	state.hgetall["RLW:METRICS:second.test:by_method"] = { "GET", "11" }

	local store = new_store({
		scan_count = 99999,
		scan_limit = 0,
	})
	local payload = store:fetch_metrics()

	testimony.assert_match([[http_requests_total{host="first.test",code="200"} 9]], payload)
	testimony.assert_match([[http_requests_by_method{host="first.test",method="GET"} 9]], payload)
	testimony.assert_equal(nil, payload:match([[host="second%.test"]]))

	local scan_call = state.calls[1]
	testimony.assert_equal("SCAN", scan_call.cmd)
	testimony.assert_equal("1000", scan_call.args[5])
end)

testify:conclude()
