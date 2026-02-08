-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Renderer registry and factory for markdown module.

Provides a pluggable renderer system with three main implementations:
- static: Full document rendering for pager/static display
- streaming: Live cursor-based rendering for LLM output
- html: For converting markdown document into HTML5

Usage:
    local renderer = require("markdown.renderer")

    -- Get a renderer module by name
    local static = renderer.get("static")
    local r = static.new({ width = 80 })

    -- Or use the factory function
    local r = renderer.create("static", { width = 80 })
]]

-- Registry of available renderers
-- Maps name -> module path suffix
local RENDERER_REGISTRY = {
	static = "static",
	streaming = "streaming",
	html = "html",
}

-- Get a renderer module by name
-- @param name string Renderer name ("static", "streaming")
-- @return table Renderer module with new() function
local function get(name)
	local suffix = RENDERER_REGISTRY[name]
	if not suffix then
		return nil, "unknown renderer: " .. tostring(name)
	end
	return require("markdown.renderer." .. suffix)
end

-- Create a renderer instance by name
-- @param name string Renderer name
-- @param options table Options passed to renderer.new()
-- @return table Renderer instance
local function create(name, options)
	local mod, err = get(name)
	if not mod then
		return nil, err
	end
	return mod.new(options)
end

-- List available renderer names
local function list()
	local names = {}
	for name, _ in pairs(RENDERER_REGISTRY) do
		names[#names + 1] = name
	end
	return names
end

return {
	get = get,
	create = create,
	list = list,
}
