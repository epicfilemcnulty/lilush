local testimony = require("testimony")
local helpers = require("tests.botls._helpers")

local testify = testimony.new("== botls scheduler ==")

local make_logger = function()
	return {
		lines = {},
		log = function(self, msg, level)
			table.insert(self.lines, { msg = msg, level = level })
		end,
	}
end

local make_manager = function(meta_by_domain, now)
	helpers.clear_modules({ "botls.scheduler" })
	local scheduler = helpers.load_module_from_src("botls.scheduler", "src/botls/botls/scheduler.lua")
	local logger = make_logger()
	return {
		cfg = {
			certificates = {
				{ names = { "present.example.com" } },
				{ names = { "missing.example.com" } },
			},
			renew_time = 100,
		},
		client = {
			get_certificate_meta = function(self, domain)
				local out = meta_by_domain[domain]
				if out == nil then
					return nil, "not found"
				end
				return out
			end,
		},
		logger = logger,
		__deps = {
			time = function()
				return now
			end,
			random = function(min)
				return min
			end,
		},
		get_certs_expire_time = scheduler.get_certs_expire_time,
		all_certs_present = scheduler.all_certs_present,
		next_sleep_duration = scheduler.next_sleep_duration,
	},
		logger
end

testify:that("get_certs_expire_time uses store metadata", function()
	local manager = make_manager({
		["present.example.com"] = {
			exists = true,
			not_after_ts = 2000,
			cert_path = "/x/present.crt",
		},
		["missing.example.com"] = {
			exists = false,
			cert_path = "/x/missing.crt",
		},
	}, 1000)

	local min_expire_time = manager:get_certs_expire_time()
	testimony.assert_equal(1000, min_expire_time)
	testimony.assert_equal(2000, manager.cfg.certificates[1].expires_at)
	testimony.assert_equal(-1, manager.cfg.certificates[2].expires_at)
	testimony.assert_nil(manager:all_certs_present())
end)

testify:that("get_certs_expire_time logs metadata load errors", function()
	local manager, logger = make_manager({
		["present.example.com"] = {
			exists = true,
			not_after_ts = 3000,
			cert_path = "/x/present.crt",
		},
	}, 1000)

	manager:get_certs_expire_time()
	testimony.assert_true(#logger.lines >= 2)
	testimony.assert_equal("failed to load certificate metadata", logger.lines[2].msg.msg)
	testimony.assert_equal("error", logger.lines[2].level)
end)

testify:conclude()
