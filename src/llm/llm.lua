-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local oaic = require("llm.oaic")
local llamacpp = require("llm.llamacpp")

local new = function(backend, api_url)
	backend = backend or "llamacpp"
	if backend == "oaic" then
		return oaic.new(api_url)
	elseif backend == "llamacpp" then
		return llamacpp.new(api_url)
	else
		return nil, "unknown backend: " .. tostring(backend)
	end
end

return {
	new = new,
	templates = require("llm.templates"),
	tools = require("llm.tools"),
}
