-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local core = require("crypto.core")
local std = require("std")
local json = require("cjson.safe")

local _M = {}

local bin_to_hex = function(bin)
	local hex = string.gsub(bin, ".", function(c)
		return string.format("%02x", string.byte(c))
	end)
	return hex
end

local hex_to_bin = function(hex)
	local bin = string.gsub(hex, "..", function(h)
		return string.char(tonumber(h, 16))
	end)
	return bin
end

local sha256 = function(data)
	return core.sha256(data)
end

local hmac = function(secret, msg)
	return core.hmac(secret, msg)
end

local b64_encode = function(str)
	return core.base64_encode(str)
end

local b64_decode = function(str)
	return core.base64_decode(str)
end

local b64url_encode = function(str)
	local b64_str = core.base64_encode(str)
	return b64_str:gsub("[+/= \r\n]", { ["+"] = "-", ["/"] = "_", [" "] = "", ["\r"] = "", ["\n"] = "", ["="] = "" })
end

local b64url_decode = function(str)
	str = str .. string.rep("=", (4 - (#str % 4)) % 4)
	return b64_decode(str:gsub("[-_]", { ["-"] = "+", ["_"] = "/" }))
end

local b64url_encode_json = function(tbl)
	local str = json.encode(tbl)
	return b64url_encode(str)
end

local ecc_generate_key = function()
	local key, pub, x, y = core.ecc_generate_key()
	local key_obj = {
		private = key,
		public = pub,
		x = x,
		y = y,
	}
	return key_obj
end

local save_ecc_key = function(key_obj, name)
	local name = name or bin_to_hex(std.salt(4))
	std.fs.write_file(
		name .. ".jwk",
		json.encode({
			x = b64url_encode(key_obj.x),
			y = b64url_encode(key_obj.y),
			d = b64url_encode(key_obj.private),
			pub = b64url_encode(key_obj.public),
		})
	)
end

local load_ecc_key = function(key_file)
	local content, err = std.fs.read_file(key_file)
	if not content then
		return nil, err
	end
	local jwk = json.decode(content)
	local key_obj = {
		private = b64url_decode(jwk.d),
		public = b64url_decode(jwk.pub),
		x = b64url_decode(jwk.x),
		y = b64url_decode(jwk.y),
	}
	return key_obj
end

local ecc_sign = function(key, pub_key, msg)
	return core.ecc_sign(key, pub_key, msg)
end

local ecc_verify = function(pub_key, msg, sig)
	return core.ecc_verify(pub_key, msg, sig)
end

local ed25519_generate_key = function()
	return core.ed25519_generate_key()
end

local ed25519_sign = function(key, msg)
	return core.ed25519_sign(key, msg)
end

local ed25519_verify = function(pub_key, msg, sig)
	return core.ed25519_verify(pub_key, msg, sig)
end

_M.bin_to_hex = bin_to_hex
_M.hex_to_bin = hex_to_bin
_M.b64_encode = b64_encode
_M.b64_decode = b64_decode
_M.b64url_encode = b64url_encode
_M.b64url_decode = b64url_decode
_M.b64url_encode_json = b64url_encode_json
_M.sha256 = sha256
_M.hmac = hmac
_M.ecc_generate_key = ecc_generate_key
_M.ecc_load_key = load_ecc_key
_M.ecc_save_key = save_ecc_key
_M.ecc_sign = ecc_sign
_M.ecc_verify = ecc_verify
_M.ed25519_generate_key = ed25519_generate_key
_M.ed25519_sign = ed25519_sign
_M.ed25519_verify = ed25519_verify
return _M
