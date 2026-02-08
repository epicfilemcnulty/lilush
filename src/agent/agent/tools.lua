-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Agent tools registry.

Provides a unified interface for tool management, using tools from llm.tools.
All tools are defined in llm.tools.* modules and auto-registered by llm.tools.
]]

local llm_tools = require("llm.tools")

-- Tools used by the agent (all from llm.tools)
-- These are auto-registered by llm.tools module
local agent_tools = {
	"read_file",
	"write_file",
	"edit_file",
	"bash",
	"web_search",
	"fetch_webpage",
}

-- Get tool descriptions for a list of tool names
-- If names is nil, returns all agent tools
local function get_descriptions(names)
	if not names then
		names = agent_tools
	end
	return llm_tools.get_descriptions(names)
end

-- Get list of all available tool names
local function list()
	-- Return tools that are actually registered
	local available = {}
	for _, name in ipairs(agent_tools) do
		if llm_tools.get(name) then
			table.insert(available, name)
		end
	end
	return available
end

-- Get a tool by name (from llm.tools)
local function get(name)
	return llm_tools.get(name)
end

-- Execute a tool by name
local function execute(name, arguments)
	return llm_tools.execute(name, arguments)
end

return {
	get = get,
	get_descriptions = get_descriptions,
	list = list,
	execute = execute,
	-- Re-export llm.tools.loop for convenience
	loop = llm_tools.loop,
	-- Expose the tool list for reference
	agent_tools = agent_tools,
}
