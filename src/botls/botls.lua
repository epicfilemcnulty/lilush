-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local acme = require("acme")
local config_mod = require("botls.config")
local manager = require("botls.manager")

local build_client = function(cfg)
	local client, err = acme.le_prod({
		account_email = cfg.account,
		storage = {
			plugin = "file",
			storage_dir = cfg.data_dir,
		},
	})
	if not client then
		return nil, "failed to create ACME client: " .. tostring(err)
	end
	local ok, init_err = client:init()
	if not ok then
		return nil, "failed to initialize ACME client: " .. tostring(init_err)
	end
	return client
end

local new = function(cfg, opts)
	opts = opts or {}
	if not cfg or type(cfg) ~= "table" then
		return nil, "cfg must be a table"
	end
	cfg = config_mod.normalize(cfg)

	local logger = opts.logger or std.logger.new(os.getenv("BOTLS_LOG_LEVEL") or "debug")
	local client = opts.client
	if not client then
		local err
		client, err = build_client(cfg)
		if not client then
			return nil, err
		end
	end

	return manager.new(cfg, {
		logger = logger,
		client = client,
		time = opts.time,
		sleep = opts.sleep,
		random = opts.random,
	})
end

local new_from_env = function(opts)
	local cfg, err = config_mod.from_env()
	if not cfg then
		return nil, err
	end
	return new(cfg, opts)
end

return {
	new = new,
	new_from_env = new_from_env,
}
