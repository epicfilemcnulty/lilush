-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Agent configuration module.

Handles loading configuration from file, environment variables,
and provides defaults. Supports runtime model/backend switching.

Config file: ~/.config/lilush/agent.json
]]

local std = require("std")
local json = require("cjson.safe")

-- Zen model configurations with explicit api_style
-- api_style: "anthropic" or "oaic"
-- endpoint: specific endpoint path (for oaic style)
local zen_models = {
	-- Anthropic models via Zen (use /messages endpoint)
	["claude-sonnet-4"] = { api_style = "anthropic" },
	["claude-sonnet-4-5"] = { api_style = "anthropic" },
	["claude-haiku-4-5"] = { api_style = "anthropic" },
	["claude-3-5-haiku"] = { api_style = "anthropic" },
	["claude-opus-4-5"] = { api_style = "anthropic" },
	["claude-opus-4-1"] = { api_style = "anthropic" },
	-- Special case: minimax-m2.1-free uses anthropic style
	["minimax-m2.1-free"] = { api_style = "anthropic" },

	-- OpenAI models via Zen (use /responses endpoint)
	["gpt-5.2"] = { api_style = "oaic", endpoint = "/responses" },
	["gpt-5.2-codex"] = { api_style = "oaic", endpoint = "/responses" },
	["gpt-5.1"] = { api_style = "oaic", endpoint = "/responses" },
	["gpt-5.1-codex"] = { api_style = "oaic", endpoint = "/responses" },
	["gpt-5.1-codex-max"] = { api_style = "oaic", endpoint = "/responses" },
	["gpt-5.1-codex-mini"] = { api_style = "oaic", endpoint = "/responses" },
	["gpt-5"] = { api_style = "oaic", endpoint = "/responses" },
	["gpt-5-codex"] = { api_style = "oaic", endpoint = "/responses" },
	["gpt-5-nano"] = { api_style = "oaic", endpoint = "/responses" },

	-- Other models via Zen (use /chat/completions endpoint)
	["minimax-m2.1"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["glm-4.7"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["glm-4.7-free"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["glm-4.6"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["kimi-k2.5"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["kimi-k2.5-free"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["kimi-k2-thinking"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["kimi-k2"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["qwen3-coder"] = { api_style = "oaic", endpoint = "/chat/completions" },
	["big-pickle"] = { api_style = "oaic", endpoint = "/chat/completions" },
}

-- Default configuration
local defaults = {
	-- Active backend and model (can be switched at runtime)
	-- Default to OpenCode Zen with Claude Sonnet 4
	backend = "zen",
	model = "claude-sonnet-4",

	-- Available backends with their default models
	backends = {
		zen = {
			url = "https://opencode.ai/zen/v1",
			api_key_env = "OPENCODE_API_KEY",
			default_model = "claude-sonnet-4",
			-- Model configs are in zen_models table above
			models = zen_models,
		},
		anthropic = {
			url = nil, -- Uses ANTHROPIC_API_URL or default
			api_key_env = "ANTHROPIC_API_KEY",
			default_model = "claude-sonnet-4-20250514",
			api_style = "anthropic", -- All models use anthropic style
		},
		oaic = {
			url = nil, -- Uses LLM_OAIC_API_URL or default
			api_key_env = "LLM_API_KEY",
			default_model = "gpt-4o",
			api_style = "oaic", -- All models use oaic style
		},
		llamacpp = {
			url = nil, -- Uses LLM_API_URL or default
			api_key_env = "LLM_API_KEY",
			default_model = "GLM-4.7-Flash",
			api_style = "oaic", -- llamacpp uses OAIC-compatible API
		},
	},

	-- To do/to think over:
	-- shall we provide a way to specify temperature
	-- or other sampling parameters? Most providers don't even
	-- expose those for coding agents, and with llamacpp we can
	-- rely on the server settings, but still..
	sampler = {
		max_new_tokens = 32768,
	},

	-- Tool-specific configuration
	tools = {
		bash = {
			approval = "ask", -- "auto", "ask", "deny"
		},
		write_file = {
			approval = "ask",
		},
		edit_file = {
			approval = "ask",
		},
		-- Read-only tools default to auto
		read_file = { approval = "auto" },
		web_search = { approval = "auto" },
		fetch_webpage = { approval = "auto" },
	},

	-- System prompt (nil = use default from agent.system_prompt)
	system_prompt = nil,

	-- Conversation settings
	max_conversation_tokens = 100000,

	-- Rendering settings
	render = {
		markdown = true,
		syntax_highlight = true,
		line_numbers = true,
	},

	-- Custom pricing overrides (merged with llm.pricing defaults)
	pricing = {},
}

-- Load configuration from file
local load_file = function()
	local home = os.getenv("HOME") or "/tmp"
	local config_path = home .. "/.config/lilush/agent.json"
	local content = std.fs.read_file(config_path)
	if not content then
		return nil
	end
	local config, err = json.decode(content)
	if not config then
		return nil, "failed to parse agent.json: " .. tostring(err)
	end
	return config
end

-- Save configuration to file
local save_file = function(config)
	local home = os.getenv("HOME") or "/tmp"
	local config_dir = home .. "/.config/lilush"
	local config_path = config_dir .. "/agent.json"

	-- Ensure directory exists
	std.fs.mkdir(config_dir)

	-- Only save user-configurable fields, not runtime state
	local to_save = {
		backend = config.backend,
		model = config.model,
		backends = config.backends,
		sampler = config.sampler,
		tools = config.tools,
		system_prompt = config.system_prompt,
		max_conversation_tokens = config.max_conversation_tokens,
		render = config.render,
		pricing = config.pricing,
	}

	local content = json.encode(to_save)
	if not content then
		return nil, "failed to encode config"
	end

	return std.fs.write_file(config_path, content)
end

local init_pricing = function(config)
	if config.pricing and next(config.pricing) then
		local pricing = require("llm.pricing")
		pricing.set_custom_prices(config.pricing)
	end
end

-- Get current backend name
local get_backend = function(self)
	return self.__state.backend
end

-- Get current model name
local get_model = function(self)
	return self.__state.model
end

-- Get backend configuration
local get_backend_config = function(self, backend_name)
	backend_name = backend_name or self.__state.backend
	return (self.cfg.backends or {})[backend_name]
end

-- Get model configuration (api_style, endpoint) for current or specified model
-- Returns { api_style = "anthropic"|"oaic", endpoint = "/path" } or nil
local get_model_config = function(self, model_name)
	model_name = model_name or self.__state.model
	local backend_config = self.get_backend_config(self)

	if not backend_config then
		return nil
	end

	-- Check if backend has per-model configs (like Zen)
	if backend_config.models and backend_config.models[model_name] then
		return backend_config.models[model_name]
	end

	-- Check if backend has a global api_style
	if backend_config.api_style then
		return { api_style = backend_config.api_style }
	end

	-- Default fallback for unknown models: use oaic with /chat/completions
	return { api_style = "oaic", endpoint = "/chat/completions" }
end

-- Set backend (switches to that backend's default model if model not specified)
local set_backend = function(self, backend_name, model_name)
	local backend_config = (self.cfg.backends or {})[backend_name]
	if not backend_config then
		return nil, "unknown backend: " .. tostring(backend_name)
	end

	self.__state.backend = backend_name
	self.__state.model = model_name or backend_config.default_model
	return true
end

-- Set model (optionally with backend)
local set_model = function(self, model_name, backend_name)
	if backend_name then
		return self.set_backend(self, backend_name, model_name)
	end
	self.__state.model = model_name
	return true
end

-- Get sampler configuration
local get_sampler = function(self)
	return std.tbl.copy(self.cfg.sampler or {})
end

-- Update sampler settings
local set_sampler = function(self, settings)
	self.cfg.sampler = self.cfg.sampler or {}
	for k, v in pairs(settings or {}) do
		self.cfg.sampler[k] = v
	end
end

-- Get tool configuration
local get_tool_config = function(self, tool_name)
	local tools = self.cfg.tools or {}
	return tools[tool_name] or { approval = "auto" }
end

-- Check if tool requires approval (considering session overrides)
local tool_needs_approval = function(self, tool_name)
	-- Session override takes precedence
	if self.__state.session_approvals[tool_name] == "auto" then
		return false
	end

	local tool_config = self.get_tool_config(self, tool_name)
	return tool_config.approval == "ask"
end

-- Set session-level approval override for a tool
local set_session_approval = function(self, tool_name, approval)
	self.__state.session_approvals[tool_name] = approval
end

-- Clear session approvals (e.g., when starting new conversation)
local clear_session_approvals = function(self)
	self.__state.session_approvals = {}
end

-- Get system prompt (returns nil if should use default)
local get_system_prompt = function(self)
	return self.cfg.system_prompt
end

-- Set system prompt
local set_system_prompt = function(self, prompt)
	self.cfg.system_prompt = prompt
end

-- Get max conversation tokens
local get_max_tokens = function(self)
	return self.cfg.max_conversation_tokens
end

-- Get render settings
local get_render_config = function(self)
	return self.cfg.render
end

-- Get list of available backends
local list_backends = function(self)
	local backends = {}
	for name, _ in pairs(self.cfg.backends or {}) do
		table.insert(backends, name)
	end
	table.sort(backends)
	return backends
end

-- Get list of models for a backend (if available)
local list_models = function(self, backend_name)
	backend_name = backend_name or self.__state.backend
	local backend_config = (self.cfg.backends or {})[backend_name]
	if not backend_config then
		return {}
	end

	if backend_config.models then
		local models = {}
		for name, _ in pairs(backend_config.models) do
			table.insert(models, name)
		end
		table.sort(models)
		return models
	end

	-- Return default model as the only option
	if backend_config.default_model then
		return { backend_config.default_model }
	end

	return {}
end

-- Get pricing overrides from config
local get_pricing_overrides = function(self)
	return self.cfg.pricing or {}
end

-- Save current configuration to file
local save = function(self)
	return save_file(self.cfg)
end

local new = function()
	local file_config = load_file() or {}
	local config = std.tbl.merge(defaults, file_config)

	local instance = {
		cfg = config,
		__state = {
			backend = config.backend,
			model = config.model,
			-- Session-level tool approval overrides
			-- When a user says "allow all" for a tool, it's stored here.
			session_approvals = {},
		},
		get_backend = get_backend,
		get_model = get_model,
		get_backend_config = get_backend_config,
		get_model_config = get_model_config,
		set_backend = set_backend,
		set_model = set_model,
		get_sampler = get_sampler,
		set_sampler = set_sampler,
		get_tool_config = get_tool_config,
		tool_needs_approval = tool_needs_approval,
		set_session_approval = set_session_approval,
		clear_session_approvals = clear_session_approvals,
		get_system_prompt = get_system_prompt,
		set_system_prompt = set_system_prompt,
		get_max_tokens = get_max_tokens,
		get_render_config = get_render_config,
		list_backends = list_backends,
		list_models = list_models,
		get_pricing_overrides = get_pricing_overrides,
		save = save,
	}

	init_pricing(config)

	return instance
end

return {
	new = new,
	defaults = defaults,
}
