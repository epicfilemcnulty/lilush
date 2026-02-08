-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local storage = require("reliw.store")

local provision = function(self, domain, token, key_thumbprint)
	if not domain or type(domain) ~= "string" then
		return nil, "domain name must be provided and must be a string"
	end
	if domain:match("%*") then
		return nil, "wildcards can't be verified by http challenge"
	end
	local txt_value = token .. "." .. key_thumbprint
	local _, err = self.__state.store:provision_acme_challenge(domain, token, txt_value)
	if err then
		return nil, err
	end
	return { provider = "http.reliw", domain = domain, token = token }
end

local cleanup = function(self, provision_state)
	if not provision_state or not provision_state.domain or not provision_state.token then
		return nil, "invalid provision state"
	end
	return self.__state.store:cleanup_acme_challenge(provision_state.domain, provision_state.token)
end

local new = function(cfg)
	local store, err = storage.new(cfg)
	if not store then
		return nil, err
	end
	return {
		cfg = cfg,
		__state = {
			store = store,
		},
		provision = provision,
		cleanup = cleanup,
	}
end

return {
	new = new,
}
