-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local client = require("acme.client")

local LE_PROD_DIR = "https://acme-v02.api.letsencrypt.org/directory"
local LE_STAGE_DIR = "https://acme-staging-v02.api.letsencrypt.org/directory"

local new = function(cfg)
	return client.new(cfg)
end

local le_prod = function(cfg)
	cfg = cfg or {}
	cfg.directory_url = LE_PROD_DIR
	return client.new(cfg)
end

local le_stage = function(cfg)
	cfg = cfg or {}
	cfg.directory_url = LE_STAGE_DIR
	return client.new(cfg)
end

return {
	new = new,
	le_prod = le_prod,
	le_stage = le_stage,
}
