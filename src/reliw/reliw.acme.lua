local std = require("std")
local json = require("cjson.safe")
local acme = require("acme")
local store = require("reliw.store")
local crypto = require("crypto")

local get_certs_expire_time = function(self)
	if not std.fs.dir_exists(self.__acme_dir .. "/certs") then
		self.logger:log(
			{ process = "acme", msg = "no cert_dir found", cert_dir = self.__acme_dir .. "/certs" },
			"error"
		)
	end
	local min_expire_time = 0

	for _, domain in ipairs(self.__config.domains) do
		local cert_path = self.__acme_dir .. "/certs/" .. domain.name .. ".crt"
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
					domain = domain.name,
					certfile = cert_path,
					expires_at = expires_at,
				}, "debug")
			end
		else
			self.logger:log({
				process = "acme",
				msg = "no certificate found",
				domain = domain.name,
				certfile = cert_path,
			})
		end
		domain.expires_at = expires_at
	end
	return min_expire_time
end

local all_certs_present = function(self)
	for _, domain in ipairs(self.__config.domains) do
		if not domain.expires_at or domain.expires_at < 0 then
			return nil
		end
	end
	return true
end

local request_certificate = function(self, domain, provider)
	if self.state[domain] then
		self.logger:log({ process = "acme", msg = "certificate already requested", domain = domain }, "debug")
		return true
	end
	self.state[domain] = {}
	local order_url, err = self.client:new_order({ domain })
	if err then
		self.logger:log({ process = "acme", msg = "certificate request failed", domain = domain }, "error")
		return nil
	end
	self.state[domain].order_url = order_url
	local ok, err = self.client:get_authorization(order_url)
	if not ok then
		self.logger:log({ process = "acme", msg = "authorization request failed", domain = domain }, "error")
		return nil
	end
	local ok, err = self.client:accept_dns_challenge(order_url, provider)
	if not ok then
		self.logger:log({ process = "acme", msg = "accept dns challenge failed", domain = domain }, "error")
		return nil
	end
	self.logger:log({ process = "acme", msg = "certificate requested", domain = domain })
	return true
end

local send_csr = function(self, order_urls)
	for _, order_url in ipairs(order_urls) do
		local domain = self.client.orders[order_url].identifiers[1].value
		if not self.state[domain].csr_sent then
			local ok, err = self.client:finalize(order_url)
			if not ok then
				self.logger:log({ process = "acme", msg = "CSR request failed", domain = domain }, "error")
			else
				self.logger:log({ process = "acme", msg = "CSR request sent", domain = domain })
				self.state[domain].csr_sent = true
			end
		end
	end
	return true
end

local get_certificates = function(self, order_urls)
	for _, order_url in ipairs(order_urls) do
		local ok, err = self.client:fetch_certificate(order_url)
		local domain = self.client.orders[order_url].identifiers[1].value
		if ok then
			self.logger:log({ process = "acme", msg = "certificate fetched", domain = domain })
			self.client:cleanup(order_url)
			self.state[domain] = nil
		else
			self.logger:log({ process = "acme", msg = "certificate fetch failed", domain = domain }, "error")
		end
	end
end

local manage = function(self)
	local store = store.new()
	math.randomseed(os.time())
	while true do
		local min_expire_time = self:get_certs_expire_time()
		for i, domain in ipairs(self.__config.domains) do
			if domain.expires_at < 0 then
				self:request_certificate(domain.name, domain.provider)
			else
				local expires_in = domain.expires_at - os.time()
				if expires_in <= self.__config.renew_time then
					self.logger:log({
						process = "acme",
						msg = "certificate renewal",
						domain = domain.name,
						expires_in = expires_in,
					})
					self:request_certificate(domain.name, domain.provider)
				end
			end
		end
		local ready_to_finalize = self.client:ready_to_finalize()
		if #ready_to_finalize > 0 then
			self:send_csr(ready_to_finalize)
		end
		local ready_to_fetch = self.client:ready_to_fetch()
		if #ready_to_fetch > 0 then
			self:get_certificates(ready_to_fetch)
		end
		local sleep_duration = math.random(1, 15)
		if self.__ready < 2 then
			if self:all_certs_present() then
				store:send_ctl_msg("ACME READY")
				self.__ready = self.__ready + 1
			end
		elseif min_expire_time > 0 then
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

local acme_manager_new = function(srv_cfg, logger)
	local acme_dir = srv_cfg.data_dir .. "/.acme"
	local account = srv_cfg.ssl.acme.account
	local client, err = acme.le_prod(account, { plugin = "file", storage_dir = acme_dir })
	if err then
		return nil, "failed to initialize acme client: " .. err
	end
	local ok, err = client:init()
	if err then
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
		request_certificate = request_certificate,
		send_csr = send_csr,
		get_certificates = get_certificates,
		manage = manage,
	}
	manager.__config.renew_time = manager.__config.renew_time or 2592000 -- one month
	return manager
end

return { new = acme_manager_new }
