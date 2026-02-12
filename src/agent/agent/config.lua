-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Agent configuration module.
User config file: ~/.config/lilush/agent.json
]]

local std = require("std")
local json = require("cjson.safe")
local web = require("web")

local defaults = {
	provider = "openrouter",
	model = "openai/gpt-5.2-codex",

	providers = {
		openrouter = {
			kind = "openrouter",
			url = "https://openrouter.ai/api/v1",
			api_key_env = "OPENROUTER_API_KEY",
			default_model = "openai/gpt-5.2-codex",
		},
	},

	sampler = {
		max_new_tokens = 32768,
	},

	tools = {
		bash = {
			approval = "ask",
		},
		write = {
			approval = "ask",
		},
		edit = {
			approval = "ask",
		},
		read = { approval = "auto" },
	},
	active_prompt = nil,
	system_prompt = nil,
	index_file = nil,
	max_tool_steps = 100,
}

local normalize_context_window = function(value)
	local n = tonumber(value)
	if not n then
		return nil
	end
	n = math.floor(n)
	if n < 1 then
		return nil
	end
	return n
end

local normalize_non_negative_number = function(value)
	local n = tonumber(value)
	if not n or n < 0 then
		return nil
	end
	return n
end

local trim_trailing_slash = function(value)
	if type(value) ~= "string" then
		return value
	end
	return value:gsub("/+$", "")
end

local normalize_provider_cfg = function(provider_name, provider_cfg)
	provider_cfg = provider_cfg or {}
	provider_cfg.url = trim_trailing_slash(provider_cfg.url)

	if provider_cfg.kind == "openrouter" then
		provider_cfg.api_key_env = provider_cfg.api_key_env or "OPENROUTER_API_KEY"
	elseif provider_cfg.kind == "llamacpp" then
		provider_cfg.api_key_env = provider_cfg.api_key_env or "LLM_API_KEY"
	end

	return provider_cfg
end

local resolve_provider_api_url = function(provider_name, provider_cfg)
	local configured = provider_cfg and provider_cfg.url
	if configured and configured ~= "" then
		return configured
	end

	if provider_name == "openrouter" and provider_cfg and provider_cfg.kind == "openrouter" then
		local env_url = trim_trailing_slash(os.getenv("OPENROUTER_API_URL"))
		if env_url and env_url ~= "" then
			return env_url
		end
		return "https://openrouter.ai/api/v1"
	end

	return nil
end

local provider_models_url = function(provider_name, provider_cfg, api_url)
	if type(api_url) ~= "string" or api_url == "" then
		return nil
	end

	if provider_cfg.kind == "llamacpp" then
		local base = api_url:gsub("/v1$", "")
		return base .. "/models"
	end

	return api_url .. "/models"
end

local provider_auth_headers = function(provider_name, provider_cfg)
	local headers = { ["Content-Type"] = "application/json" }
	local key_env = provider_cfg and provider_cfg.api_key_env
	local key = nil

	if type(key_env) == "string" and key_env ~= "" then
		key = os.getenv(key_env)
	end

	if key and key ~= "" then
		headers["Authorization"] = "Bearer " .. key
	end

	return headers
end

local parse_llamacpp_ctx_size = function(args)
	if type(args) ~= "table" then
		return nil
	end
	for i = 1, #args - 1 do
		if args[i] == "--ctx-size" then
			return normalize_context_window(args[i + 1])
		end
	end
	return nil
end

local list_has_value = function(values, value)
	if type(values) == "table" then
		for _, v in ipairs(values) do
			if v == value then
				return true
			end
		end
	end
	return false
end

local supports_text_io = function(model)
	local arch = model and model.architecture
	if type(arch) ~= "table" then
		return false
	end

	local input_has_text = list_has_value(arch.input_modalities, "text")
	local output_has_text = list_has_value(arch.output_modalities, "text")
	if input_has_text and output_has_text then
		return true
	end

	if type(arch.modality) == "string" and arch.modality ~= "" then
		local input, output = arch.modality:match("^([^%-]+)%-%>(.+)$")
		if input and output then
			return input:match("text") ~= nil and output:match("text") ~= nil
		end
	end

	return false
end

local parse_openrouter_model = function(model)
	if type(model) ~= "table" then
		return nil
	end

	local name = model.id
	if type(name) ~= "string" or name == "" then
		return nil
	end
	if not supports_text_io(model) then
		return nil
	end

	local top_provider = model.top_provider
	local context_window = normalize_context_window(top_provider and top_provider.context_length)
		or normalize_context_window(model.context_length)
	if not context_window then
		return nil
	end

	local pricing = model.pricing or {}
	local prompt_price = normalize_non_negative_number(pricing.prompt)
	local completion_price = normalize_non_negative_number(pricing.completion)

	return {
		name = name,
		context_window = context_window,
		prompt_price = prompt_price,
		completion_price = completion_price,
		supports_text_in = true,
		supports_text_out = true,
		loaded = nil,
	}
end

local parse_llamacpp_model = function(model)
	if type(model) ~= "table" then
		return nil
	end

	local name = model.id
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local status = model.status
	local context_window = parse_llamacpp_ctx_size(status and status.args)
		or normalize_context_window(model.context_length)
	if not context_window then
		return nil
	end

	local loaded = status and status.value == "loaded" or false

	return {
		name = name,
		context_window = context_window,
		prompt_price = nil,
		completion_price = nil,
		supports_text_in = true,
		supports_text_out = true,
		loaded = loaded,
	}
end

local fetch_provider_models = function(provider_name, provider_cfg)
	local api_url = resolve_provider_api_url(provider_name, provider_cfg)
	if not api_url then
		return nil, "provider `" .. tostring(provider_name) .. "` has invalid or missing URL"
	end

	local models_url = provider_models_url(provider_name, provider_cfg, api_url)
	if not models_url then
		return nil, "provider `" .. tostring(provider_name) .. "` has invalid models URL"
	end

	local timeout = tonumber(os.getenv("LLM_API_TIMEOUT")) or 600
	local headers = provider_auth_headers(provider_name, provider_cfg)
	local resp, err = web.request(models_url, { method = "GET", headers = headers }, timeout)
	if not resp then
		return nil, "provider `" .. tostring(provider_name) .. "` unavailable: " .. tostring(err)
	end
	if resp.status ~= 200 then
		return nil,
			"provider `"
				.. tostring(provider_name)
				.. "` unavailable: bad response status "
				.. tostring(resp.status)
				.. "\n"
				.. tostring(resp.body or "")
	end

	local decoded, decode_err = json.decode(resp.body)
	if type(decoded) ~= "table" then
		return nil,
			"provider `" .. tostring(provider_name) .. "` unavailable: invalid /models payload (" .. tostring(
				decode_err
			) .. ")"
	end

	local data = decoded.data
	if type(data) ~= "table" then
		return nil, "provider `" .. tostring(provider_name) .. "` unavailable: missing data array in /models response"
	end

	local ordered = {}
	local by_name = {}
	local parser = provider_cfg.kind == "openrouter" and parse_openrouter_model or parse_llamacpp_model

	for _, model in ipairs(data) do
		local descriptor = parser(model)
		if descriptor and not by_name[descriptor.name] then
			by_name[descriptor.name] = descriptor
			ordered[#ordered + 1] = descriptor
		end
	end

	if #ordered == 0 then
		return nil, "provider `" .. tostring(provider_name) .. "` unavailable: no usable models in /models response"
	end

	table.sort(ordered, function(a, b)
		return tostring(a.name) < tostring(b.name)
	end)

	local default_model = provider_cfg.default_model
	if not by_name[default_model] then
		return nil,
			"provider `"
				.. tostring(provider_name)
				.. "` default_model `"
				.. tostring(default_model)
				.. "` not found in discovered models"
	end

	return {
		provider = provider_name,
		kind = provider_cfg.kind,
		api_url = api_url,
		models = ordered,
		models_by_name = by_name,
		default_model = default_model,
	}
end

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
	if type(config) ~= "table" then
		return nil, "agent.json must contain a JSON object"
	end
	return config
end

local validate_provider_cfg = function(provider_name, provider_cfg)
	if type(provider_name) ~= "string" or provider_name == "" then
		return nil, "provider name must be a non-empty string"
	end
	if type(provider_cfg) ~= "table" then
		return nil, "provider `" .. tostring(provider_name) .. "` must be an object"
	end
	if type(provider_cfg.kind) ~= "string" or provider_cfg.kind == "" then
		return nil, "provider `" .. tostring(provider_name) .. "` is missing required `kind`"
	end
	if provider_cfg.kind ~= "openrouter" and provider_cfg.kind ~= "llamacpp" then
		return nil,
			"provider `" .. tostring(provider_name) .. "` has invalid `kind`; expected `openrouter` or `llamacpp`"
	end
	if provider_cfg.url ~= nil and (type(provider_cfg.url) ~= "string" or provider_cfg.url == "") then
		return nil, "provider `" .. tostring(provider_name) .. "` has invalid `url`"
	end
	if
		provider_cfg.api_key_env ~= nil
		and (type(provider_cfg.api_key_env) ~= "string" or provider_cfg.api_key_env == "")
	then
		return nil, "provider `" .. tostring(provider_name) .. "` has invalid `api_key_env`"
	end
	if type(provider_cfg.default_model) ~= "string" or provider_cfg.default_model == "" then
		return nil, "provider `" .. tostring(provider_name) .. "` is missing required `default_model`"
	end

	return true
end

local validate_user_config = function(config)
	if type(config) ~= "table" then
		return nil, "agent.json must contain a JSON object"
	end

	if config.provider ~= nil and (type(config.provider) ~= "string" or config.provider == "") then
		return nil, "`provider` must be a non-empty string"
	end
	if config.model ~= nil and (type(config.model) ~= "string" or config.model == "") then
		return nil, "`model` must be a non-empty string"
	end

	if type(config.providers) == "table" then
		for provider_name, provider_cfg in pairs(config.providers) do
			-- We don't do full validation for user overrides over default
			-- openrouter provider here, it gets validated after
			-- merge with `validate_merged_config()`.
			if provider_name ~= "openrouter" then
				local ok, err = validate_provider_cfg(provider_name, provider_cfg)
				if not ok then
					return nil, err
				end
			end
		end
	end

	return true
end

local validate_merged_config = function(config)
	if type(config.providers) ~= "table" then
		return nil, "`providers` must be an object"
	end

	local provider_count = 0
	for provider_name, provider_cfg in pairs(config.providers) do
		provider_count = provider_count + 1
		local ok, err = validate_provider_cfg(provider_name, provider_cfg)
		if not ok then
			return nil, err
		end
	end

	if provider_count == 0 then
		return nil, "at least one provider must be configured"
	end

	if type(config.provider) ~= "string" or config.provider == "" then
		return nil, "`provider` must be a non-empty string"
	end

	if not config.providers[config.provider] then
		return nil, "unknown provider: " .. tostring(config.provider)
	end

	if config.model ~= nil and (type(config.model) ~= "string" or config.model == "") then
		return nil, "`model` must be a non-empty string"
	end

	return true
end

local save_file = function(user_config)
	local home = os.getenv("HOME") or "/tmp"
	local config_dir = home .. "/.config/lilush"
	local config_path = config_dir .. "/agent.json"

	std.fs.mkdir(config_dir)

	local content = json.encode(user_config)
	if not content then
		return nil, "failed to encode config"
	end

	return std.fs.write_file(config_path, content)
end

local get_provider = function(self)
	return self.__state.provider
end

local get_model = function(self)
	return self.__state.model
end

local get_provider_config = function(self, provider_name)
	provider_name = provider_name or self.__state.provider
	return (self.cfg.providers or {})[provider_name]
end

local discover_provider_models = function(self, provider_name, opts)
	provider_name = provider_name or self.__state.provider
	opts = opts or {}

	local provider_cfg = self:get_provider_config(provider_name)
	if not provider_cfg then
		return nil, "unknown provider: " .. tostring(provider_name)
	end

	self.__state.provider_models = self.__state.provider_models or {}
	local cached = self.__state.provider_models[provider_name]
	if cached and not opts.refresh then
		return cached
	end

	local discovered, discover_err = fetch_provider_models(provider_name, provider_cfg)
	if not discovered then
		self.__state.provider_models[provider_name] = nil
		return nil, discover_err
	end

	self.__state.provider_models[provider_name] = discovered
	return discovered
end

local resolve_model = function(self, model_name, provider_name)
	model_name = model_name or self.__state.model
	provider_name = provider_name or self.__state.provider

	if type(model_name) ~= "string" or model_name == "" then
		return nil, "model name must be a non-empty string"
	end

	local provider_cfg = self:get_provider_config(provider_name)
	if not provider_cfg then
		return nil, "unknown provider: " .. tostring(provider_name)
	end

	local discovered, discover_err = self:discover_provider_models(provider_name)
	if not discovered then
		return nil, discover_err
	end

	local meta = discovered.models_by_name and discovered.models_by_name[model_name]
	if not meta then
		return nil,
			"model `" .. model_name .. "` is not available on provider `" .. tostring(provider_name) .. "` (/models)"
	end

	return {
		name = model_name,
		provider = provider_name,
		endpoint = "/chat/completions",
		context_window = meta.context_window,
		prompt_price = meta.prompt_price,
		completion_price = meta.completion_price,
		supports_text_in = meta.supports_text_in,
		supports_text_out = meta.supports_text_out,
		loaded = meta.loaded,
		kind = provider_cfg.kind,
	}
end

local set_provider = function(self, provider_name, model_name)
	local provider_cfg = (self.cfg.providers or {})[provider_name]
	if not provider_cfg then
		return nil, "unknown provider: " .. tostring(provider_name)
	end

	local discovered, discover_err = self:discover_provider_models(provider_name, { refresh = true })
	if not discovered then
		return nil, discover_err
	end

	local target_model = model_name or provider_cfg.default_model
	if not target_model then
		return nil, "provider `" .. tostring(provider_name) .. "` has no default model"
	end
	if not (discovered.models_by_name and discovered.models_by_name[target_model]) then
		return nil,
			"model `" .. tostring(target_model) .. "` is not available on provider `" .. tostring(provider_name) .. "`"
	end

	self.__state.provider = provider_name
	self.__state.model = target_model
	self.__user_cfg.provider = provider_name
	self.__user_cfg.model = target_model
	return true
end

local set_model = function(self, model_name, provider_name)
	if provider_name then
		return self:set_provider(provider_name, model_name)
	end

	local _, resolve_err = self:resolve_model(model_name, self.__state.provider)
	if resolve_err then
		return nil, resolve_err
	end

	self.__state.model = model_name
	self.__user_cfg.model = model_name
	return true
end

local refresh_provider_models = function(self, provider_name)
	provider_name = provider_name or self.__state.provider
	return self:discover_provider_models(provider_name, { refresh = true })
end

local get_sampler = function(self)
	return std.tbl.copy(self.cfg.sampler or {})
end

local set_sampler = function(self, settings)
	self.cfg.sampler = self.cfg.sampler or {}
	self.__user_cfg.sampler = self.__user_cfg.sampler or {}
	for k, v in pairs(settings or {}) do
		self.cfg.sampler[k] = v
		self.__user_cfg.sampler[k] = v
	end
end

local get_tool_config = function(self, tool_name)
	local tools = self.cfg.tools or {}
	return tools[tool_name] or { approval = "auto" }
end

local tool_needs_approval = function(self, tool_name)
	if self.__state.session_approvals[tool_name] == "auto" then
		return false
	end

	local tool_config = self:get_tool_config(tool_name)
	return tool_config.approval == "ask"
end

local set_session_approval = function(self, tool_name, approval)
	self.__state.session_approvals[tool_name] = approval
end

local clear_session_approvals = function(self)
	self.__state.session_approvals = {}
end

local get_active_prompt = function(self)
	return self.cfg.active_prompt
end

local set_active_prompt = function(self, name)
	self.cfg.active_prompt = name
	self.__user_cfg.active_prompt = name
end

local get_system_prompt = function(self)
	return self.cfg.system_prompt
end

local set_system_prompt = function(self, name)
	self.cfg.system_prompt = name
	self.__user_cfg.system_prompt = name
end

local get_index_file = function(self)
	return self.cfg.index_file
end

local get_max_tool_steps = function(self)
	return self.cfg.max_tool_steps
end

local list_providers = function(self)
	local providers = {}
	for name, _ in pairs(self.cfg.providers or {}) do
		table.insert(providers, name)
	end
	table.sort(providers)
	return providers
end

local list_models = function(self, provider_name)
	provider_name = provider_name or self.__state.provider
	if not (self.cfg.providers or {})[provider_name] then
		return {}
	end

	local discovered = self:discover_provider_models(provider_name)
	if not discovered then
		return {}
	end

	local names = {}
	for _, model in ipairs(discovered.models or {}) do
		if model and model.name then
			names[#names + 1] = model.name
		end
	end
	return names
end

local list_models_detailed = function(self, provider_name, opts)
	provider_name = provider_name or self.__state.provider
	if not (self.cfg.providers or {})[provider_name] then
		return {}
	end

	local discovered, discover_err = self:discover_provider_models(provider_name, opts)
	if not discovered then
		return {}, discover_err
	end

	local details = {}
	for _, model in ipairs(discovered.models or {}) do
		if type(model) == "table" and type(model.name) == "string" and model.name ~= "" then
			details[#details + 1] = {
				name = model.name,
				context_window = model.context_window,
				provider = provider_name,
				loaded = model.loaded,
				prompt_price = model.prompt_price,
				completion_price = model.completion_price,
				supports_text_in = model.supports_text_in,
				supports_text_out = model.supports_text_out,
			}
		end
	end
	return details
end

local save = function(self)
	return save_file(self.__user_cfg)
end

local new = function()
	local file_config, load_err = load_file()
	if load_err then
		error(load_err)
	end

	file_config = file_config or {}
	local ok, validate_err = validate_user_config(file_config)
	if not ok then
		error(validate_err)
	end

	local user_cfg = std.tbl.copy(file_config)
	local config = std.tbl.merge(std.tbl.copy(defaults), file_config)
	for provider_name, provider_cfg in pairs(config.providers or {}) do
		config.providers[provider_name] = normalize_provider_cfg(provider_name, provider_cfg)
	end

	ok, validate_err = validate_merged_config(config)
	if not ok then
		error(validate_err)
	end

	if type(config.model) ~= "string" or config.model == "" then
		local active_provider = config.providers[config.provider]
		config.model = active_provider and active_provider.default_model or nil
	end

	local instance = {
		cfg = config,
		__user_cfg = user_cfg,
		__state = {
			provider = config.provider,
			model = config.model,
			session_approvals = {},
			provider_models = {},
		},
		get_provider = get_provider,
		get_model = get_model,
		get_provider_config = get_provider_config,
		discover_provider_models = discover_provider_models,
		refresh_provider_models = refresh_provider_models,
		resolve_model = resolve_model,
		set_provider = set_provider,
		set_model = set_model,
		get_sampler = get_sampler,
		set_sampler = set_sampler,
		get_tool_config = get_tool_config,
		tool_needs_approval = tool_needs_approval,
		set_session_approval = set_session_approval,
		clear_session_approvals = clear_session_approvals,
		get_active_prompt = get_active_prompt,
		set_active_prompt = set_active_prompt,
		get_system_prompt = get_system_prompt,
		set_system_prompt = set_system_prompt,
		get_index_file = get_index_file,
		get_max_tool_steps = get_max_tool_steps,
		list_providers = list_providers,
		list_models = list_models,
		list_models_detailed = list_models_detailed,
		save = save,
	}

	local discovered, discover_err = instance:discover_provider_models(instance:get_provider(), { refresh = true })
	if not discovered then
		error(discover_err)
	end

	if not instance:get_model() or instance:get_model() == "" then
		instance.__state.model = discovered.default_model
	end

	local _, resolve_err = instance:resolve_model(instance:get_model(), instance:get_provider())
	if resolve_err then
		error(resolve_err)
	end

	return instance
end

local prompts_dir = function()
	local home = os.getenv("HOME") or "/tmp"
	return home .. "/.config/lilush/agent/prompts"
end

local system_prompts_dir = function()
	local home = os.getenv("HOME") or "/tmp"
	return home .. "/.config/lilush/agent/system_prompts"
end

local list_prompt_files = function(dir)
	local entries = std.fs.list_dir(dir)
	if not entries then
		return {}
	end
	local names = {}
	for _, name in ipairs(entries) do
		if name ~= "." and name ~= ".." then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names
end

local load_prompt_file = function(dir, name)
	if not name or name == "" then
		return nil
	end
	return std.fs.read_file(dir .. "/" .. name)
end

local list_user_prompts = function()
	return list_prompt_files(prompts_dir())
end

local load_user_prompt = function(name)
	return load_prompt_file(prompts_dir(), name)
end

local list_system_prompts = function()
	return list_prompt_files(system_prompts_dir())
end

local load_system_prompt = function(name)
	return load_prompt_file(system_prompts_dir(), name)
end

return {
	new = new,
	defaults = defaults,
	list_user_prompts = list_user_prompts,
	load_user_prompt = load_user_prompt,
	list_system_prompts = list_system_prompts,
	load_system_prompt = load_system_prompt,
}
