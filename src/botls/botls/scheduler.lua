-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local get_certs_expire_time = function(self)
	local min_expire_time = 0
	for _, cert in ipairs(self.cfg.certificates or {}) do
		local primary_domain = cert.names[1]
		local meta, err = self.client:get_certificate_meta(primary_domain)
		local expires_at = -1

		if not meta then
			self.logger:log({
				process = "acme",
				msg = "failed to load certificate metadata",
				domain = primary_domain,
				err = err,
			}, "error")
		elseif meta.exists and meta.not_after_ts then
			expires_at = meta.not_after_ts
			local expires_in = expires_at - self.__deps.time()
			if min_expire_time == 0 or expires_in < min_expire_time then
				min_expire_time = expires_in
			end
			self.logger:log({
				process = "acme",
				msg = "certificate found",
				domain = primary_domain,
				certfile = meta.cert_path,
				expires_at = expires_at,
			}, "debug")
		else
			self.logger:log({
				process = "acme",
				msg = "no certificate found",
				domain = primary_domain,
				certfile = meta and meta.cert_path or nil,
			}, "debug")
		end

		cert.expires_at = expires_at
	end
	return min_expire_time
end

local all_certs_present = function(self)
	for _, cert in ipairs(self.cfg.certificates or {}) do
		if not cert.expires_at or cert.expires_at < 0 then
			return nil
		end
	end
	return true
end

local next_sleep_duration = function(self, min_expire_time)
	local sleep_duration = self.__deps.random(10, 30)
	if min_expire_time > 0 then
		local time_until_renewal = min_expire_time - self.cfg.renew_time
		if time_until_renewal > 3600 then
			local min = math.max(1, math.ceil(time_until_renewal * 0.8))
			local max = time_until_renewal
			sleep_duration = self.__deps.random(min, max)
		else
			sleep_duration = self.__deps.random(10, 30)
		end
	end
	return sleep_duration
end

return {
	get_certs_expire_time = get_certs_expire_time,
	all_certs_present = all_certs_present,
	next_sleep_duration = next_sleep_duration,
}
