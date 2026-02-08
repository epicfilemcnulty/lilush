-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local crypto = require("crypto")
local web = require("web")
local json = require("cjson.safe")

local get_domain_parts = function(domain)
	local base_domain = domain:match("([^.]+%.[^.]+)$") or domain
	local sub_domain = ""
	local dots = 0
	for _ in domain:gmatch("%.") do
		dots = dots + 1
	end

	if dots == 1 then
		base_domain = domain
	elseif dots > 1 then
		local prefix = domain:match("^(.+)%." .. base_domain:gsub("%.", "%%.") .. "$")
		if prefix and not prefix:match("%*") then
			sub_domain = "." .. prefix
		end
	end
	return base_domain, sub_domain
end

local provision = function(self, domain, token, key_thumbprint)
	local base_domain, sub_domain = get_domain_parts(domain)
	local api_endpoint = "https://api.vultr.com/v2/domains/" .. base_domain .. "/records"
	local txt_value = crypto.b64url_encode(crypto.sha256(token .. "." .. key_thumbprint))
	local vultr_payload = {
		type = "TXT",
		ttl = 60,
		name = "_acme-challenge" .. sub_domain,
		data = txt_value,
	}
	local resp, err = web.request(api_endpoint, {
		method = "POST",
		headers = self.__state.headers,
		body = json.encode(vultr_payload),
	})
	if resp and (resp.status == 200 or resp.status == 201) then
		local info, decode_err = json.decode(resp.body)
		if not info then
			return nil, decode_err
		end
		return {
			provider = "vultr",
			domain = base_domain,
			record_id = info.record.id,
		}
	end
	return nil, err or (resp and "HTTP " .. tostring(resp.status)) or "request failed"
end

local cleanup = function(self, provision_state)
	local api_endpoint = "https://api.vultr.com/v2/domains/"
		.. provision_state.domain
		.. "/records/"
		.. provision_state.record_id
	local resp, err = web.request(api_endpoint, { method = "DELETE", headers = self.__state.headers })
	if resp and resp.status == 204 then
		return true
	end
	return nil, err or (resp and "HTTP " .. tostring(resp.status)) or "request failed"
end

local new = function(cfg)
	if not cfg or not cfg.token then
		return nil, "token is required"
	end
	return {
		cfg = cfg,
		__state = {
			headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = "Bearer " .. cfg.token,
			},
		},
		provision = provision,
		cleanup = cleanup,
	}
end

return {
	new = new,
}
