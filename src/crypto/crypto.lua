-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local core = require("crypto.core")

local _M = {}

local bin_to_hex = function(bin)
	local hex = string.gsub(bin, ".", function(c)
		return string.format("%02x", string.byte(c))
	end)
	return hex
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

_M.bin_to_hex = bin_to_hex
_M.sha256 = sha256
_M.hmac = hmac
_M.b64_encode = b64_encode
_M.b64_decode = b64_decode
return _M
