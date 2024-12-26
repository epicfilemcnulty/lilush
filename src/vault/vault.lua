local web = require("web")
local json = require("cjson.safe")

local handle_response = function(resp, err)
	if not resp then
		return nil, "request failed: " .. err
	end
	if resp.status == 204 then
		return true
	end
	local response, err = json.decode(resp.body)
	if not response then
		return nil, "failed to parse response body: " .. err
	end
	if resp.status == 200 then
		return response
	end
	if response.errors then
		local error = table.concat(response.errors, ": ")
		return nil, error
	end
	return nil, resp.status .. ": unknown error"
end

local login = function(self, user, pass, mount)
	local mount = mount or "auth/userpass"
	if not user or type(user) ~= "string" then
		return nil, "username must be provided"
	end
	if not pass or type(pass) ~= "string" then
		return nil, "password must be provided"
	end
	local url = self.vault_addr .. "/v1/" .. mount .. "/login/" .. user
	local body = { password = pass }
	local response, err =
		handle_response(web.request(url, { method = "POST", body = json.encode(body), headers = self.headers }))
	if not response then
		return nil, err
	end
	self.headers["x-vault-token"] = response.auth.client_token
	local lease_duration = response.auth.lease_duration or 0
	self.token = response.auth.client_token
	self.valid_till = lease_duration + os.time()
	return response
end

local set_token = function(self, token)
	local token = token or os.getenv("VAULT_TOKEN")
	if not token then
		return nil, "no token provided/found"
	end
	self.headers["x-vault-token"] = token
	return true
end

local get_secret = function(self, path, mount)
	local mount = mount or "secret"
	if not path or type(path) ~= "string" then
		return nil, "secret path not provided"
	end
	local secret, field = path:match("^([^#]+)#([^#]+)$")
	if not secret then
		secret = path
	end
	local url = self.vault_addr .. "/v1/" .. mount .. "/" .. secret
	local response, err = handle_response(web.request(url, { method = "GET", headers = self.headers }))
	if not response then
		return nil, err
	end
	if field and response.data[field] then
		return response.data[field]
	end
	return response.data
end

local list_secrets = function(self, path, mount)
	local mount = mount or "secret"
	if not path or type(path) ~= "string" then
		return nil, "secret path not provided"
	end
	local url = self.vault_addr .. "/v1/" .. mount .. "/" .. path
	local response, err = handle_response(web.request(url, { method = "LIST", headers = self.headers }))
	if not response then
		return nil, err
	end
	return response.data.keys
end

local healthy = function(self)
	local url = self.vault_addr .. "/v1/sys/health"
	local response, err = handle_response(web.request(url, { method = "GET", headers = self.headers }))
	if not response then
		return nil, err
	end
	if response.initialized then
		if response.sealed then
			return nil, "vault is sealed"
		end
		return true
	end
	return nil, "vault is not initialized"
end

local new = function(vault_addr, token)
	local client = {
		vault_addr = vault_addr or os.getenv("VAULT_ADDR") or "127.0.0.1:8200",
		headers = {
			["content-type"] = "application/json",
			["x-vault-token"] = nil,
		},
		healthy = healthy,
		login = login,
		set_token = set_token,
		get_secret = get_secret,
		list_secrets = list_secrets,
	}
	client:set_token(token)
	return client
end

return { new = new }
