-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local term = require("term")
local widgets = require("term.widgets")
local llm = require("llm")
local std = require("std")
local json = require("cjson.safe")
local theme = require("shell.theme")
local text = require("text")
local tss_gen = require("term.tss")

local render = function(self, content, indent, style)
	local style = style or theme.renderer.kat
	local mode = self.conf.renderer.mode.selected
	local out
	local conf = {
		global_indent = indent,
		wrap = self.conf.renderer.wrap,
		codeblock_wrap = self.conf.renderer.codeblock_wrap,
		hide_links = self.conf.renderer.hide_links,
	}
	if mode == "markdown" then
		out = text.render_markdown(content, style, conf)
	elseif mode == "djot" then
		out = text.render_djot(content, style, conf)
	else
		local opts = { raw = {}, simple = { global_indent = 2, wrap = 80 } }
		out = text.render_text(content, opts[mode], conf) .. "\r\n"
	end
	return out
end

local choose_preset = function(self, combo)
	local presets = self.store:get_hash_key("llm", "presets.json", true)
	if not presets then
		return false
	end
	local content = { title = "Choose a preset", options = std.sort_keys(presets) }
	term.switch_screen("alt")
	term.hide_cursor()
	local choice = widgets.switcher(content, theme.widgets.switcher.llm)
	term.switch_screen("main")
	term.show_cursor()
	if choice == "" then
		self:show_conversation()
		return true
	end
	local preset = presets[choice]
	self.preset = choice
	if preset.generation then
		for k, v in pairs(preset.generation) do
			if k == "backend" then
				self.conf.generation.backend.selected = v
			elseif k == "mode" then
				self.conf.generation.mode.selected = v
			else
				self.conf.generation[k] = v
			end
		end
	end
	if preset.sys_prompt then
		if preset.sys_prompt.prompt then
			self.conf.sys_prompt.user.prompt = preset.sys_prompt.prompt
			self.conf.sys_prompt.selected = "user"
		else
			self.conf.sys_prompt.selected = preset.sys_prompt
		end
	end
	if preset.prompt_template then
		if type(preset.prompt_template) == "string" then
			self.conf.prompt_template.selected = preset.prompt_template
		else
			self.conf.prompt_template.user = preset.prompt_template
			self.conf.prompt_template.selected = "user"
		end
	end
	if preset.api_url then
		self.conf.api_url = preset.api_url
	end
	return self:flush()
end

local load_llm_config = function(store)
	local user_prompt_template = store:get_hash_key("llm", "prompt_template.json")
		or { prefix = "", infix = "", suffix = "" }
	local sys_prompt_text = store:get_hash_key("llm", "sys_prompt.txt") or ""

	local settings = {
		api_url = "http://127.0.0.1:8013",
		generation = {
			stop_conditions = "",
			temperature = 0.5,
			tokens = 512,
			top_k = 40,
			top_p = 0.75,
			min_p = 0,
			hide_special_tokens = true,
			repetition_penalty = 1.05,
			mode = {
				selected = "chat",
				options = { "chat", "completion" },
			},
			backend = {
				selected = "exl2",
				options = { "exl2", "mamba", "llamacpp", "Claude", "MistralAI", "OpenAI" },
			},
		},
		renderer = {
			mode = { selected = "djot", options = { "djot", "markdown", "raw" } },
			wrap = 120,
			codeblock_wrap = true,
			user_indent = 2,
			llm_indent = 8,
			hide_links = false,
		},
		sys_prompt = {
			selected = "null",
			null = {
				prompt = "",
			},
			user = { prompt = sys_prompt_text },
		},
		prompt_template = {
			selected = "null",
			null = {
				prefix = "",
				infix = "",
				suffix = "",
			},
			user = user_prompt_template,
		},
		models = {
			OpenAI = {
				selected = "gpt-3.5-turbo",
				options = { "gpt-3.5-turbo", "gpt-4-turbo" },
			},
			MistralAI = {
				selected = "mistral-small-latest",
				options = { "mistral-small-latest", "mistral-medium-latest", "mistral-large-latest" },
			},
			Claude = {
				selected = "claude-3-haiku-20240307",
				options = { "claude-3-haiku-20240307", "claude-3-sonnet-20240229", "claude-3-opus-20240229" },
			},
			exl2 = {},
			llamacpp = {},
			mamba = {},
		},
		autosave = false,
	}
	return settings
end

local convert_to_mamba_fmt = function(messages, completion)
	if completion then
		return { { kind = "spt", token = "<TXT>", content = messages[#messages].content } }
	end
	local msgs = { { kind = "spt", token = "<CHAT>" } }
	for i, msg in ipairs(messages) do
		if msg.role == "system" then
			table.insert(msgs, { kind = "spt", token = "<SYS>", content = msg.content })
			table.insert(msgs, { kind = "spt", token = "</SYS>" })
		elseif msg.role == "user" then
			table.insert(msgs, { kind = "spt", token = "<QUERY>", content = msg.content })
			table.insert(msgs, { kind = "spt", token = "</QUERY>" })
		elseif msg.role == "assistant" then
			table.insert(msgs, { kind = "spt", token = "<REPLY>", content = msg.content })
			table.insert(msgs, { kind = "spt", token = "</REPLY>" })
		end
	end
	table.insert(msgs, { kind = "spt", token = "<REPLY>" })
	return msgs
end

local run = function(self)
	local user_message = self.input:render()
	if #user_message == 0 then
		return 0
	end

	local resp, err
	local api_url = self.chats_meta[self.chat_idx].api_url
	local backend = self.chats_meta[self.chat_idx].backend
	local mode = self.chats_meta[self.chat_idx].mode
	local uuid = self.chats_meta[self.chat_idx].uuid
	local sampler = self.chats_meta[self.chat_idx].sampler
	local client = llm.new(backend, api_url)

	table.insert(self.chats[self.chat_idx], { role = "user", content = user_message })
	local model = "local"
	if self.conf.models[backend] then
		model = self.conf.models[backend].selected or model
	end
	local messages = self.chats[self.chat_idx]
	local completion = false
	if mode == "completion" then
		completion = true
	end
	if not backend:match("^%u") then -- local backend
		if backend == "mamba" then
			messages = convert_to_mamba_fmt(messages, completion)
		else
			messages =
				llm.render_prompt_tmpl(self.chats_meta[self.chat_idx].prompt_template, self.chats[self.chat_idx], true)
		end
	end
	local stop_conditions = {}
	for sc in self.conf.generation.stop_conditions:gmatch("([^,]+),?") do
		table.insert(stop_conditions, sc)
	end
	resp, err = client:complete(model, messages, sampler, stop_conditions, uuid)

	if resp then
		local text = resp.text:gsub("^%s", "")
		local price = resp.price or 0
		self.total_cost = self.total_cost + price
		self.rate = resp.rate or 0
		self.chats_meta[self.chat_idx].ctx = resp.ctx or resp.tokens
		self.chats_meta[self.chat_idx].model = resp.model
		self.chats_meta[self.chat_idx].backend = resp.backend
		table.insert(self.chats[self.chat_idx], {
			role = "assistant",
			content = text,
			backend = resp.backend,
			model = resp.model,
			rate = self.rate,
		})
		term.write("\n" .. self:render(text, self.conf.renderer.indent) .. "\r\n")
		self.input.prompt:set({
			ctx = self.chats_meta[self.chat_idx].ctx,
			total_cost = self.total_cost,
			rate = self.rate,
			backend = resp.backend,
			model = resp.model,
		})
		if self.conf.autosave then
			self:save()
		end
		if price ~= 0 then
			self.store:incr_hash_key("llm/costs", resp.backend, price)
		end
	else
		return 255, err
	end
	return 0
end

local sync_meta = function(self)
	self.chats_meta[self.chat_idx].prompt_template = self.conf.prompt_template[self.conf.prompt_template.selected]
	self.chats_meta[self.chat_idx].sys_prompt = self.conf.sys_prompt[self.conf.sys_prompt.selected]
	self.chats_meta[self.chat_idx].mode = self.conf.generation.mode.selected
	self.chats_meta[self.chat_idx].backend = self.conf.generation.backend.selected
	self.chats_meta[self.chat_idx].api_url = self.conf.api_url
	self.chats_meta[self.chat_idx].sampler = {
		temperature = self.conf.generation.temperature,
		hide_special_tokens = self.conf.generation.hide_special_tokens,
		top_k = self.conf.generation.top_k,
		top_p = self.conf.generation.top_p,
		min_p = self.conf.generation.min_p,
		repetition_penalty = self.conf.generation.repetition_penalty,
		max_new_tokens = self.conf.generation.tokens,
	}
end

local sync_conf = function(self)
	self.conf.generation.temperature = self.chats_meta[self.chat_idx].sampler.temperature
	self.conf.generation.top_k = self.chats_meta[self.chat_idx].sampler.top_k
	self.conf.generation.top_p = self.chats_meta[self.chat_idx].sampler.top_p
	self.conf.generation.min_p = self.chats_meta[self.chat_idx].sampler.min_p
	self.conf.generation.hide_special_tokens = self.chats_meta[self.chat_idx].sampler.hide_special_tokens
	self.conf.generation.repetition_penalty = self.chats_meta[self.chat_idx].sampler.repetition_penalty
	self.conf.generation.tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens
	self.conf.prompt_template.user = self.chats_meta[self.chat_idx].prompt_template
	self.conf.sys_prompt.user = self.chats_meta[self.chat_idx].sys_prompt
	self.conf.prompt_template.selected = "user"
	self.conf.sys_prompt.selected = "user"
	self.conf.api_url = self.chats_meta[self.chat_idx].api_url
end

local flush = function(self, combo)
	local sys_prompt = self:get_system_prompt()
	if sys_prompt ~= "" then
		self.chats[self.chat_idx] = { { role = "system", content = sys_prompt } }
	else
		self.chats[self.chat_idx] = {}
	end
	self:sync_meta()
	local backend = self.chats_meta[self.chat_idx].backend
	if not backend:match("^%u") then
		-- If it's OpenAI/MistralAI/Anthropic we better rely on the hardcoded list
		-- of models. In all other cases we want to fetch the list of models.
		local client = llm.new(backend, self.chats_meta[self.chat_idx].api_url)
		local models = client:models() or {}
		if models.models then
			models = models.models
		end
		self.conf.models[backend] = { options = models, selected = models[1] }
	end
	self.chats_meta[self.chat_idx].ctx = 0
	self.chats_meta[self.chat_idx].model = self.conf.models[backend].selected
	self.rate = 0
	self.input:flush()
	self.input.prompt:set({
		backend = self.chats_meta[self.chat_idx].backend,
		model = self.chats_meta[self.chat_idx].model,
		ctx = 0,
		preset = self.preset or "",
		rate = 0,
		chat = self.chat_idx,
		temperature = self.chats_meta[self.chat_idx].sampler.temperature,
		tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens,
		endpoint = self.chats_meta[self.chat_idx].mode,
		prompt = self.conf.prompt_template.selected,
	})
	term.clear()
	term.go(1, 1)
	return true
end

local save = function(self)
	local msg_count = #self.chats[self.chat_idx]
	if msg_count > 0 then
		local uuid = self.chats_meta[self.chat_idx].uuid
		local model = self.chats_meta[self.chat_idx].model
		local name = model .. ": " .. os.date()
		if self.chats_meta[self.chat_idx].name then
			name = self.chats_meta[self.chat_idx].name
		else
			self.chats_meta[self.chat_idx].name = name
		end
		self.store:set_hash_key("llm/chats", name, {
			conversation = self.chats[self.chat_idx],
			prompt_template = self.conf.prompt_template[self.conf.prompt_template.selected],
			sys_prompt = self.conf.sys_prompt[self.conf.sys_prompt.selected],
			sampler = self.chats_meta[self.chat_idx].sampler,
			backend = self.chats_meta[self.chat_idx].backend,
			ctx = self.chats_meta[self.chat_idx].ctx,
			mode = self.chats_meta[self.chat_idx].mode,
			model = self.chats_meta[self.chat_idx].model,
			api_url = self.chats_meta[self.chat_idx].api_url,
			uuid = self.chats_meta[self.chat_idx].uuid,
		}, true)
	end
end

local settings = function(self, combo)
	term.hide_cursor()
	local backend = self.conf.generation.backend.selected
	widgets.settings(self.conf, "LLM Mode Settings", theme.widgets.settings.llm, theme.widgets.switcher.llm, 3, 5)
	self.input.prompt:set({
		prompt = self.conf.prompt_template.selected,
		tokens = self.conf.generation.tokens,
		temperature = self.conf.generation.temperature,
		backend = self.conf.generation.backend.selected,
		endpoint = self.conf.generation.mode.selected,
	})
	if backend ~= self.conf.generation.backend.selected then
		self.preset = nil
		local model = ""
		if self.conf.models[self.conf.generation.backend.selected] then
			model = self.conf.models[self.conf.generation.backend.selected].selected or ""
		end
		self.chats_meta[self.chat_idx].model = model
		self.input.prompt:set({ preset = "", model = model })
	end
	self:sync_meta()
	term.clear()
	term.go(1, 1)
	term.show_cursor()
	self:show_conversation()
	return true
end

local change_renderer = function(self, combo)
	local content = { title = "Choose text rendering mode", options = self.conf.renderer.mode.options }
	term.hide_cursor()
	term.switch_screen("alt")
	local choice = widgets.switcher(content, theme.widgets.switcher.llm)
	term.switch_screen("main")
	term.show_cursor()
	if choice ~= "" then
		self.conf.renderer.mode.selected = choice
	end
	self:show_conversation()
	return true
end

local load_conversation = function(self, combo)
	local content = { title = "Choose a chat to load", options = {} }
	local chats = self.store:list_hash_keys("llm/chats") or {}
	for i, v in ipairs(chats) do
		table.insert(content.options, v)
	end
	if #content.options == 0 then
		return false
	end
	term.switch_screen("alt")
	term.hide_cursor()
	local choice = widgets.switcher(content, theme.widgets.switcher.llm)
	term.switch_screen("main")
	term.show_cursor()
	if choice == "" then
		self:show_conversation()
		return true
	end
	local chat, err = self.store:get_hash_key("llm/chats", choice, true)
	if err then
		return nil, "can't load chat: " .. tostring(err)
	end
	if chat then
		self.chats[self.chat_idx] = chat.conversation
		self.chats_meta[self.chat_idx].model = chat.model
		self.chats_meta[self.chat_idx].api_url = chat.api_url
		self.chats_meta[self.chat_idx].uuid = chat.uuid
		self.chats_meta[self.chat_idx].ctx = chat.ctx
		self.chats_meta[self.chat_idx].sampler = chat.sampler
		self.chats_meta[self.chat_idx].prompt_template = chat.prompt_template
		self.chats_meta[self.chat_idx].sys_prompt = chat.sys_prompt
		self:sync_conf()
		self:show_conversation()
		self.input.prompt:set({
			ctx = self.chats_meta[self.chat_idx].ctx,
		})
		return true
	end
	return nil, tostring(err)
end

local adjust_temperature = function(self, combo)
	local t = self.chats_meta[self.chat_idx].sampler.temperature
	if combo == "Alt+Up" then
		if t < 0.9 then
			self.chats_meta[self.chat_idx].sampler.temperature = t + 0.1
		else
			self.chats_meta[self.chat_idx].sampler.temperature = 1
		end
	else
		if t > 0.1 then
			-- have to do this madness because of weird float arithmetics...
			if t < 0.2 then
				self.chats_meta[self.chat_idx].sampler.temperature = 0
			else
				self.chats_meta[self.chat_idx].sampler.temperature = t - 0.1
			end
		else
			self.chats_meta[self.chat_idx].sampler.temperature = 0
		end
	end
	self.input.prompt:set({
		temperature = self.chats_meta[self.chat_idx].sampler.temperature,
	})
	self.conf.generation.temperature = self.chats_meta[self.chat_idx].sampler.temperature
	term.clear_line(2)
	term.move("column")
	return true
end

local adjust_tokens = function(self, combo)
	local tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens
	if combo == "Alt+Left" then
		if tokens > 64 then
			self.chats_meta[self.chat_idx].sampler.max_new_tokens = tokens - 64
		end
	else
		if tokens < 16384 then
			self.chats_meta[self.chat_idx].sampler.max_new_tokens = tokens + 64
		end
	end
	self.input.prompt:set({
		tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens,
	})
	self.conf.generation.tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens
	term.clear_line(2)
	term.move("column")
	return true
end

local show_conversation = function(self, combo)
	local tss = tss_gen.new(theme)
	local msg_count = #self.chats[self.chat_idx]
	if msg_count > 0 then
		term.clear()
		term.go(1, 1)
		for i, m in ipairs(self.chats[self.chat_idx]) do
			if m.role == "system" then
				local sys_prompt = "```System_Prompt\n\n" .. m.content .. "\n```"
				term.write(text.render_djot(sys_prompt, theme.renderer.llm.sys_prompt) .. "\n")
			elseif m.role == "user" then
				local user_msg = m.content
				term.write("\r\n" .. self:render(user_msg, self.conf.renderer.user_indent, theme.renderer.llm.user))
			elseif m.role == "assistant" then
				term.write("\r\n" .. self:render(m.content, self.conf.renderer.llm_indent))
			end
		end
		term.write("\r\n")
		return true
	end
end

local switch_chat = function(self, combo)
	if combo == "Ctrl+Up" then
		if self.chat_idx > 1 then
			self.chat_idx = self.chat_idx - 1
			self.input.prompt:set({
				ctx = self.chats_meta[self.chat_idx].ctx,
				chat = self.chat_idx,
				backend = self.chats_meta[self.chat_idx].backend,
				model = self.chats_meta[self.chat_idx].model,
				tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens,
				temperature = self.chats_meta[self.chat_idx].sampler.temperature,
			})
			self:show_conversation()
			return true
		end
		return false
	end
	if self.chat_idx < #self.chats then
		self.chat_idx = self.chat_idx + 1
		self.input.prompt:set({
			ctx = self.chats_meta[self.chat_idx].ctx,
			chat = self.chat_idx,
			backend = self.chats_meta[self.chat_idx].backend,
			model = self.chats_meta[self.chat_idx].model,
			tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens,
			temperature = self.chats_meta[self.chat_idx].sampler.temperature,
		})
		self:show_conversation()
		return true
	elseif #self.chats[self.chat_idx] > 2 then
		local backend = self.chats_meta[self.chat_idx].backend
		local mode = self.chats_meta[self.chat_idx].mode
		local sampler = self.chats_meta[self.chat_idx].sampler
		self.chat_idx = self.chat_idx + 1
		self.chats_meta[self.chat_idx] = {}
		self.chats_meta[self.chat_idx].backend = backend
		self.chats_meta[self.chat_idx].mode = mode
		self.chats_meta[self.chat_idx].sampler = sampler
		self:flush()
		return true
	end
end

local get_system_prompt = function(self)
	local sys_prompt = self.conf.sys_prompt[self.conf.sys_prompt.selected].prompt or ""
	return sys_prompt
end

local get_saved_costs = function(self)
	local cost = 0
	local backends = self.store:list_hash_keys("llm/costs")
	for _, backend in ipairs(backends) do
		local c = self.store:get_hash_key("llm/costs", backend)
		c = tonumber(c) or 0
		cost = cost + c
	end
	return cost
end

local new = function(input, prompt, store)
	local conf = load_llm_config(store)

	local mode = {
		combos = {
			["Ctrl+F"] = flush,
			["Ctrl+Y"] = save,
			["Ctrl+T"] = change_renderer,
			["Ctrl+Up"] = switch_chat,
			["Ctrl+Down"] = switch_chat,
			["Alt+Up"] = adjust_temperature,
			["Alt+Down"] = adjust_temperature,
			["Alt+Left"] = adjust_tokens,
			["Alt+Right"] = adjust_tokens,
			["Ctrl+S"] = settings,
			["Ctrl+O"] = load_conversation,
			["Ctrl+R"] = show_conversation,
			["Ctrl+P"] = choose_preset,
		},
		store = store,
		show_conversation = show_conversation,
		get_system_prompt = get_system_prompt,
		sync_meta = sync_meta,
		sync_conf = sync_conf,
		save = save,
		flush = flush,
		render = render,
		run = run,
		get_saved_costs = get_saved_costs,
		input = input,
		total_cost = 0,
		rate = 0,
		chat_idx = 1,
		chats_meta = {
			{
				uuid = std.uuid(),
				backend = conf.generation.backend.selected,
				model = conf.models.OpenAI.selected,
				ctx = 0,
				sampler = {
					temperature = conf.generation.temperature,
					tokens = conf.generation.tokens,
					top_k = conf.generation.top_k,
					top_p = conf.generation.top_p,
					min_p = conf.generation.min_p,
					repetition_penalty = conf.generation.repetition_penalty,
				},
			},
		},
		chats = { {} },
	}
	mode.conf = conf
	mode.total_cost = mode:get_saved_costs()
	mode.input.prompt = prompt
	mode.input.prompt:set({ total_cost = mode.total_cost })
	mode:flush()
	return mode
end

return { new = new }
