local testimony = require("testimony")
local helpers = require("tests.acme._helpers")

local testify = testimony.new("== acme api ==")

testify:that("le_prod and le_stage inject directory URL", function()
	helpers.clear_modules({ "acme", "acme.client" })
	helpers.stub_module("acme.client", {
		new = function(cfg)
			return { cfg = cfg }
		end,
	})

	local acme = helpers.load_module_from_src("acme", "src/acme/acme.lua")
	local prod = acme.le_prod({ account_email = "ops@example.com" })
	local stage = acme.le_stage({ account_email = "ops@example.com" })

	testimony.assert_equal("https://acme-v02.api.letsencrypt.org/directory", prod.cfg.directory_url)
	testimony.assert_equal("https://acme-staging-v02.api.letsencrypt.org/directory", stage.cfg.directory_url)
end)

testify:that("new delegates cfg to acme.client.new", function()
	helpers.clear_modules({ "acme", "acme.client" })
	local called_cfg = nil
	helpers.stub_module("acme.client", {
		new = function(cfg)
			called_cfg = cfg
			return { ok = true }
		end,
	})

	local acme = helpers.load_module_from_src("acme", "src/acme/acme.lua")
	local cfg = { account_email = "ops@example.com", directory_url = "https://example.test/acme" }
	local client = acme.new(cfg)

	testimony.assert_true(client.ok)
	testimony.assert_equal(cfg, called_cfg)
end)

testify:conclude()
