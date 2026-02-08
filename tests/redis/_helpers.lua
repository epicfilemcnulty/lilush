-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local clear_modules = function(mods)
	for _, mod_name in ipairs(mods or {}) do
		package.loaded[mod_name] = nil
		package.preload[mod_name] = nil
	end
end

local stub_module = function(mod_name, value)
	package.loaded[mod_name] = nil
	package.preload[mod_name] = function()
		return value
	end
end

local load_module_from_src = function(mod_name, path)
	package.loaded[mod_name] = nil
	package.preload[mod_name] = function()
		return dofile(path)
	end
	return require(mod_name)
end

return {
	clear_modules = clear_modules,
	stub_module = stub_module,
	load_module_from_src = load_module_from_src,
}
