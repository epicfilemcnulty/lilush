local std = require("std")
local acme = require("acme")
local crypto = require("crypto")

--[[
 State format for each order:

 state[primary_domain] = {
     domains = {domain1, domain2, ...},     -- All domains in this order
     count = n,                             -- Total number of domains
     idx = 1,                               -- Current authorization index being processed
     challenges = {                         -- Challenge status for each domain
         [domain1] = "new|solved|marked|validated",
         [domain2] = "new|solved|marked|validated",
         ...
     }
 }
]]

local get_certs_expire_time = function(self)
	if not std.fs.dir_exists(self.__acme_dir .. "/certs") then
		self.logger:log(
			{ process = "acme", msg = "no cert_dir found", cert_dir = self.__acme_dir .. "/certs" },
			"error"
		)
	end
	local min_expire_time = 0

	for _, cert in ipairs(self.__config.certificates) do
		local primary_domain = cert.names[1]
		local pd = primary_domain:gsub("^%*", "_")
		local cert_path = self.__acme_dir .. "/certs/" .. pd .. ".crt"
		local cert_pem = std.fs.read_file(cert_path)
		local expires_at = -1 -- means we don't have a cert at all
		if cert_pem then
			local cert_info = crypto.parse_x509_cert(cert_pem)
			if cert_info then
				expires_at = std.conv.date_to_ts(cert_info.not_after)
				local expires_in = expires_at - os.time()
				if min_expire_time == 0 or expires_in < min_expire_time then
					min_expire_time = expires_in
				end
				self.logger:log({
					process = "acme",
					msg = "certificate found",
					domain = primary_domain,
					certfile = cert_path,
					expires_at = expires_at,
				}, "debug")
			end
		else
			self.logger:log({
				process = "acme",
				msg = "no certificate found",
				domain = primary_domain,
				certfile = cert_path,
			}, "debug")
		end
		cert.expires_at = expires_at
	end
	return min_expire_time
end

local all_certs_present = function(self)
	for _, cert in ipairs(self.__config.certificates) do
		if not cert.expires_at or cert.expires_at < 0 then
			return nil
		end
	end
	return true
end

local all_challenges_solved = function(self, primary_domain)
	local state = self.state[primary_domain]
	for _, status in pairs(state.challenges) do
		if status ~= "validated" then
			return false
		end
	end
	return true
end

local place_order = function(self, domain_names)
	local primary_domain = domain_names[1]
	if self.state[primary_domain] then
		self.logger:log({ process = "acme", msg = "order's been placed already", domain = primary_domain }, "debug")
		return true
	end

	self.state[primary_domain] = {
		idx = 1,
		count = #domain_names,
		challenges = {},
		domains = {},
	}

	local order, err = self.client:new_order(domain_names)
	if not order then
		self.logger:log({ process = "acme", msg = "order placing failed", domain = primary_domain, err = err }, "error")
		return nil
	end
	for _, identifier in ipairs(order.identifiers) do
		table.insert(self.state[primary_domain].domains, identifier.value)
	end

	for _, domain in ipairs(domain_names) do
		self.state[primary_domain].challenges[domain] = "new"
	end

	self.logger:log({ process = "acme", msg = "order successfully placed", domain = primary_domain })
	return true
end

local solve_challenge = function(self, primary_domain)
	local state = self.state[primary_domain]
	local domain = self.state[primary_domain].domains[state.idx]

	local auth = self.client:get_authorization(primary_domain, domain)
	if not auth then
		self.logger:log({
			process = "acme",
			msg = "failed to get authorization object",
			primary_domain = primary_domain,
			domain = domain,
		}, "error")
		return nil
	end

	self.logger:log({
		process = "acme",
		msg = "processing authorization",
		primary_domain = primary_domain,
		domain = domain,
		auth = auth,
	}, "debug")

	if auth.status ~= "pending" then
		self.logger:log({
			process = "acme",
			msg = "authorization is in wrong state",
			primary_domain = primary_domain,
			domain = domain,
			status = auth.status,
		}, "warn")
		return nil
	end

	local provider_name = self:provider_by_domain(primary_domain)
	local cfg = self.__config.providers[provider_name]
	local ok, err = self.client:solve_challenge(primary_domain, domain, provider_name, cfg)
	if not ok then
		self.logger:log({
			process = "acme",
			msg = "challenge provisioning failed",
			primary_domain = primary_domain,
			domain = domain,
			err = err,
		}, "error")
		return nil
	end

	state.challenges[domain] = "solved"
	self.logger:log({
		process = "acme",
		msg = "challenge provisioned",
		primary_domain = primary_domain,
		domain = domain,
	})
	return true
end

local mark_challenge_as_ready = function(self, primary_domain)
	local state = self.state[primary_domain]
	local domain = self.state[primary_domain].domains[state.idx]

	local _, err = self.client:mark_challenge_as_ready(primary_domain, domain)
	if err then
		self.logger:log({
			process = "acme",
			msg = "failed to mark challenge as ready",
			primary_domain = primary_domain,
			domain = domain,
			err = err,
		}, "error")
		return nil
	end

	state.challenges[domain] = "marked"
	self.logger:log({
		process = "acme",
		msg = "challenge marked as ready",
		primary_domain = primary_domain,
		domain = domain,
	})
	return true
end

local cleanup_challenge = function(self, primary_domain)
	local state = self.state[primary_domain]
	local domain = self.state[primary_domain].domains[state.idx]

	local provider_name = self:provider_by_domain(primary_domain)
	local cfg = self.__config.providers[provider_name]
	local ok, err = self.client:cleanup_provision(primary_domain, domain, provider_name, cfg)
	if not ok then
		self.logger:log({
			process = "acme",
			msg = "challenge cleanup failed",
			primary_domain = primary_domain,
			domain = domain,
			err = err,
		}, "error")
		return nil
	end

	state.challenges[domain] = "validated"
	-- Move to next authorization if available
	if state.idx < state.count then
		state.idx = state.idx + 1
	end

	self.logger:log({
		process = "acme",
		msg = "challenge cleaned up",
		primary_domain = primary_domain,
		domain = domain,
	})
	return true
end

local send_csr = function(self, primary_domain)
	if not self.state[primary_domain] then
		self.logger:log({ process = "acme", msg = "no domain info found for CSR", domain = primary_domain }, "error")
		return nil
	end
	if not self.state[primary_domain].csr_sent then
		local ok, err = self.client:finalize(primary_domain)
		if not ok then
			self.logger:log({
				process = "acme",
				msg = "CSR request failed",
				domain = primary_domain,
				err = err,
			}, "error")
			return nil
		end
		self.logger:log({ process = "acme", msg = "CSR request sent", domain = primary_domain })
		self.state[primary_domain].csr_sent = true
	end
	return true
end

local get_certificate = function(self, primary_domain)
	local ok, err = self.client:fetch_certificate(primary_domain)
	if ok then
		self.logger:log({ process = "acme", msg = "certificate fetched", domain = primary_domain })
		self.state[primary_domain] = nil
		self.client:cleanup(primary_domain)
	else
		self.logger:log({ process = "acme", msg = "certificate fetch failed", domain = primary_domain, err = err })
	end
	return ok, err
end

local provider_by_domain = function(self, domain)
	for _, cert in ipairs(self.__config.certificates) do
		for _, cert_domain in ipairs(cert.names) do
			if cert_domain == domain then
				return cert.provider
			end
		end
	end
	return nil
end

local manage = function(self)
	math.randomseed(os.time())

	while true do
		local min_expire_time = self:get_certs_expire_time()

		-- Check for certificates that need renewal
		for _, cert in ipairs(self.__config.certificates) do
			if cert.expires_at < 0 then
				self:place_order(cert.names)
			else
				local expires_in = cert.expires_at - os.time()
				if expires_in <= self.__config.renew_time then
					self.logger:log({
						process = "acme",
						msg = "certificate renewal",
						domain = cert.names[1],
						expires_in = expires_in,
					})
					self:place_order(cert.names)
				end
			end
		end

		-- Process pending orders
		for primary_domain, state in pairs(self.state) do
			local order = self.client:order_info(primary_domain)
			if order then
				if order.status == "pending" or order.status == "ready" then
					local domain = state.domains[state.idx]
					local challenge_status = state.challenges[domain]
					if challenge_status == "new" then
						local provider = self:provider_by_domain(primary_domain)
						if self:solve_challenge(primary_domain) then
							if provider:match("dns") then
								self.logger:log({
									process = "acme",
									msg = "waiting for DNS to propagate",
									primary_domain = primary_domain,
									domain = domain,
									duration = 120,
								})
								std.sleep(120)
							end
						end
					elseif challenge_status == "solved" then
						self:mark_challenge_as_ready(primary_domain)
					elseif challenge_status == "marked" then
						local auth = self.client:get_authorization(primary_domain, domain)
						if auth and auth.status == "valid" then
							self:cleanup_challenge(primary_domain)
						end
					end
				end
				if order.status == "ready" and self:all_challenges_solved(primary_domain) then
					self:send_csr(primary_domain)
				end
				if order.status == "valid" then
					self:get_certificate(primary_domain)
				end
				if order.status == "invalid" then
					self.logger:log(
						{ process = "acme", primary_domain = primary_domain, msg = "order is invalid" },
						"error"
					)
					for _, url in ipairs(order.authorizations) do
						self.logger:log({
							process = "acme",
							primary_domain = primary_domain,
							msg = "order's auth",
							auth = self.client:get_auth_by_url(url),
						}, "debug")
					end
					os.exit(-1)
				end
			end
		end

		-- Calculate sleep duration
		local sleep_duration = math.random(10, 30)
		if min_expire_time > 0 then
			local min = 1
			local max = min_expire_time - self.__config.renew_time
			if max > 0 then
				min = math.ceil(max * 0.8)
			end
			sleep_duration = math.random(min, max)
		end

		self.logger:log({ process = "acme", msg = "sleeping", duration = sleep_duration })
		std.sleep(sleep_duration)
	end
end

local http_handle = function(method, query, args, headers, body, ctx)
	local storage = require("reliw.store")
	local store, err = storage.new(ctx.cfg)
	if err then
		ctx.logger:log("redis connection error", "error")
		return "db connection error", 501, { ["content-type"] = "text/plain" }
	end
	if method ~= "GET" then
		return "Method Not Allowed", 405, { ["content-type"] = "text/plain" }
	end

	local host = headers.host or headers.Host
	local token = query:match("^/%.well%-known/acme%-challenge/(.*)")
	if not token or not host then
		return "Bad Request", 401, { ["content-type"] = "text/plain" }
	end
	local challenge = store:get_acme_challenge(host, token)
	if challenge then
		return challenge, 200
	end

	return "Not Found", 404, { ["content-type"] = "text/plain" }
end

local acme_manager_new = function(srv_cfg, logger)
	local acme_dir = srv_cfg.data_dir .. "/.acme"
	local account = srv_cfg.ssl.acme.account
	local client, err = acme.le_prod(account, { plugin = "file", storage_dir = acme_dir })
	if not client then
		return nil, "failed to initialize acme client: " .. err
	end
	local ok, err = client:init()
	if not ok then
		return nil, "failed to initialize acme client: " .. err
	end
	local manager = {
		__config = srv_cfg.ssl.acme,
		__acme_dir = acme_dir,
		__ready = 0,
		logger = logger,
		state = {},
		client = client,
		get_certs_expire_time = get_certs_expire_time,
		all_certs_present = all_certs_present,
		place_order = place_order,
		solve_challenge = solve_challenge,
		cleanup_challenge = cleanup_challenge,
		mark_challenge_as_ready = mark_challenge_as_ready,
		all_challenges_solved = all_challenges_solved,
		send_csr = send_csr,
		get_certificate = get_certificate,
		provider_by_domain = provider_by_domain,
		manage = manage,
		http_handle = http_handle,
	}
	if not manager.__config.providers then
		manager.__config.providers = {}
	end
	manager.__config.providers["http.reliw"] = { redis = srv_cfg.redis }
	manager.__config.renew_time = manager.__config.renew_time or 2592000 -- one month
	return manager
end

return { new = acme_manager_new }
