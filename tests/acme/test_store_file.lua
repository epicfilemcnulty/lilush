local testimony = require("testimony")
local helpers = require("tests.acme._helpers")

local testify = testimony.new("== acme.store.file ==")

testify:that("store constructor validates account_email", function()
	helpers.clear_modules({ "acme.store.file" })
	local store_mod = helpers.load_module_from_src("acme.store.file", "src/acme/acme/store/file.lua")
	local store, err = store_mod.new({})
	testimony.assert_nil(store)
	testimony.assert_match("account_email", err)
end)

testify:that("store saves and loads order info", function()
	helpers.clear_modules({ "acme.store.file" })
	local store_mod = helpers.load_module_from_src("acme.store.file", "src/acme/acme/store/file.lua")
	local tmp = "/tmp/lilush_acme_store_test_" .. tostring(os.time())
	local store, err = store_mod.new({ account_email = "ops@example.com", storage_dir = tmp })
	testimony.assert_nil(err)
	testimony.assert_true(type(store) == "table")

	local order_info = { status = "pending", identifiers = { { type = "dns", value = "example.com" } } }
	local ok, save_err = store:save_order_info("example.com", order_info)
	testimony.assert_true(ok)
	testimony.assert_nil(save_err)

	local loaded, load_err = store:load_order_info("example.com")
	testimony.assert_nil(load_err)
	testimony.assert_equal("pending", loaded.status)
	testimony.assert_equal("example.com", loaded.identifiers[1].value)
end)

testify:that("store certificate metadata reports missing certificate", function()
	helpers.clear_modules({ "acme.store.file" })
	local store_mod = helpers.load_module_from_src("acme.store.file", "src/acme/acme/store/file.lua")
	local tmp = "/tmp/lilush_acme_store_test_meta_" .. tostring(os.time())
	local store, err = store_mod.new({ account_email = "ops@example.com", storage_dir = tmp })
	testimony.assert_nil(err)
	testimony.assert_true(type(store) == "table")

	local meta, meta_err = store:get_certificate_meta("missing.example.com")
	testimony.assert_nil(meta_err)
	testimony.assert_false(meta.exists)
	testimony.assert_match("missing%.example%.com%.crt$", meta.cert_path)
end)

testify:conclude()
