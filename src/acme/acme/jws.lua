-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local crypto = require("crypto")

local generate_header = function(client, url, use_jwk)
	local header = {
		alg = "ES256",
		nonce = client.__state.nonce,
		url = url,
	}
	if use_jwk then
		header.jwk = {
			kty = "EC",
			crv = "P-256",
			x = crypto.b64url_encode(client.__state.key.x),
			y = crypto.b64url_encode(client.__state.key.y),
		}
	else
		header.kid = client.__state.kid
	end
	return header
end

local key_thumbprint = function(client)
	local canonical = string.format(
		'{"crv":"P-256","kty":"EC","x":"%s","y":"%s"}',
		crypto.b64url_encode(client.__state.key.x),
		crypto.b64url_encode(client.__state.key.y)
	)
	local sha = crypto.sha256(canonical)
	return crypto.b64url_encode(sha)
end

local sign_jws = function(client, encoded_header, encoded_payload)
	local signing_input = encoded_header .. "." .. encoded_payload
	local signature = crypto.ecc_sign(client.__state.key.private, client.__state.key.public, signing_input)
	return crypto.b64url_encode(signature)
end

local frame = function(client, url, payload, use_jwk)
	local enc_header = crypto.b64url_encode_json(generate_header(client, url, use_jwk))
	local enc_payload = ""
	if payload ~= nil then
		enc_payload = crypto.b64url_encode_json(payload)
	end
	return {
		protected = enc_header,
		payload = enc_payload,
		signature = sign_jws(client, enc_header, enc_payload),
	}
end

return {
	generate_header = generate_header,
	key_thumbprint = key_thumbprint,
	sign_jws = sign_jws,
	frame = frame,
}
