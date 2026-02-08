-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local crypto = require("crypto")
local std = require("std")
local transport = require("acme.transport")
local jws = require("acme.jws")
local orders = require("acme.orders")
local providers = require("acme.providers")

local response_err = function(resp, err)
	if err then
		return err
	end
	if resp then
		return "HTTP " .. tostring(resp.status)
	end
	return "request failed"
end

local refresh_nonce = function(self)
	local resp, err = transport.request(self, self.cfg.directory.newNonce, { method = "HEAD" })
	if not resp or resp.status ~= 200 then
		return nil, response_err(resp, err)
	end
	return true
end

local load_key = function(self)
	local account_key, err = self.store:load_account_key()
	if not account_key then
		return nil, err
	end
	self.__state.key = account_key
	self.__state.kid = account_key.kid
	return true
end

local register_account = function(self)
	local payload = {
		termsOfServiceAgreed = true,
		contact = { "mailto:" .. self.cfg.account_email },
	}
	local resp, err = transport.request_jws(self, self.cfg.directory.newAccount, payload, true)
	if resp and (resp.status == 201 or resp.status == 200) then
		self.__state.kid = resp.headers.location
		self.__state.key.kid = resp.headers.location
		local ok, save_err = self.store:save_account_key(self.__state.key)
		if not ok then
			return nil, "failed to save account key: " .. tostring(save_err)
		end
		return transport.decode_json_body(resp)
	end
	return nil, response_err(resp, err)
end

local init = function(self)
	local ok, err = self:refresh_nonce()
	if not ok then
		return nil, err
	end
	ok, err = self:load_key()
	if not ok then
		return nil, err
	end
	return self:register_account()
end

local new_order = function(self, domains)
	local payload = { identifiers = {} }
	local primary_domain = domains[1]
	for _, domain in ipairs(domains) do
		table.insert(payload.identifiers, { type = "dns", value = domain })
	end
	local resp, err = transport.request_jws(self, self.cfg.directory.newOrder, payload)
	if resp and (resp.status == 201 or resp.status == 200) then
		local order_info, decode_err = transport.decode_json_body(resp)
		if not order_info then
			return nil, decode_err
		end
		orders.set_order_info(self, primary_domain, resp.headers.location, order_info)
		return order_info
	end
	return nil, response_err(resp, err)
end

local order_info = function(self, primary_domain, order_url)
	local target_url = order_url or orders.get_order_url(self, primary_domain)
	if not target_url then
		return nil, "order_url not found nor provided"
	end
	local resp, err = transport.request_jws(self, target_url)
	if resp and (resp.status == 201 or resp.status == 200) then
		local order, decode_err = transport.decode_json_body(resp)
		if not order then
			return nil, decode_err
		end
		orders.set_order_info(self, primary_domain, target_url, order)
		return order
	end
	return nil, response_err(resp, err)
end

local get_authorization = function(self, primary_domain, domain)
	local order = orders.get_order_info(self, primary_domain)
	if not order then
		return nil, "order not found"
	end
	local idx = nil
	for i, identifier in ipairs(order.identifiers or {}) do
		if identifier.value == domain then
			idx = i
			break
		end
	end
	if not idx then
		return nil, "subdomain not found"
	end
	local authorization_url = order.authorizations[idx]
	local resp, err = transport.request_jws(self, authorization_url)
	if resp and (resp.status == 201 or resp.status == 200) then
		return transport.decode_json_body(resp)
	end
	return nil, response_err(resp, err)
end

local get_auth_by_url = function(self, url)
	local resp, err = transport.request_jws(self, url)
	if resp and (resp.status == 201 or resp.status == 200) then
		return transport.decode_json_body(resp)
	end
	return nil, response_err(resp, err)
end

local solve_challenge = function(self, primary_domain, domain, provider_name, provider_cfg)
	local solver, err = providers.load_challenge_provider(provider_name, provider_cfg)
	if not solver then
		return nil, err
	end
	local mode = provider_name:match("^(%w+)%.")
	local auth, auth_err = self:get_authorization(primary_domain, domain)
	if not auth then
		return nil, auth_err
	end

	local challenge_url = nil
	local token = nil
	for _, challenge in ipairs(auth.challenges or {}) do
		if challenge.type == mode .. "-01" then
			challenge_url = challenge.url
			token = challenge.token
			break
		end
	end
	if not challenge_url then
		return nil, "can't get challenge info"
	end
	local provision_state, provision_err = solver:provision(domain, token, self:key_thumbprint())
	if not provision_state then
		return nil, provision_err
	end
	orders.set_challenge_url(self, primary_domain, domain, challenge_url)
	return self.store:save_order_provision(primary_domain, domain, provision_state)
end

local mark_challenge_as_ready = function(self, primary_domain, domain)
	local challenge_url = orders.get_challenge_url(self, primary_domain, domain)
	if not challenge_url then
		return nil, "challenge_url not found"
	end
	local resp, err = transport.request_jws(self, challenge_url, {})
	if resp and (resp.status == 201 or resp.status == 200) then
		return true
	end
	return nil, response_err(resp, err)
end

local cleanup_provision = function(self, primary_domain, domain, provider_name, provider_cfg)
	local provision_state, err = self.store:load_order_provision(primary_domain, domain)
	if not provision_state then
		return nil, err
	end
	local solver, solver_err = providers.load_challenge_provider(provider_name, provider_cfg)
	if not solver then
		return nil, solver_err
	end
	local ok, cleanup_err = solver:cleanup(provision_state)
	if not ok then
		return nil, cleanup_err
	end
	self.store:delete_order_provision(primary_domain, domain)
	return true
end

local cleanup = function(self, primary_domain, purge)
	if purge then
		self.store:delete_order_info(primary_domain)
	end
	orders.clear_order(self, primary_domain)
	return true
end

local finalize = function(self, primary_domain)
	local order = orders.get_order_info(self, primary_domain)
	if not order then
		return nil, "order not found"
	end

	local cert_key = self.store:load_cert_key(primary_domain)
	if not cert_key then
		cert_key = crypto.ecc_generate_key()
		self.store:save_cert_key(primary_domain, cert_key)
	end

	local alt_names = {}
	for _, identifier in ipairs(order.identifiers or {}) do
		if identifier.value ~= primary_domain then
			table.insert(alt_names, identifier.value)
		end
	end
	local csr =
		crypto.generate_csr(cert_key.private, cert_key.public, primary_domain, #alt_names > 0 and alt_names or nil)

	local resp, err = transport.request_jws(self, order.finalize, { csr = crypto.b64url_encode(csr) })
	if resp and (resp.status == 201 or resp.status == 200) then
		return transport.decode_json_body(resp)
	end
	return nil, response_err(resp, err)
end

local fetch_certificate = function(self, primary_domain)
	local order = orders.get_order_info(self, primary_domain)
	if not order or not order.certificate then
		return nil, "certificate is not ready"
	end
	local resp, err =
		transport.request_jws(self, order.certificate, nil, nil, { ["Accept"] = "application/pem-certificate-chain" })
	if resp and resp.status == 200 then
		self.store:save_certificate(primary_domain, resp.body)
		return resp.body
	end
	return nil, response_err(resp, err)
end

local get_certificate_meta = function(self, primary_domain)
	if not self.store.get_certificate_meta then
		return nil, "storage provider does not support get_certificate_meta"
	end
	return self.store:get_certificate_meta(primary_domain)
end

local new = function(cfg)
	if not cfg or type(cfg) ~= "table" then
		return nil, "cfg must be a table"
	end
	if not cfg.account_email or not cfg.account_email:match("[^@+]@[^.]+%..*") then
		return nil, "you must provide a valid email as account_email"
	end
	if not cfg.directory_url then
		return nil, "you must provide directory_url"
	end

	local resp, err = transport.request({ __state = {} }, cfg.directory_url)
	if not resp or resp.status ~= 200 then
		return nil, response_err(resp, err)
	end
	local directory, decode_err = transport.decode_json_body(resp)
	if not directory then
		return nil, decode_err
	end

	local merged_cfg = std.tbl.copy(cfg)
	merged_cfg.directory = directory
	local store, store_err = providers.load_storage(merged_cfg)
	if not store then
		return nil, "failed to initialize storage provider: " .. tostring(store_err)
	end

	local client = {
		cfg = merged_cfg,
		__state = {
			nonce = "",
			kid = nil,
			key = nil,
			orders = {},
		},
		store = store,
		generate_header = jws.generate_header,
		sign_jws = jws.sign_jws,
		acme_frame = jws.frame,
		key_thumbprint = jws.key_thumbprint,
		refresh_nonce = refresh_nonce,
		load_key = load_key,
		register_account = register_account,
		init = init,
		new_order = new_order,
		order_info = order_info,
		get_authorization = get_authorization,
		get_auth_by_url = get_auth_by_url,
		solve_challenge = solve_challenge,
		mark_challenge_as_ready = mark_challenge_as_ready,
		cleanup_provision = cleanup_provision,
		cleanup = cleanup,
		finalize = finalize,
		fetch_certificate = fetch_certificate,
		get_certificate_meta = get_certificate_meta,
	}

	return client
end

return {
	new = new,
}
