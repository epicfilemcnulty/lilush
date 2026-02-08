local testimony = require("testimony")
local helpers = require("tests.botls._helpers")

local testify = testimony.new("== botls orders ==")

local make_logger = function()
	return {
		lines = {},
		log = function(self, msg, level)
			table.insert(self.lines, { msg = msg, level = level })
		end,
	}
end

local make_client = function()
	return {
		new_order = function(self, domains)
			return {
				identifiers = {
					{ value = domains[1] },
				},
			}
		end,
		get_authorization = function(self, primary_domain, domain)
			return { status = "pending" }
		end,
		solve_challenge = function(self)
			return true
		end,
		mark_challenge_as_ready = function(self)
			return true
		end,
		cleanup_provision = function(self)
			return true
		end,
		finalize = function(self)
			return true
		end,
		fetch_certificate = function(self)
			return true
		end,
		cleanup = function(self)
			return true
		end,
	}
end

testify:that("order lifecycle transitions update manager state", function()
	helpers.clear_modules({ "botls.manager", "botls.orders", "botls.providers", "botls.scheduler" })
	helpers.load_module_from_src("botls.providers", "src/botls/botls/providers.lua")
	helpers.load_module_from_src("botls.orders", "src/botls/botls/orders.lua")
	helpers.load_module_from_src("botls.scheduler", "src/botls/botls/scheduler.lua")
	local manager_mod = helpers.load_module_from_src("botls.manager", "src/botls/botls/manager.lua")
	local logger = make_logger()
	local manager = manager_mod.new({
		account = "ops@example.com",
		certificates = {
			{ names = { "example.com" }, provider = "dns.vultr" },
		},
		providers = {
			["dns.vultr"] = { token = "x" },
		},
		renew_time = 2592000,
		data_dir = "/tmp",
	}, {
		logger = logger,
		client = make_client(),
		sleep = function() end,
		random = function(min)
			return min
		end,
	})

	local ok = manager:place_order({ "example.com" })
	testimony.assert_true(ok)
	testimony.assert_equal("new", manager.__state.orders["example.com"].challenges["example.com"])

	testimony.assert_true(manager:solve_challenge("example.com"))
	testimony.assert_equal("solved", manager.__state.orders["example.com"].challenges["example.com"])

	testimony.assert_true(manager:mark_challenge_as_ready("example.com"))
	testimony.assert_equal("marked", manager.__state.orders["example.com"].challenges["example.com"])

	testimony.assert_true(manager:cleanup_challenge("example.com"))
	testimony.assert_equal("validated", manager.__state.orders["example.com"].challenges["example.com"])

	testimony.assert_true(manager:send_csr("example.com"))
	testimony.assert_true(manager.__state.orders["example.com"].csr_sent)

	testimony.assert_true(manager:get_certificate("example.com"))
	testimony.assert_nil(manager.__state.orders["example.com"])
end)

testify:conclude()
