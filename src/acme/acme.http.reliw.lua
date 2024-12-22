local crypto = require("crypto")
local storage = require("reliw.store")

local provision = function(self, domain, token, key_thumbprint)
	if not domain or type(domain) ~= "string" then
		return nil, "domain name must be provided and must be a string"
	end
	if domain:match("%*") then
		return nil, "wildcards can't be verified by http challenge"
	end
	local txt_value = crypto.b64url_encode(crypto.sha256(token .. "." .. key_thumbprint))
	-- url: $domain/.well-known/acme-challenge/$token
	local _, err = self.store:provision_acme_challenge(domain, token, txt_value)
	if err then
		return nil, err
	end
	return { provider = "reliw", domain = domain, token = token }
end

local cleanup = function(self, provision_state)
	if not provision_state or not provision_state.domain or not provision_state.token then
		return nil, "invalid provision state"
	end
	return self.store:cleanup_acme_challenge(provision_state.domain, provision_state.token)
end

local new = function(cfg)
	local store = storage.new(cfg)
	if err then
		return nil, err
	end
	return {
		store = store,
		provision = provision,
		cleanup = cleanup,
	}
end

return { new = new }
