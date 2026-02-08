-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local all_challenges_solved = function(self, primary_domain)
	local state = self.__state.orders[primary_domain]
	for _, status in pairs(state.challenges) do
		if status ~= "validated" then
			return false
		end
	end
	return true
end

local place_order = function(self, domain_names)
	local primary_domain = domain_names[1]
	if self.__state.orders[primary_domain] then
		self.logger:log({ process = "acme", msg = "order's been placed already", domain = primary_domain }, "debug")
		return true
	end

	self.__state.orders[primary_domain] = {
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

	for _, identifier in ipairs(order.identifiers or {}) do
		table.insert(self.__state.orders[primary_domain].domains, identifier.value)
	end
	for _, domain in ipairs(domain_names) do
		self.__state.orders[primary_domain].challenges[domain] = "new"
	end

	self.logger:log({ process = "acme", msg = "order successfully placed", domain = primary_domain })
	return true
end

local solve_challenge = function(self, primary_domain)
	local state = self.__state.orders[primary_domain]
	local domain = state.domains[state.idx]
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
	local provider_cfg = self.cfg.providers[provider_name]
	local ok, err = self.client:solve_challenge(primary_domain, domain, provider_name, provider_cfg)
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
	local state = self.__state.orders[primary_domain]
	local domain = state.domains[state.idx]
	local ok, err = self.client:mark_challenge_as_ready(primary_domain, domain)
	if not ok then
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
	local state = self.__state.orders[primary_domain]
	local domain = state.domains[state.idx]
	local provider_name = self:provider_by_domain(primary_domain)
	local provider_cfg = self.cfg.providers[provider_name]
	local ok, err = self.client:cleanup_provision(primary_domain, domain, provider_name, provider_cfg)
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
	if state.idx < state.count then
		state.idx = state.idx + 1
	end
	self.logger:log({ process = "acme", msg = "challenge cleaned up", primary_domain = primary_domain, domain = domain })
	return true
end

local send_csr = function(self, primary_domain)
	local order_state = self.__state.orders[primary_domain]
	if not order_state then
		self.logger:log({ process = "acme", msg = "no domain info found for CSR", domain = primary_domain }, "error")
		return nil
	end
	if not order_state.csr_sent then
		local ok, err = self.client:finalize(primary_domain)
		if not ok then
			self.logger:log(
				{ process = "acme", msg = "CSR request failed", domain = primary_domain, err = err },
				"error"
			)
			return nil
		end
		self.logger:log({ process = "acme", msg = "CSR request sent", domain = primary_domain })
		order_state.csr_sent = true
	end
	return true
end

local get_certificate = function(self, primary_domain)
	local ok, err = self.client:fetch_certificate(primary_domain)
	if ok then
		self.logger:log({ process = "acme", msg = "certificate fetched", domain = primary_domain })
		self.__state.orders[primary_domain] = nil
		self.client:cleanup(primary_domain)
	else
		self.logger:log({ process = "acme", msg = "certificate fetch failed", domain = primary_domain, err = err })
	end
	return ok, err
end

return {
	all_challenges_solved = all_challenges_solved,
	place_order = place_order,
	solve_challenge = solve_challenge,
	mark_challenge_as_ready = mark_challenge_as_ready,
	cleanup_challenge = cleanup_challenge,
	send_csr = send_csr,
	get_certificate = get_certificate,
}
