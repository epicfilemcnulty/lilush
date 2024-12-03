local std = require("std")
local crypto = require("crypto")
local json = require("cjson.safe")

local save_account_key = function(self, key)
	return crypto.ecc_save_key(key, self.__storage_dir .. "/accounts/" .. self.__email .. ".jwk")
end

local load_account_key = function(self)
	local full_key_path = self.__storage_dir .. "/accounts/" .. self.__email .. ".jwk"
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

local save_order_info = function(self, domain, order_info)
	if not std.fs.dir_exists(self.__storage_dir .. "/orders/" .. self.__email) then
		std.fs.mkdir(self.__storage_dir .. "/orders/" .. self.__email)
	end
	return std.fs.write_file(
		self.__storage_dir .. "/orders/" .. self.__email .. "/" .. domain .. ".json",
		json.encode(order_info)
	)
end

local load_order_info = function(self, domain)
	local content, err = std.fs.read_file(self.__storage_dir .. "/orders/" .. self.__email .. "/" .. domain .. ".json")
	if not content then
		return nil, err
	end
	return json.decode(content)
end

local save_order_provision = function(self, domain, provision)
	return std.fs.write_file(
		self.__storage_dir .. "/orders/" .. self.__email .. "/" .. domain .. ".provision.json",
		json.encode(provision)
	)
end

local load_order_provision = function(self, domain)
	local content, err =
		std.fs.read_file(self.__storage_dir .. "/orders/" .. self.__email .. "/" .. domain .. ".provision.json")
	if err then
		return nil, err
	end
	return json.decode(content)
end

local delete_order_provision = function(self, domain)
	return std.fs.remove(self.__storage_dir .. "/orders/" .. self.__email .. "/" .. domain .. ".provision.json")
end

local save_certificate = function(self, domain, cert_pem)
	return std.fs.write_file(self.__storage_dir .. "/certs/" .. domain .. ".crt", cert_pem)
end

local save_cert_key = function(self, domain, key)
	local key_pem, err = crypto.der_to_pem_ecc_key(key)
	if err then
		return nil, "failed to save certificate's key: " .. err
	end
	return std.fs.write_file(self.__storage_dir .. "/certs/" .. domain .. ".key", key_pem)
end

local store_new = function(email, config)
	local storage_dir = config.storage_dir or (os.getenv("HOME") or "/tmp") .. "/.acme"
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
		__email = email,
		__storage_dir = storage_dir,
		load_account_key = load_account_key,
		save_account_key = save_account_key,
		save_order_info = save_order_info,
		load_order_info = load_order_info,
		save_order_provision = save_order_provision,
		load_order_provision = load_order_provision,
		delete_order_provision = delete_order_provision,
		save_cert_key = save_cert_key,
		save_certificate = save_certificate,
	}
end

return { new = store_new }
