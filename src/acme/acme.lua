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
	local full_key_path = self.__storage_dir .. "/accounts/" .. self.__email .. ".jwk"
	if not std.fs.file_exists(full_key_path) then
		local key_obj = crypto.ecc_generate_key()
		self.__key = key_obj
		return true
	end
	local key_obj, err = crypto.ecc_load_key(full_key_path)
	if err then
		return nil, "error loading the key: " .. err
	end
	self.__key = key_obj
	self.__kid = key_obj.kid
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
			local ok, err =
				crypto.ecc_save_key(self.__key, self.__storage_dir .. "/accounts/" .. self.__email .. ".jwk")
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
			local order_info = json.decode(resp.body)
			self.orders[order_url] = order_info
			return order_url
		end
	end
	return nil, resp, err
end

local order_info = function(self, order_url)
	local jws = self:acme_frame(order_url)
	local resp, err = web.request(order_url, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			local order_info = json.decode(resp.body)
			self.orders[order_url] = order_info
			std.fs.write_file(self.__storage_dir .. "/orders/" .. crypto.b64url_encode(order_url) .. ".json", resp.body)
			return order_info
		end
	end
	return nil, resp, err
end

local get_authorization = function(self, authorization_url)
	local jws = self:acme_frame(authorization_url)
	local resp, err =
		web.request(authorization_url, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			local authorization_info, err = json.decode(resp.body)
			return authorization_info, err
		end
	end
	return nil, resp, err
end

local accept_dns_challenge = function(self, auth_obj, dns_provider)
	if not std.module_available("acme.dns." .. dns_provider) then
		return nil, "no DNS plugin for " .. dns_provider .. " found"
	end
	local dns = require("acme.dns." .. dns_provider)

	local challenge_url, token
	for i, challenge in ipairs(auth_obj.challenges) do
		if challenge.type == "dns-01" then
			challenge_url = challenge.url
			token = challenge.token
			break
		end
	end
	if not challenge_url or not token then
		return nil, "can't parse auth object"
	end
	local domain = auth_obj.identifier.value

	local record_id, err = dns.provision(domain, token .. "." .. self:key_thumbprint())
	if not record_id then
		return nil, err
	end
	local jws = self:acme_frame(challenge_url, {})
	local resp, err = web.request(challenge_url, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			return record_id
		end
	end
	return nil, resp, err
end

local finalize = function(self, finalize_url, domain)
	local cert_key = crypto.ecc_generate_key()
	local cert_key_pem = crypto.der_to_pem_ecc_key(cert_key)
	std.fs.write_file(self.__storage_dir .. "/certs/" .. domain .. ".key", cert_key_pem)
	local csr = crypto.generate_csr(cert_key.private, cert_key.public, domain)
	local payload = { csr = crypto.b64url_encode(csr) }
	local jws = self:acme_frame(finalize_url, payload)
	local resp, err = web.request(finalize_url, { method = "POST", headers = common_headers, body = json.encode(jws) })
	if resp then
		self.__nonce = resp.headers["replay-nonce"]
		if resp.status == 201 or resp.status == 200 then
			return json.decode(resp.body)
		end
	end
	return nil, resp, err
end

local fetch_certificate = function(self, order_url)
	local info = self:order_info(order_url)
	if info and info.certificate then
		local jws = self:acme_frame(info.certificate)
		local resp, err = web.request(info.certificate, {
			method = "POST",
			headers = std.tbl.merge({ ["Accept"] = "application/pem-certificate-chain" }, common_headers),
			body = json.encode(jws),
		})
		if resp then
			self.__nonce = resp.headers["replay-nonce"]
			if resp.status == 200 then
				local domain_name = info.identifiers[1].value
				std.fs.write_file(self.__storage_dir .. "/certs/" .. domain_name .. ".crt", resp.body)
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

local acme_new = function(email, directory_url, storage_dir)
	if not email or not email:match("[^@+]@[^.]+%..*") then
		return nil, "you must provide a valid email as the account id"
	end
	local directory_url = directory_url or "https://acme-staging-v02.api.letsencrypt.org/directory"
	local resp, err = web.request(directory_url)
	if not resp or resp.status ~= 200 then
		return nil, resp, err
	end
	local directory, err = json.decode(resp.body)
	if not directory then
		return nil, err
	end
	local storage_dir = storage_dir or (os.getenv("HOME") or "/tmp") .. "/.acme"

	if not std.fs.dir_exists(storage_dir) then
		if not std.fs.mkdir(storage_dir) then
			return nil, "failed to create storage dir"
		end
	end
	std.fs.mkdir(storage_dir .. "/accounts")
	std.fs.mkdir(storage_dir .. "/orders")
	std.fs.mkdir(storage_dir .. "/certs")
	return {
		__dir = directory,
		__nonce = "",
		__kid = nil,
		__email = email,
		__storage_dir = storage_dir,
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
		accept_dns_challenge = accept_dns_challenge,
		finalize = finalize,
		fetch_certificate = fetch_certificate,
	}
end

return { new = acme_new }

--[[
order_url, err = client:new_order({ "test22.deviant.guru" })
handle_response(order_url, err)
handle_response(client:order_info(order_url))

handle_response(client:fetch_certificate(order_url))
local auth, err = client:get_authorization(client.orders[order_url].authorizations[1])
handle_response(auth, err)

local resp, err = client:finalize(client.orders[order_url].finalize, "test22.deviant.guru")
handle_response(resp, err)

local record_id, err = client:accept_dns_challenge(auth)
handle_response(record_id, err)

std.sleep(2)
local auth, err = client:get_authorization(client.orders[order_url].authorizations[1])
handle_response(auth, err)
]]
