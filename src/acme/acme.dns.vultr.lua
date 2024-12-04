local crypto = require("crypto")
local web = require("web")
local json = require("cjson.safe")

local provision = function(self, domain, key_authorization)
	local base_domain = domain:match("([^.]+%.[^.]+)$")
	local sub_domain = "." .. domain:match("^([^.]+)%.")
	local dots = 0
	for dot in domain:gmatch("%.") do
		dots = dots + 1
	end
	if dots == 1 then
		base_domain = domain
		sub_domain = ""
	end
	local api_endpoint = "https://api.vultr.com/v2/domains/" .. base_domain .. "/records"
	local dns_txt_value = crypto.b64url_encode(crypto.sha256(key_authorization))
	local vultr_payload = {
		type = "TXT",
		ttl = 300,
		name = "_acme-challenge" .. sub_domain,
		data = dns_txt_value,
	}
	local resp, err =
		web.request(api_endpoint, { method = "POST", headers = self.headers, body = json.encode(vultr_payload) })
	if resp and (resp.status == 200 or resp.status == 201) then
		local info, err = json.decode(resp.body)
		if not info then
			return nil, err
		end
		return { provider = "vultr", domain = base_domain, record_id = info.record.id }
	end
	return nil, resp, err
end

local cleanup = function(self, provision_state)
	local api_endpoint = "https://api.vultr.com/v2/domains/"
		.. provision_state.domain
		.. "/records/"
		.. provision_state.record_id
	local resp, err = web.request(api_endpoint, { method = "DELETE", headers = self.headers })
	if resp and resp.status == 204 then
		return true
	end
	return nil, resp, err
end

local new = function(cfg)
	return {
		headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer " .. cfg.token,
		},
		provision = provision,
		cleanup = cleanup,
	}
end

return { new = new }
