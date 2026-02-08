-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local load_storage = function(cfg)
	local storage_cfg = cfg.storage or { plugin = "file" }
	storage_cfg.plugin = storage_cfg.plugin or "file"
	local mod_name = "acme.store." .. storage_cfg.plugin
	if not std.module_available(mod_name) then
		return nil, "no such storage plugin found: " .. storage_cfg.plugin
	end
	local storage_mod = require(mod_name)
	return storage_mod.new({
		account_email = cfg.account_email,
		storage_dir = storage_cfg.storage_dir,
		plugin = storage_cfg.plugin,
	})
end

local load_challenge_provider = function(provider_name, cfg)
	if not cfg or type(cfg) ~= "table" or not provider_name then
		return nil, "provider config missing"
	end

	local mode = provider_name:match("^(%w+)%.") or ""
	if mode ~= "dns" and mode ~= "http" then
		return nil, "invalid provider name: " .. mode
	end

	local mod_name = "acme." .. provider_name
	if not std.module_available(mod_name) then
		return nil, "no provider plugin for " .. provider_name .. " found"
	end

	local provider = require(mod_name)
	local solver, err = provider.new(cfg)
	if err then
		return nil, "failed to init challenge solver: " .. err
	end
	return solver
end

return {
	load_storage = load_storage,
	load_challenge_provider = load_challenge_provider,
}
