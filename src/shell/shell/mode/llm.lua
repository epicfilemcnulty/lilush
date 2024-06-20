-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local term = require("term")
local widgets = require("term.widgets")
local llm = require("llm")
local std = require("std")
local json = require("cjson.safe")
local theme = require("shell.theme")
local storage = require("storage")
local text = require("text")
local style = require("term.tss")

local render = function(self, content, indent)
	local rss = theme.renderer.kat
	local mode = self.conf.renderer.mode.selected
	local out
	local conf = {
		global_indent = indent,
		wrap = self.conf.renderer.wrap,
		codeblock_wrap = self.conf.renderer.codeblock_wrap,
		hide_links = self.conf.renderer.hide_links,
	}
	if mode == "markdown" then
		out = text.render_markdown(content, rss, conf)
	elseif mode == "djot" then
		out = text.render_djot(content, rss, conf)
	else
		rss = { global_indent = 0, wrap = 120 }
		out = text.render_text(content, rss) .. "\r\n"
	end
	return out
end

local choose_preset = function(self, combo)
	local presets = self.store:get_hash_key("llm", "presets.json", true)
	if not presets then
		return false
	end
	local content = { title = "Choose a preset", options = std.tbl.sort_keys(presets) }
	term.switch_screen("alt", true)
	term.hide_cursor()
	local choice = widgets.switcher(content, theme.widgets.llm)
	term.switch_screen("main", nil, true)
	term.show_cursor()
	if choice == "" then
		self:show_conversation()
		return true
	end
	local preset = presets[choice]
	self.preset = choice
	local custom_api_url = false
	for k, v in pairs(preset) do
		if k == "backend" then
			self.conf.backend.selected = v
		elseif k == "sys_prompt" then
			self.conf.sys_prompt.selected = v
		elseif k == "prompt_template" then
			self.conf.prompt_template.selected = preset.prompt_template
		elseif k == "api_url" then
			self.conf.api_url = v
			custom_api_url = true
		elseif k == "sampler" then
			local user_samplers = self.store:get_hash_key("llm", "samplers.json", true)
			if user_samplers and user_samplers[v] then
				for k1, v1 in pairs(user_samplers[v]) do
					self.conf.sampler[k1] = v1
				end
			end
		end
	end
	if not custom_api_url then
		-- if custom api_url was already set before
		-- we want to reset it.
		self.conf.api_url = nil
	end
	return self:flush()
end

local load_llm_config = function(store)
	local user_prompt_templates = store:get_hash_key("llm", "prompt_templates.json", true) or {}
	local user_sys_prompts = store:get_hash_key("llm", "sys_prompts.json", true) or {}

	local settings = {
		sampler = {
			stop_conditions = {},
			temperature = 0.75,
			tokens = 1024,
			top_k = 40,
			top_p = 0.75,
			min_p = 0,
			add_bos = true,
			add_eos = false,
			encode_special_tokens = true,
			hide_special_tokens = true,
			repetition_penalty = 1.05,
		},
		backend = {
			selected = "exl2",
			options = { "exl2", "mamba", "tf", "llamacpp", "Claude", "MistralAI", "OpenAI" },
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
			null = "",
		},
		prompt_template = {
			selected = "null",
			null = {
				prefix = "",
				infix = "",
				suffix = "",
			},
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
			tf = {},
		},
		autosave = false,
		attach_as_codeblock = false,
	}
	for k, v in pairs(user_prompt_templates) do
		settings.prompt_template[k] = v
	end
	for k, v in pairs(user_sys_prompts) do
		settings.sys_prompt[k] = v
	end
	local sys_prompt_text = store:get_hash_key("llm", "sys_prompt.txt")
	if sys_prompt_text then
		settings.sys_prompt.user = sys_prompt_text
	end
	return settings
end

local run = function(self)
	local user_message = self.input:render()
	if #user_message == 0 then
		return 0
	end

	local resp, err
	local api_url = self.chats_meta[self.chat_idx].api_url
	local backend = self.chats_meta[self.chat_idx].backend
	local uuid = self.chats_meta[self.chat_idx].uuid
	local sampler = self.chats_meta[self.chat_idx].sampler
	local client = llm.new(backend, api_url)

	if self.attachment and self.conf.attach_as_codeblock then
		local previous_message = self.chats[self.chat_idx][#self.chats[self.chat_idx]].content
		local msg = "```\n" .. previous_message .. "\n```\n\n" .. user_message
		self.chats[self.chat_idx][#self.chats[self.chat_idx]].content = msg
		self.attachment = false
	else
		table.insert(self.chats[self.chat_idx], { role = "user", content = user_message })
	end
	local model = "local"
	if self.conf.models[backend] then
		model = self.conf.models[backend].selected or model
	end
	local messages = self.chats[self.chat_idx]
	if not backend:match("^%u") then -- local backend
		local prompt_template = self.conf.prompt_template[self.chats_meta[self.chat_idx].prompt_template]
		if backend == "mamba" then
			prompt_template = "mamba"
		end
		messages = llm.render_prompt_tmpl(prompt_template, self.chats[self.chat_idx], true)
		if os.getenv("LILUSH_DEBUG") then
			std.tbl.print(messages)
		end
	end
	resp, err = client:complete(model, messages, sampler, self.conf.sampler.stop_conditions, uuid)

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
	self.chats_meta[self.chat_idx].prompt_template = self.conf.prompt_template.selected
	self.chats_meta[self.chat_idx].sys_prompt = self.conf.sys_prompt.selected
	self.chats_meta[self.chat_idx].backend = self.conf.backend.selected
	self.chats_meta[self.chat_idx].api_url = self.conf.api_url
	self.chats_meta[self.chat_idx].sampler = {
		temperature = self.conf.sampler.temperature,
		hide_special_tokens = self.conf.sampler.hide_special_tokens,
		encode_special_tokens = self.conf.sampler.encode_special_tokens,
		top_k = self.conf.sampler.top_k,
		top_p = self.conf.sampler.top_p,
		min_p = self.conf.sampler.min_p,
		repetition_penalty = self.conf.sampler.repetition_penalty,
		add_bos = self.conf.sampler.add_bos,
		add_eos = self.conf.sampler.add_eos,
		max_new_tokens = self.conf.sampler.tokens,
	}
end

local sync_conf = function(self)
	self.conf.sampler.temperature = self.chats_meta[self.chat_idx].sampler.temperature
	self.conf.sampler.top_k = self.chats_meta[self.chat_idx].sampler.top_k
	self.conf.sampler.top_p = self.chats_meta[self.chat_idx].sampler.top_p
	self.conf.sampler.min_p = self.chats_meta[self.chat_idx].sampler.min_p
	self.conf.sampler.hide_special_tokens = self.chats_meta[self.chat_idx].sampler.hide_special_tokens
	self.conf.sampler.repetition_penalty = self.chats_meta[self.chat_idx].sampler.repetition_penalty
	self.conf.sampler.tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens
	self.conf.prompt_template.selected = self.chats_meta[self.chat_idx].prompt_template
	self.conf.sys_prompt.selected = self.chats_meta[self.chat_idx].sys_prompt
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
		local name = model .. "_" .. os.date("%s")
		if self.chats_meta[self.chat_idx].name then
			name = self.chats_meta[self.chat_idx].name
		else
			self.chats_meta[self.chat_idx].name = name
		end
		self.store:set_hash_key("llm/chats", name, {
			conversation = self.chats[self.chat_idx],
			prompt_template_name = self.conf.prompt_template.selected,
			sys_prompt_name = self.conf.sys_prompt.selected,
			sampler = self.chats_meta[self.chat_idx].sampler,
			backend = self.chats_meta[self.chat_idx].backend,
			ctx = self.chats_meta[self.chat_idx].ctx,
			model = self.chats_meta[self.chat_idx].model,
			api_url = self.chats_meta[self.chat_idx].api_url,
			uuid = self.chats_meta[self.chat_idx].uuid,
			attach_as_codeblock = self.conf.attach_as_codeblock,
		}, true)
	end
end

local settings = function(self, combo)
	term.switch_screen("alt", true)
	term.hide_cursor()
	local backend = self.conf.backend.selected
	widgets.settings(self.conf, "LLM Mode Settings", theme.widgets.llm, 3, 5)
	self.input.prompt:set({
		prompt = self.conf.prompt_template.selected,
		tokens = self.conf.sampler.tokens,
		temperature = self.conf.sampler.temperature,
		backend = self.conf.backend.selected,
	})
	if backend ~= self.conf.backend.selected then
		self.preset = nil
		local model = ""
		if self.conf.models[self.conf.backend.selected] then
			model = self.conf.models[self.conf.backend.selected].selected or ""
		end
		self.chats_meta[self.chat_idx].model = model
		self.input.prompt:set({ preset = "", model = model })
	end
	self:sync_meta()
	term.switch_screen("main", nil, true)
	term.clear()
	term.go(1, 1)
	term.show_cursor()
	self:show_conversation()
	return true
end

local change_renderer = function(self, combo)
	local content = { title = "Choose text rendering mode", options = self.conf.renderer.mode.options }
	term.hide_cursor()
	term.switch_screen("alt", true)
	local choice = widgets.switcher(content, theme.widgets.llm)
	term.switch_screen("main", nil, true)
	term.show_cursor()
	if choice ~= "" then
		self.conf.renderer.mode.selected = choice
	end
	self:show_conversation()
	return true
end

local change_sampler = function(self, combo)
	local user_samplers = self.store:get_hash_key("llm", "samplers.json", true)
	local content = { title = "Choose sampler preset", options = std.tbl.sort_keys(user_samplers) }
	term.hide_cursor()
	term.switch_screen("alt", true)
	local choice = widgets.switcher(content, theme.widgets.llm)
	term.switch_screen("main", nil, true)
	term.show_cursor()
	if choice ~= "" then
		local custom_stop_conditions = false
		for k, v in pairs(user_samplers[choice]) do
			if k == "stop_conditions" then
				custom_stop_conditions = true
			end
			self.conf.sampler[k] = v
		end
		if not custom_stop_conditions then
			self.conf.sampler.stop_conditions = {}
		end
	end
	return self:flush()
end

local attach_file = function(self, combo)
	term.hide_cursor()
	term.switch_screen("alt", true)
	local chosen_file = widgets.file_chooser(
		"Choose a file to attach",
		os.getenv("HOME"),
		theme.widgets.llm,
		{ mode = "[fdl]", select = "f" }
	)
	term.switch_screen("main", nil, true)
	term.show_cursor()
	if chosen_file then
		local file_content = std.fs.read_file(chosen_file)
		local file_size = #file_content / 1024
		table.insert(self.chats[self.chat_idx], {
			role = "user",
			content = file_content,
			file = chosen_file,
			size = file_size,
		})
		self.attachment = true
	end
	self:show_conversation()
	return true
end

local load_model = function(self, combo)
	term.hide_cursor()
	term.switch_screen("alt", true)
	local model_dir =
		widgets.file_chooser("Choose model dir", "/storage/models", theme.widgets.llm, { mode = "d", select = "d" })
	if not model_dir then
		term.switch_screen("main", nil, true)
		term.show_cursor()
		self:show_conversation()
		return true
	end
	local alias = model_dir:match("([^/]+)/?$")
	local model_conf = {
		model_type = "exl2",
		context_length = 0,
		model_alias = alias,
		model_dir = model_dir,
		dynamic = false,
	}
	widgets.settings(model_conf, "Set model options", theme.widgets.llm, 3, 5)
	local client = llm.new(model_conf.model_type)
	term.clear()
	term.go(1, 1)
	term.write("LOADING...")
	local progress = std.progress_icon()
	local ok, err = client:load_model(model_conf)
	progress.stop()
	if ok then
		term.write("\r\nLOADED")
		std.sleep(1)
	end
	term.switch_screen("main", nil, true)
	term.show_cursor()
	self:show_conversation()
	return true
end

local unload_model = function(self, combo)
	local client = llm.new(self.conf.backend.selected)
	local models = client:models()
	if not models then
		self:show_conversation()
		return true
	end
	term.switch_screen("alt", true)
	term.hide_cursor()
	local choice = widgets.switcher({ title = "Select modelt to unload", options = models.models }, theme.widgets.llm)
	if choice == "" then
		term.switch_screen("main", nil, true)
		term.show_cursor()
		self:show_conversation()
		return true
	end
	term.clear()
	term.go(1, 1)
	term.write("UNLOADING...")
	local progress = std.progress_icon()
	local ok = client:unload_model(choice)
	progress.stop()
	if ok then
		term.write("\r\nUNLOADED")
		std.sleep(1)
	end
	term.switch_screen("main", nil, true)
	term.show_cursor()
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
	term.switch_screen("alt", true)
	term.hide_cursor()
	local choice = widgets.switcher(content, theme.widgets.llm)
	term.switch_screen("main", nil, true)
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
		self.chats_meta[self.chat_idx].prompt_template = chat.prompt_template_name
		self.chats_meta[self.chat_idx].sys_prompt = chat.sys_prompt_name
		self.conf.attach_as_codeblock = chat.attach_as_codeblock
		self.conf.backend.selected = chat.backend
		self:sync_conf()
		self:show_conversation()
		self.input.prompt:set({
			ctx = self.chats_meta[self.chat_idx].ctx,
			model = self.chats_meta[self.chat_idx].model,
			backend = self.conf.backend.selected,
		})
		return true
	end
	return nil, tostring(err)
end

local adjust_temperature = function(self, combo)
	local t = self.chats_meta[self.chat_idx].sampler.temperature
	if combo == "ALT+UP" then
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
	self.conf.sampler.temperature = self.chats_meta[self.chat_idx].sampler.temperature
	term.clear_line(2)
	term.move("column")
	return true
end

local adjust_tokens = function(self, combo)
	local tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens
	if combo == "ALT+LEFT" then
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
	self.conf.sampler.tokens = self.chats_meta[self.chat_idx].sampler.max_new_tokens
	term.clear_line(2)
	term.move("column")
	return true
end

local show_conversation = function(self, combo)
	local tss = style.new(theme)
	local msg_count = #self.chats[self.chat_idx]
	term.clear()
	term.go(1, 1)
	if msg_count > 0 then
		for i, m in ipairs(self.chats[self.chat_idx]) do
			if m.role == "system" then
				local sys_prompt = "```System_Prompt\n\n" .. m.content .. "\n```"
				term.write(text.render_djot(sys_prompt, theme.renderer.llm_sys_prompt) .. "\n")
			elseif m.role == "user" then
				local user_msg = m.content
				if m.file then
					user_msg = table.concat(
						std.tbl.pipe_table(
							{ "  Attached file", "Size (KB)" },
							{ { "`" .. m.file .. "`", string.format("%.2f", m.size) } }
						),
						"\n"
					)
					if self.conf.attach_as_codeblock and m.content then
						local query = m.content:match("^```\n.*\n```\n\n(.*)$") or ""
						user_msg = user_msg .. "\n\n" .. query
					end
				end
				term.write("\r\n" .. self:render("::: user\n" .. user_msg .. "\n:::\n", self.conf.renderer.user_indent))
			elseif m.role == "assistant" then
				term.write("\r\n" .. self:render(m.content, self.conf.renderer.llm_indent))
			end
		end
		term.write("\r\n")
		local y, x = term.window_size()
		local l, c = term.cursor_position()
		self.input.__config.l = l
		self.input.__config.c = 1
		return true
	end
end

local get_system_prompt = function(self)
	local sys_prompt = self.conf.sys_prompt[self.conf.sys_prompt.selected] or ""
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

local new = function(input)
	local store = storage.new()
	local conf = load_llm_config(store)

	local mode = {
		combos = {
			["CTRL+f"] = flush,
			["CTRL+y"] = save,
			["CTRL+t"] = change_sampler,
			["CTRL+u"] = unload_model,
			["CTRL+DOWN"] = load_model,
			["CTRL+UP"] = attach_file,
			["ALT+UP"] = adjust_temperature,
			["ALT+DOWN"] = adjust_temperature,
			["ALT+LEFT"] = adjust_tokens,
			["ALT+RIGHT"] = adjust_tokens,
			["CTRL+s"] = settings,
			["CTRL+o"] = load_conversation,
			["CTRL+r"] = show_conversation,
			["CTRL+p"] = choose_preset,
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
				backend = conf.backend.selected,
				model = conf.models.OpenAI.selected,
				ctx = 0,
				sampler = {
					temperature = conf.sampler.temperature,
					tokens = conf.sampler.tokens,
					top_k = conf.sampler.top_k,
					top_p = conf.sampler.top_p,
					min_p = conf.sampler.min_p,
					repetition_penalty = conf.sampler.repetition_penalty,
				},
			},
		},
		chats = { {} },
	}
	mode.conf = conf
	mode.total_cost = mode:get_saved_costs()
	mode.input.prompt:set({ total_cost = mode.total_cost })
	mode:flush()
	return mode
end

return { new = new }
