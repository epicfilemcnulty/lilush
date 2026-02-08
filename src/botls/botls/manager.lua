-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local scheduler = require("botls.scheduler")
local providers = require("botls.providers")
local orders = require("botls.orders")

local manage = function(self)
	while true do
		local min_expire_time = self:get_certs_expire_time()

		for _, cert in ipairs(self.cfg.certificates or {}) do
			if cert.expires_at < 0 then
				self:place_order(cert.names)
			else
				local expires_in = cert.expires_at - self.__deps.time()
				if expires_in <= self.cfg.renew_time then
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

		for primary_domain, state in pairs(self.__state.orders) do
			local order = self.client:order_info(primary_domain)
			if order then
				if order.status == "pending" or order.status == "ready" then
					local domain = state.domains[state.idx]
					local challenge_status = state.challenges[domain]
					if challenge_status == "new" then
						local provider = self:provider_by_domain(primary_domain)
						if self:solve_challenge(primary_domain) then
							if provider and provider:match("dns") then
								self.logger:log({
									process = "acme",
									msg = "waiting for DNS to propagate",
									primary_domain = primary_domain,
									domain = domain,
									duration = 120,
								})
								self.__deps.sleep(120)
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
					for _, url in ipairs(order.authorizations or {}) do
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

		local sleep_duration = self:next_sleep_duration(min_expire_time)
		self.logger:log({ process = "acme", msg = "sleeping", duration = sleep_duration })
		self.__deps.sleep(sleep_duration)
	end
end

local new = function(cfg, deps)
	deps = deps or {}
	local manager = {
		cfg = cfg,
		__state = {
			orders = {},
			ready = 0,
		},
		logger = deps.logger,
		client = deps.client,
		__deps = {
			time = deps.time or os.time,
			sleep = deps.sleep or std.sleep,
			random = deps.random or math.random,
		},

		get_certs_expire_time = scheduler.get_certs_expire_time,
		all_certs_present = scheduler.all_certs_present,
		next_sleep_duration = scheduler.next_sleep_duration,
		provider_by_domain = providers.provider_by_domain,

		all_challenges_solved = orders.all_challenges_solved,
		place_order = orders.place_order,
		solve_challenge = orders.solve_challenge,
		cleanup_challenge = orders.cleanup_challenge,
		mark_challenge_as_ready = orders.mark_challenge_as_ready,
		send_csr = orders.send_csr,
		get_certificate = orders.get_certificate,
		manage = manage,
	}
	return manager
end

return {
	new = new,
}
