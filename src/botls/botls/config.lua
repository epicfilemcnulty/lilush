-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local json = require("cjson.safe")

local normalize = function(cfg)
	cfg = cfg or {}
	cfg.data_dir = cfg.data_dir or ".acme"
	cfg.providers = cfg.providers or {}
	cfg.renew_time = cfg.renew_time or 2592000
	return cfg
end

local load_file = function(path)
	local config_json, err = std.fs.read_file(path)
	if err then
		return nil, "failed to read config file: " .. tostring(err)
	end
	local config, decode_err = json.decode(config_json)
	if not config then
		return nil, "failed to decode config: " .. tostring(decode_err)
	end
	return normalize(config)
end

local from_env = function()
	local config_file = os.getenv("BOTLS_CONFIG_FILE") or "/etc/botls/config.json"
	return load_file(config_file)
end

return {
	normalize = normalize,
	load_file = load_file,
	from_env = from_env,
}
