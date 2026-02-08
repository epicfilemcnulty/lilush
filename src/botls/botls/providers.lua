-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local provider_by_domain = function(self, domain)
	for _, cert in ipairs(self.cfg.certificates or {}) do
		for _, cert_domain in ipairs(cert.names or {}) do
			if cert_domain == domain then
				return cert.provider
			end
		end
	end
	return nil
end

return {
	provider_by_domain = provider_by_domain,
}
