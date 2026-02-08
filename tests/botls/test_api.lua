local testimony = require("testimony")
local helpers = require("tests.botls._helpers")

local testify = testimony.new("== botls api ==")

local make_logger = function()
	return {
		lines = {},
		log = function(self, msg, level)
			table.insert(self.lines, { msg = msg, level = level })
		end,
	}
end

testify:that("botls.new validates cfg", function()
	helpers.clear_modules({
		"botls",
		"botls.config",
		"botls.manager",
		"botls.orders",
		"botls.providers",
		"botls.scheduler",
	})
	helpers.load_module_from_src("botls.config", "src/botls/botls/config.lua")
	helpers.load_module_from_src("botls.providers", "src/botls/botls/providers.lua")
	helpers.load_module_from_src("botls.orders", "src/botls/botls/orders.lua")
	helpers.load_module_from_src("botls.scheduler", "src/botls/botls/scheduler.lua")
	helpers.load_module_from_src("botls.manager", "src/botls/botls/manager.lua")
	local botls = helpers.load_module_from_src("botls", "src/botls/botls.lua")
	local bot, err = botls.new(nil)
	testimony.assert_nil(bot)
	testimony.assert_match("cfg must be a table", err)
end)

testify:that("botls.new returns manager with normalized cfg", function()
	helpers.clear_modules({
		"botls",
		"botls.config",
		"botls.manager",
		"botls.orders",
		"botls.providers",
		"botls.scheduler",
	})
	helpers.load_module_from_src("botls.config", "src/botls/botls/config.lua")
	helpers.load_module_from_src("botls.providers", "src/botls/botls/providers.lua")
	helpers.load_module_from_src("botls.orders", "src/botls/botls/orders.lua")
	helpers.load_module_from_src("botls.scheduler", "src/botls/botls/scheduler.lua")
	helpers.load_module_from_src("botls.manager", "src/botls/botls/manager.lua")
	local botls = helpers.load_module_from_src("botls", "src/botls/botls.lua")
	local fake_client = {}
	local logger = make_logger()
	local bot, err = botls.new({ account = "ops@example.com", certificates = {} }, {
		client = fake_client,
		logger = logger,
		sleep = function() end,
		random = function(min)
			return min
		end,
	})
	testimony.assert_nil(err)
	testimony.assert_true(type(bot) == "table")
	testimony.assert_equal(".acme", bot.cfg.data_dir)
	testimony.assert_equal(2592000, bot.cfg.renew_time)
	testimony.assert_equal(fake_client, bot.client)
end)

testify:conclude()
