-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local crypto = require("crypto")
local json = require("cjson.safe")

local replace_wildcards = function(domain)
	domain = domain or ""
	if domain:match("^%*") then
		return domain:gsub("^%*", "_")
	end
	return domain
end

local account_key_path = function(self)
	return self.__state.storage_dir .. "/accounts/" .. self.cfg.account_email .. ".jwk"
end

local order_dir = function(self)
	return self.__state.storage_dir .. "/orders/" .. self.cfg.account_email
end

local save_account_key = function(self, key)
	return crypto.ecc_save_key(key, account_key_path(self))
end

local load_account_key = function(self)
	local full_key_path = account_key_path(self)
	if not std.fs.file_exists(full_key_path) then
		local key_obj = crypto.ecc_generate_key()
		self:save_account_key(key_obj)
		return key_obj
	end
	local key_obj, err = crypto.ecc_load_key(full_key_path)
	if err then
		return nil, "error loading the key: " .. err
	end
	return key_obj
end

local save_cert_key = function(self, domain, key)
	domain = replace_wildcards(domain)
	local key_pem, err = crypto.der_to_pem_ecc_key(key)
	if err then
		return nil, "failed to convert cert's key to PEM: " .. err
	end
	local ok, write_err = std.fs.write_file(self.__state.storage_dir .. "/certs/" .. domain .. ".key", key_pem)
	if write_err then
		return nil, "failed to save certificate's key: " .. write_err
	end
	return crypto.ecc_save_key(key, self.__state.storage_dir .. "/certs/" .. domain .. ".jwk")
end

local load_cert_key = function(self, domain)
	domain = replace_wildcards(domain)
	local full_key_path = self.__state.storage_dir .. "/certs/" .. domain .. ".jwk"
	return crypto.ecc_load_key(full_key_path)
end

local save_order_info = function(self, domain, order_info)
	domain = replace_wildcards(domain)
	if not std.fs.dir_exists(order_dir(self)) then
		std.fs.mkdir(order_dir(self))
	end
	return std.fs.write_file(order_dir(self) .. "/" .. domain .. ".json", json.encode(order_info))
end

local load_order_info = function(self, domain)
	domain = replace_wildcards(domain)
	local content, err = std.fs.read_file(order_dir(self) .. "/" .. domain .. ".json")
	if not content then
		return nil, err
	end
	return json.decode(content)
end

local delete_order_info = function(self, domain)
	domain = replace_wildcards(domain)
	return std.fs.remove(order_dir(self) .. "/" .. domain .. ".json")
end

local save_order_provision = function(self, primary_domain, domain, provision)
	primary_domain = replace_wildcards(primary_domain)
	return std.fs.write_file(
		order_dir(self) .. "/" .. primary_domain .. ".provision." .. domain .. ".json",
		json.encode(provision)
	)
end

local load_order_provision = function(self, primary_domain, domain)
	primary_domain = replace_wildcards(primary_domain)
	local content, err =
		std.fs.read_file(order_dir(self) .. "/" .. primary_domain .. ".provision." .. domain .. ".json")
	if err then
		return nil, err
	end
	return json.decode(content)
end

local delete_order_provision = function(self, primary_domain, domain)
	primary_domain = replace_wildcards(primary_domain)
	return std.fs.remove(order_dir(self) .. "/" .. primary_domain .. ".provision." .. domain .. ".json")
end

local save_certificate = function(self, domain, cert_pem)
	domain = replace_wildcards(domain)
	return std.fs.write_file(self.__state.storage_dir .. "/certs/" .. domain .. ".crt", cert_pem)
end

local get_certificate_meta = function(self, domain)
	domain = replace_wildcards(domain)
	local cert_path = self.__state.storage_dir .. "/certs/" .. domain .. ".crt"
	if not std.fs.file_exists(cert_path) then
		return {
			exists = false,
			cert_path = cert_path,
		}
	end

	local cert_pem, read_err = std.fs.read_file(cert_path)
	if not cert_pem then
		return nil, read_err
	end
	local cert_info = crypto.parse_x509_cert(cert_pem)
	if not cert_info then
		return nil, "failed to parse certificate: " .. cert_path
	end
	return {
		exists = true,
		cert_path = cert_path,
		not_after_ts = std.conv.date_to_ts(cert_info.not_after),
	}
end

local new = function(cfg)
	if not cfg or not cfg.account_email then
		return nil, "account_email is required"
	end
	local storage_dir = cfg.storage_dir or (os.getenv("HOME") or "/tmp") .. "/.acme"
	if not std.fs.dir_exists(storage_dir) then
		if not std.fs.mkdir(storage_dir) then
			return nil, "failed to create storage dir"
		end
	end
	for _, subdir in ipairs({ "/accounts", "/orders", "/certs" }) do
		if not std.fs.dir_exists(storage_dir .. subdir) then
			std.fs.mkdir(storage_dir .. subdir)
		end
	end
	return {
		cfg = cfg,
		__state = {
			storage_dir = storage_dir,
		},
		load_account_key = load_account_key,
		save_account_key = save_account_key,
		save_order_info = save_order_info,
		delete_order_info = delete_order_info,
		load_order_info = load_order_info,
		save_order_provision = save_order_provision,
		load_order_provision = load_order_provision,
		delete_order_provision = delete_order_provision,
		save_cert_key = save_cert_key,
		load_cert_key = load_cert_key,
		save_certificate = save_certificate,
		get_certificate_meta = get_certificate_meta,
	}
end

return {
	new = new,
}
