local crypto = require("crypto")
local std = require("std")
local web = require("web")
local json = require("cjson.safe")

--[[
    Section 6.1 of RFC8555 says:

      "ACME clients MUST send a User-Agent header field, in accordance with
       [RFC7231].  This header field SHOULD include the name and version of
       the ACME software in addition to the name and version of the
       underlying HTTP client software."
]]
local common_headers = {
	["Content-Type"] = "application/jose+json",
	["User-Agent"] = "RELIW-ACME-CLIENT/0.5",
}

local generate_header = function(self, url, jwk)
	local header = {
		alg = "ES256",
		nonce = self.__nonce,
		url = url,
	}
	if jwk then
		header.jwk = {
			kty = "EC",
			crv = "P-256",
			x = crypto.b64url_encode(self.__key.x),
			y = crypto.b64url_encode(self.__key.y),
		}
	else
		header.kid = self.__kid
	end
	return header
end

-- For ACME Key authorization (RFC8555, section 8.1)
-- we need to provide a token concatenated with the
-- thumbprint (RFC7638) of the account's public key.
local key_thumbprint = function(self)
	local canonical = string.format(
		'{"crv":"P-256","kty":"EC","x":"%s","y":"%s"}',
		crypto.b64url_encode(self.__key.x),
		crypto.b64url_encode(self.__key.y)
	)
	local sha = crypto.sha256(canonical)
	local thumbprint = crypto.b64url_encode(sha)
	return thumbprint
end

local sign_jws = function(self, encoded_header, encoded_payload)
	local signing_input = encoded_header .. "." .. encoded_payload
	local signature = crypto.ecc_sign(self.__key.private, self.__key.public, signing_input)
	return crypto.b64url_encode(signature)
end

local acme_frame = function(self, url, payload, jwk)
	local enc_header = crypto.b64url_encode_json(self:generate_header(url, jwk))
	local enc_payload = ""
	if payload then
		enc_payload = crypto.b64url_encode_json(payload)
	end
	return {
		protected = enc_header,
		payload = enc_payload,
		signature = self:sign_jws(enc_header, enc_payload),
	}
end

local refresh_nonce = function(self)
	local resp, err = web.request(self.__dir.newNonce, { method = "HEAD" })
	if not resp or resp.status ~= 200 then
		return nil, "failed to refresh nonce"
	end
	self.__nonce = resp.headers["replay-nonce"]
	return true
end

local load_key = function(self)
	local account_key, err = self.store:load_account_key()
	if err then
		return nil, err
	end
	self.__key = account_key
	self.__kid = account_key.kid
	return true
end

local register_account = function(self)
	local payload = {
		termsOfServiceAgreed = true,
		contact = { "mailto:" .. self.__email },
	}
	local jws = self:acme_frame(self.__dir.newAccount, payload, true)
	local resp, err =
		web.request(self.__dir.newAccount, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			self.__kid = resp.headers.location
			self.__key.kid = resp.headers.location
			local ok, err = self.store:save_account_key(self.__key)
			if not ok then
				return nil, "failed to save account key: " .. err
			end
			return json.decode(resp.body)
		end
	end
	return nil, resp, err
end

local new_order = function(self, domains)
	local payload = {
		identifiers = {},
	}
	local primary_domain = domains[1]
	for _, domain in ipairs(domains) do
		table.insert(payload.identifiers, { type = "dns", value = domain })
	end
	local jws = self:acme_frame(self.__dir.newOrder, payload)
	local resp, err =
		web.request(self.__dir.newOrder, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			local order_url = resp.headers.location
			local order = json.decode(resp.body)
			self.orders[primary_domain] = { info = order, url = order_url, challenges = {} }
			self.store:save_order_info(primary_domain, order)
			return order
		end
	end
	return nil, resp, err
end

local order_info = function(self, primary_domain, order_url)
	local order_url = order_url or self.orders[primary_domain].url
	if not order_url then
		return nil, "order_url not found nor provided"
	end
	local jws = self:acme_frame(order_url)
	local resp, err = web.request(order_url, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			local order = json.decode(resp.body)
			if not self.orders[primary_domain] then
				self.orders[primary_domain] = { url = order_url, challenges = {} }
			end
			self.orders[primary_domain].info = order
			self.store:save_order_info(primary_domain, order)
			return order
		end
	end
	return nil, resp, err
end

local get_authorization = function(self, primary_domain, domain)
	local idx = 1
	for i, identifier in ipairs(self.orders[primary_domain].info.identifiers) do
		if identifier.value == domain then
			idx = i
			break
		end
	end
	if domain ~= self.orders[primary_domain].info.identifiers[idx].value then
		return nil, "subdomain not found"
	end
	local authorization_url = self.orders[primary_domain].info.authorizations[idx]
	local jws = self:acme_frame(authorization_url)
	local resp, err =
		web.request(authorization_url, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			local authorization_info, err = json.decode(resp.body)
			if err then
				return nil, err
			end
			return authorization_info
		end
	end
	return nil, resp, err
end

local get_auth_by_url = function(self, url)
	local jws = self:acme_frame(url)
	local resp, err = web.request(url, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			local authorization_info, err = json.decode(resp.body)
			if err then
				return nil, err
			end
			return authorization_info
		end
	end
	return nil, resp, err
end

local solve_dns_challenge = function(self, primary_domain, domain, dns_cfg)
	local dns_cfg = dns_cfg or {}
	local dns_provider = dns_cfg.name or "unknown"
	if not std.module_available("acme.dns." .. dns_provider) then
		return nil, "no DNS plugin for " .. dns_provider .. " found"
	end
	local provider = require("acme.dns." .. dns_provider)
	local dns = provider.new(dns_cfg)
	local auth = self:get_authorization(primary_domain, domain)
	local url, token
	for _, challenge in ipairs(auth.challenges) do
		if challenge.type == "dns-01" then
			token = challenge.token
			url = challenge.url
			break
		end
	end
	if not domain or not token then
		return nil, "can't get challenge info"
	end
	local provision_state, err = dns:provision(domain, token .. "." .. self:key_thumbprint())
	if err then
		return nil, err
	end
	self.orders[primary_domain].challenges[domain] = url
	return self.store:save_order_provision(primary_domain, domain, provision_state)
end

local mark_challenge_as_ready = function(self, primary_domain, domain)
	local challenge_url = self.orders[primary_domain].challenges[domain]
	local jws = self:acme_frame(challenge_url, {})
	local resp, err = web.request(challenge_url, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			return true
		end
	end
	return nil, resp, err
end

local cleanup_dns = function(self, primary_domain, domain, dns_cfg)
	local provision_state, err = self.store:load_order_provision(primary_domain, domain)
	if provision_state then
		local provider = require("acme.dns." .. provision_state.provider)
		local dns = provider.new(dns_cfg)
		local ok, err = dns:cleanup(provision_state)
		if err then
			return nil, err
		end
		self.store:delete_order_provision(primary_domain, domain)
		return true
	end
	return nil, err
end

local cleanup = function(self, primary_domain, purge)
	if purge then
		self.store:delete_order_info(primary_domain)
	end
	self.orders[primary_domain] = nil
	return true
end

local finalize = function(self, primary_domain)
	local order = self.orders[primary_domain].info
	local finalize_url = order.finalize

	local cert_key = self.store:load_cert_key(primary_domain)
	if not cert_key then
		cert_key = crypto.ecc_generate_key()
		self.store:save_cert_key(primary_domain, cert_key)
	end

	-- Collect all domains for the certificate
	local alt_names = {}

	for _, identifier in ipairs(order.identifiers) do
		if identifier ~= primary_domain then
			table.insert(alt_names, identifier.value)
		end
	end
	-- Generate CSR with all domains
	local csr =
		crypto.generate_csr(cert_key.private, cert_key.public, primary_domain, #alt_names > 0 and alt_names or nil)

	local payload = { csr = crypto.b64url_encode(csr) }
	local jws = self:acme_frame(finalize_url, payload)
	local resp, err = web.request(finalize_url, {
		method = "POST",
		headers = common_headers,
		body = json.encode(jws),
	})
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			return json.decode(resp.body)
		end
	end
	return nil, resp, err
end

local fetch_certificate = function(self, primary_domain)
	local order = self.orders[primary_domain].info
	if order and order.certificate then
		local jws = self:acme_frame(order.certificate)
		local resp, err = web.request(order.certificate, {
			method = "POST",
			headers = std.tbl.merge({ ["Accept"] = "application/pem-certificate-chain" }, common_headers),
			body = json.encode(jws),
		})
		if resp then
			self.__nonce = resp.headers["replay-nonce"]
			if resp.status == 200 then
				self.store:save_certificate(primary_domain, resp.body)
				return resp.body
			end
		end
		return nil, resp, err
	end
	return nil, "certificate is not ready"
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

local acme_new = function(email, directory_url, storage_provider_cfg)
	if not email or not email:match("[^@+]@[^.]+%..*") then
		return nil, "you must provide a valid email as the account id"
	end
	if not directory_url then
		return nil, "you must provide the directory URL of an ACMEv2 provider"
	end
	local resp, err = web.request(directory_url)
	if not resp or resp.status ~= 200 then
		return nil, resp, err
	end
	local directory, err = json.decode(resp.body)
	if not directory then
		return nil, err
	end
	local storage_provider_cfg = storage_provider_cfg or {
		plugin = "file",
	}
	if not std.module_available("acme.store." .. storage_provider_cfg.plugin) then
		return nil, "no such storage plugin found: " .. storage_provider_cfg.plugin
	end
	local stp = require("acme.store." .. storage_provider_cfg.plugin)
	local store, err = stp.new(email, storage_provider_cfg)
	if err then
		return nil, "failed to initialize storage provider: " .. err
	end

	return {
		__dir = directory,
		__nonce = "",
		__kid = nil,
		__email = email,
		store = store,
		orders = {},
		generate_header = generate_header,
		sign_jws = sign_jws,
		acme_frame = acme_frame,
		key_thumbprint = key_thumbprint,
		refresh_nonce = refresh_nonce,
		load_key = load_key,
		register_account = register_account,
		init = init,
		new_order = new_order,
		order_info = order_info,
		get_authorization = get_authorization,
		get_auth_by_url = get_auth_by_url,
		solve_dns_challenge = solve_dns_challenge,
		mark_challenge_as_ready = mark_challenge_as_ready,
		finalize = finalize,
		fetch_certificate = fetch_certificate,
		cleanup = cleanup,
		cleanup_dns = cleanup_dns,
	}
end

local acme_new_le_prod = function(email, storage_provider_cfg)
	return acme_new(email, "https://acme-v02.api.letsencrypt.org/directory", storage_provider_cfg)
end

local acme_new_le_stage = function(email, storage_provider_cfg)
	return acme_new(email, "https://acme-staging-v02.api.letsencrypt.org/directory", storage_provider_cfg)
end

return { new = acme_new, le_prod = acme_new_le_prod, le_stage = acme_new_le_stage }
