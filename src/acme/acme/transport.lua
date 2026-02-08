-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local web = require("web")
local json = require("cjson.safe")
local jws = require("acme.jws")

local common_headers = {
	["Content-Type"] = "application/jose+json",
	["User-Agent"] = "RELIW-ACME-CLIENT/0.5",
}

local request = function(client, url, opts)
	local resp, err = web.request(url, opts)
	if resp and resp.headers and resp.headers["replay-nonce"] then
		client.__state.nonce = resp.headers["replay-nonce"]
	end
	return resp, err
end

local request_jws = function(client, url, payload, use_jwk, extra_headers)
	local req_headers = common_headers
	if extra_headers then
		req_headers = std.tbl.merge(req_headers, extra_headers)
	end
	local body = json.encode(jws.frame(client, url, payload, use_jwk))
	return request(client, url, {
		method = "POST",
		headers = req_headers,
		body = body,
	})
end

local decode_json_body = function(resp)
	if not resp then
		return nil, "empty response"
	end
	return json.decode(resp.body)
end

return {
	common_headers = common_headers,
	request = request,
	request_jws = request_jws,
	decode_json_body = decode_json_body,
}
