-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local oaic = require("llm.oaic")
local llamacpp = require("llm.llamacpp")

local new = function(backend, api_url, api_key)
	backend = backend or "llamacpp"
	if backend == "oaic" then
		return oaic.new(api_url, api_key)
	elseif backend == "llamacpp" then
		return llamacpp.new(api_url, api_key)
	else
		return nil, "unknown backend: " .. tostring(backend)
	end
end

return {
	new = new,
	templates = require("llm.templates"),
	tools = require("llm.tools"),
}
