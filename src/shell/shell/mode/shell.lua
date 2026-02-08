-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local term = require("term")
local widgets = require("term.widgets")
local pipeline = require("shell.utils.pipeline")
local builtins = require("shell.builtins")
local theme = require("shell.theme")
local style = require("term.tss")
local tss = style.new(theme)
local storage = require("shell.store")
local vault = require("vault")
local jobs = require("shell.jobs")

local get_input = function(self)
	return self.__state.input
end

local check_config_dirs = function(self)
	if not std.fs.dir_exists(self.__state.home .. "/.config/lilush") then
		std.fs.mkdir(self.__state.home .. "/.config/lilush")
	end
	if not std.fs.dir_exists(self.__state.home .. "/.local/share/lilush") then
		std.fs.mkdir(self.__state.home .. "/.local/share/lilush")
	end
end

-- Top Level Builtins
local tlb = { rehash = true, alias = true, unalias = true, run_script = true, pyvenv = true }

local run_script = function(self, cmd, args)
	local script_args = args or {}
	local script_file = script_args[1] or ""
	if not script_file:match("^/") then
		script_file = std.fs.cwd() .. "/" .. script_file
	end
	local script, err = io.open(script_file, "r")
	if script then
		local line_num = 0
		for line in script:lines() do
			line_num = line_num + 1
			if not line:match("^#") and #line > 0 then
				local parsed_cmd, parsed_args = pipeline.parse_cmdline(line, true)
				local status
				if parsed_cmd then
					if tlb[parsed_cmd] then
						status = self[parsed_cmd](self, parsed_cmd, parsed_args)
					else
						status = pipeline.run({ { cmd = parsed_cmd, args = parsed_args } }, nil, builtins)
					end
				end
				if status ~= nil and status ~= 0 then
					builtins.errmsg(
						"error on line "
							.. line_num
							.. ", {"
							.. tostring(parsed_cmd)
							.. "}, exit code: "
							.. tostring(status)
					)
					return 127
				end
			end
		end
		script:close()
		return 0
	end
	builtins.errmsg(err)
	return 255
end

local load_config = function(self)
	local config_file = self.__state.home .. "/.config/lilush/init.lsh"
	if std.fs.file_exists(config_file) then
		self:run_script("run_script", { config_file })
	end
end

local replace_aliases = function(self, raw_input)
	local expanded_input = raw_input or ""
	expanded_input = expanded_input:gsub("^%s-([%w._]+)", self.__state.aliases)
	expanded_input = expanded_input:gsub("|%s-([%w._]+)", self.__state.aliases)
	return expanded_input
end

-- TOP BUILTINS
-- These are the builtins that we have to process here,
-- cause they need access to the mode's self object.

local rehash = function(self, cmd, args)
	get_input(self):completion_update()
	return 0
end

local alias = function(self, cmd, args)
	local cmd_args = args or {}
	local aliases = self.__state.aliases
	if cmd == "alias" then
		if #cmd_args == 0 then
			local sorted = std.tbl.sort_keys(aliases)
			local out = ""
			tss:set_property("builtins.alias.name", "w", std.tbl.longest(sorted))
			for _, entry in ipairs(sorted) do
				out = out .. tss:apply("builtins.alias.name", entry).text
				out = out .. tss:apply("builtins.alias.value", aliases[entry]).text .. "\n"
			end
			term.write(out)
		elseif #cmd_args > 1 then
			local alias_name = table.remove(cmd_args, 1)
			aliases[alias_name] = table.concat(cmd_args, " ")
			get_input(self):completion_update_source("builtins", aliases)
		end
	elseif cmd == "unalias" then
		if #cmd_args > 0 then
			aliases[cmd_args[1]] = nil
			get_input(self):completion_update_source("builtins", aliases)
		end
	end
	return 0
end

local python_env = function(self, cmd, args)
	local cmd_args = args or {}
	local deactivate = function()
		local virtual_env = os.getenv("VIRTUAL_ENV")
		if virtual_env then
			std.ps.setenv("PATH", self.__state.old_path)
			std.ps.unsetenv("VIRTUAL_ENV")
			get_input(self):prompt_toggle_block("python")
			self:rehash()
		end
	end
	if (cmd_args[1] and cmd_args[1] == "exit") or cmd_args[1] == "deactivate" then
		deactivate()
		return 0
	end
	local base_dir = os.getenv("LILUSH_PYTHON_VENVS_DIR")
	local virtual_env = cmd_args[1] or ""
	if virtual_env == "" and base_dir then
		local files = std.fs.list_files(base_dir, nil, "d") or {}
		local venvs = {}
		for f, _ in pairs(files) do
			table.insert(venvs, f)
		end
		venvs = std.tbl.alphanumsort(venvs)
		local choice = widgets.chooser(venvs, { rss = theme.widgets.python, title = "Choose a python venv" })
		if not choice then
			return 0
		end
		virtual_env = base_dir .. "/" .. choice
	end
	if not virtual_env:match("^/") then
		virtual_env = std.fs.cwd() .. "/" .. virtual_env
	end
	virtual_env = virtual_env:gsub("/$", "")
	local python_path = virtual_env .. "/bin"
	if std.fs.dir_exists(python_path) and python_path ~= "/bin" then
		if os.getenv("VIRTUAL_ENV") ~= nil then
			deactivate()
		end
		std.ps.setenv("VIRTUAL_ENV", virtual_env)
		local path = os.getenv("PATH") or ""
		self.__state.old_path = path
		std.ps.setenv("PATH", python_path .. ":" .. path)
		self:rehash()
		get_input(self):prompt_toggle_block("python")
	end
	return 0
end

local vault_login = function()
	local store = storage.new()
	local token = os.getenv("VAULT_TOKEN") or store:get_vault_token()
	if not token then
		local login_form = widgets.form(
			{ "username", "password" },
			{ title = "Login to Vault", rss = theme.widgets.shell, meta = { password = { w = 32, secret = true } } }
		) or {}
		local vc = vault.new()
		local ok, err = vc:login(login_form.username, login_form.password)
		if not ok then
			store:close()
			return nil, err
		end
		local session_token = vc:get_token()
		if not session_token then
			store:close()
			return nil, "vault login did not return a token"
		end
		local ttl = vc:get_token_ttl()
		if ttl < 0 then
			ttl = 0
		end
		store:save_vault_token(session_token, ttl)
		store:close()
		std.ps.setenv("VAULT_TOKEN", session_token)
	end
	return true
end

local fetch_env_secrets = function(envs)
	local store = storage.new()
	local token = store:get_vault_token()
	store:close()
	local vc = vault.new(nil, token)
	local ok, err = vc:healthy()
	if not ok then
		return nil, err
	end
	for name, value in pairs(envs) do
		local mount, path = value:match("^vault://([^/]+)/(.+)$")
		if not mount or not path then
			return nil, "failed to parse vault reference"
		end
		if not path:match("#") then
			path = path .. "#value"
		end
		local secret, secret_err = vc:get_secret(path, mount)
		if not secret then
			return nil, secret_err
		end
		std.ps.setenv(name, secret)
	end
	return true
end

local clear_env_secrets = function(self)
	if self.__state.vault_vars then
		for name, value in pairs(self.__state.vault_vars) do
			std.ps.setenv(name, value)
		end
		self.__state.vault_vars = nil
		get_input(self):prompt_set({ vault_status = "locked" })
	end
end

local env_secrets_combo = function(self, combo)
	local vault_vars = {}
	local no_vault_vars = true
	for name, value in pairs(std.environ()) do
		if value:match("^vault://") then
			vault_vars[name] = value
			no_vault_vars = false
		end
	end
	if no_vault_vars then
		return false
	end
	get_input(self):prompt_toggle_block("vault")
	if not vault_login() then
		get_input(self):prompt_set({ vault_status = "error" })
		return true
	end
	local results = widgets.chooser(
		std.tbl.sort_keys(vault_vars),
		{ multiple_choice = true, rss = theme.widgets.shell, title = "Choose secrets to be fetched" }
	)
	if results and #results > 0 then
		local selected_envs = {}
		for _, name in ipairs(results) do
			selected_envs[name] = vault_vars[name]
		end
		self.__state.vault_vars = vault_vars
		if fetch_env_secrets(selected_envs) then
			get_input(self):prompt_set({ vault_status = "unlocked" })
		else
			self:clear_env_secrets()
			get_input(self):prompt_set({ vault_status = "error" })
		end
	end
	return true
end

local run = function(self)
	self.__state.jobs:poll()
	local mode_input = get_input(self)
	local parsed_input = self:replace_aliases(mode_input:get_content())
	local p, err = pipeline.parse(parsed_input, true)
	if not p then
		return 255, "invalid pipeline: " .. tostring(err)
	end
	if #p == 0 then
		return 0
	end

	for _, cmdline in ipairs(p) do
		local parsed_cmd = cmdline.cmd
		if not builtins.get(parsed_cmd) and not mode_input:lookup_binary(parsed_cmd) and not tlb[parsed_cmd] then
			if not parsed_cmd:match("^%.?/") then
				return 255, "unknown command in pipeline: `" .. cmdline.cmd .. "`"
			end
		end
	end

	local cmd = p[1].cmd
	local status, run_err
	if tlb[cmd] then
		status, run_err = self[cmd](self, cmd, p[1].args)
	else
		status, run_err = pipeline.run(p, nil, builtins, self.__state.jobs)
	end
	self:clear_env_secrets()
	return status, run_err
end

local run_once = function(self)
	local mode_input = get_input(self)
	local raw_input = mode_input:get_content()
	local p, err = pipeline.parse(raw_input, true)
	if not p then
		return 255, "invalid pipeline: " .. tostring(err)
	end
	if #p == 0 then
		return 0
	end
	local cmd = p[1].cmd
	if tlb[cmd] then
		local status, run_err = self[cmd](self, cmd, p[1].args)
		return status, run_err
	end
	local status, run_err = pipeline.run(p, nil, builtins)
	return status, run_err
end

local toggle_blocks_combo = function(self, combo)
	local selected = {}
	local mode_input = get_input(self)
	for _, b in ipairs(mode_input:prompt_blocks()) do
		selected[b] = true
	end
	local results = widgets.chooser({ "user", "dir", "ssh", "kube", "aws", "git", "vault" }, {
		multiple_choice = true,
		selected = selected,
		rss = theme.widgets.shell,
		title = "Choose prompt blocks to be enabled",
	})
	if results and #results > 0 then
		mode_input:prompt_set_blocks(results)
		return true
	end
	return false
end

local can_handle_combo = function(self, combo)
	return type(self.__state.combos[combo]) == "function"
end

local handle_combo = function(self, combo)
	local handler = self.__state.combos[combo]
	if type(handler) == "function" then
		return handler(self, combo)
	end
	return false
end

local on_shell_exit = function(self)
	if os.getenv("VIRTUAL_ENV") ~= nil then
		self:pyvenv("pyvenv", { "exit" })
		return true
	end
	return false
end

local new = function(input_obj, config)
	local mode = {
		cfg = config or {},
		__state = {
			combos = {
				["ALT+p"] = toggle_blocks_combo,
				["ALT+v"] = env_secrets_combo,
			},
			aliases = {},
			jobs = jobs.new(),
			input = input_obj,
			home = os.getenv("HOME") or "HOMELESS",
			user = os.getenv("USER") or "nobody",
			hostname = std.hostname(),
			pwd = std.fs.cwd() or "",
			vault_vars = nil,
			old_path = os.getenv("PATH") or "",
		},
		check_config_dirs = check_config_dirs,
		load_config = load_config,
		run_script = run_script,
		run = run,
		run_once = run_once,
		replace_aliases = replace_aliases,
		rehash = rehash,
		pyvenv = python_env,
		alias = alias,
		clear_env_secrets = clear_env_secrets,
		unalias = alias,
		get_input = get_input,
		can_handle_combo = can_handle_combo,
		handle_combo = handle_combo,
		on_shell_exit = on_shell_exit,
	}
	mode:check_config_dirs()
	mode:load_config()
	std.ps.setenv("PWD", mode.__state.pwd)
	mode:get_input():prompt_set({
		home = mode.__state.home,
		user = mode.__state.user,
		hostname = mode.__state.hostname,
		pwd = mode.__state.pwd,
	})
	mode:get_input():completion_update_source("builtins", mode.__state.aliases)
	return mode
end

return { new = new }
