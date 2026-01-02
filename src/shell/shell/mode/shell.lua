-- SPDX-FileCopyrightText: © 2025 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
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

local check_config_dirs = function(self)
	if not std.fs.dir_exists(self.home .. "/.config/lilush") then
		std.fs.mkdir(self.home .. "/.config/lilush")
	end
	if not std.fs.dir_exists(self.home .. "/.local/share/lilush") then
		std.fs.mkdir(self.home .. "/.local/share/lilush")
	end
end

-- Top Level Builtins
local tlb = { rehash = true, alias = true, unalias = true, run_script = true, pyvenv = true }

local run_script = function(self, cmd, args)
	local args = args or {}
	local script_file = args[1] or ""
	if not script_file:match("^/") then
		script_file = std.fs.cwd() .. "/" .. script_file
	end
	local script, err = io.open(script_file, "r")
	if script then
		local line_num = 0
		for line in script:lines() do
			line_num = line_num + 1
			if not line:match("^#") and #line > 0 then
				local cmd, args = pipeline.parse_cmdline(line, true)
				local status
				if cmd then
					if tlb[cmd] then
						status = self[cmd](self, cmd, args)
					else
						status = pipeline.run({ { cmd = cmd, args = args } }, nil, builtins)
					end
				end
				if status ~= nil and status ~= 0 then
					builtins.errmsg("error on line " .. line_num .. ", {" .. cmd .. "}, exit code: " .. status)
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
	local home = os.getenv("HOME") or "/tmp"
	local config_file = home .. "/.config/lilush/init.lsh"
	if std.fs.file_exists(config_file) then
		self:run_script("run_script", { config_file })
	end
end

local replace_aliases = function(self, input)
	local input = input or ""
	input = input:gsub("^%s-([%w._]+)", self.aliases)
	input = input:gsub("|%s-([%w._]+)", self.aliases)
	return input
end

-- TOP BUILTINS
-- These are the builtins that we have to process here,
-- cause they need access to the mode's self object.

local rehash = function(self, cmd, args)
	if self.input.completion then
		self.input.completion:update()
	end
	return 0
end

local alias = function(self, cmd, args)
	local args = args or {}
	if cmd == "alias" then
		if #args == 0 then
			local max = 0
			local sorted = std.tbl.sort_keys(self.aliases)
			local out = ""
			tss.__style.builtins.alias.name.w = std.tbl.longest(sorted)
			for _, entry in ipairs(sorted) do
				out = out .. tss:apply("builtins.alias.name", entry)
				out = out .. tss:apply("builtins.alias.value", self.aliases[entry]) .. "\n"
			end
			term.write(out)
		elseif #args > 1 then
			local a = table.remove(args, 1)
			self.aliases[a] = table.concat(args, " ")
			if self.input.completion then
				self.input.completion.__sources["builtins"]:update(self.aliases)
			end
		end
	elseif cmd == "unalias" then
		if #args > 0 then
			self.aliases[args[1]] = nil
			if self.input.completion then
				self.input.completion.__sources["builtins"]:update(self.aliases)
			end
		end
	end
	return 0
end

local python_env = function(self, cmd, args)
	local args = args or {}
	local deactivate = function()
		local virtual_env = os.getenv("VIRTUAL_ENV")
		if virtual_env then
			std.ps.setenv("PATH", self.old_path)
			std.ps.unsetenv("VIRTUAL_ENV")
			self.input.prompt:toggle_block("python")
			self:rehash()
		end
	end
	if args[1] and args[1] == "exit" or args[1] == "deactivate" then
		deactivate()
		return 0
	end
	local base_dir = os.getenv("LILUSH_PYTHON_VENVS_DIR")
	local virtual_env = args[1] or ""
	if virtual_env == "" and base_dir then
		local files = std.fs.list_files(base_dir, nil, "d") or {}
		local venvs = {}
		for f, _ in pairs(files) do
			table.insert(venvs, f)
		end
		venvs = std.tbl.alphanumsort(venvs)
		local choice = widgets.chooser(venvs, { rss = theme.widgets.python, title = "Choose a python venv" })
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
		self.old_path = path
		std.ps.setenv("PATH", python_path .. ":" .. path)
		self:rehash()
		self.input.prompt:toggle_block("python")
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
		local ttl = vc.valid_till - os.time()
		store:save_vault_token(vc.token, ttl)
		store:close()
		std.ps.setenv("VAULT_TOKEN", vc.token)
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
		local secret, err = vc:get_secret(path, mount)
		if not secret then
			return nil, err
		end
		std.ps.setenv(name, secret)
	end
	return true
end

local clear_env_secrets = function(self)
	if self.vault_vars then
		for name, value in pairs(self.vault_vars) do
			std.ps.setenv(name, value)
		end
		self.vault_vars = nil
		self.input:prompt_set({ vault_status = "locked" })
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
	self.input.prompt:toggle_block("vault")
	if not vault_login() then
		self.input:prompt_set({ vault_status = "error" })
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
		self.vault_vars = vault_vars
		if fetch_env_secrets(selected_envs) then
			self.input:prompt_set({ vault_status = "unlocked" })
		else
			self:clear_env_secrets()
			self.input:prompt_set({ vault_status = "error" })
		end
	end
	return true
end

local run = function(self)
	self.jobs:poll()
	local input = self:replace_aliases(self.input:get_content())
	local p, err = pipeline.parse(input, true)
	if not p then
		return 255, "invalid pipeline: " .. tostring(err)
	end
	if #p == 0 then
		return 0
	end

	if self.input.completion then
		for _, cmdline in ipairs(p) do
			local cmd = cmdline.cmd
			if not builtins.get(cmd) and not self.input.completion.__sources["bin"].binaries[cmd] and not tlb[cmd] then
				if not cmd:match("^%.?/") then
					return 255, "uknown command in pipeline: `" .. cmdline.cmd .. "`"
				end
			end
		end
	end

	local cmd = p[1].cmd
	local status, err
	if tlb[cmd] then
		status, err = self[cmd](self, cmd, p[1].args)
	else
		status, err = pipeline.run(p, nil, builtins, self.jobs)
	end
	-- TODO: Gotta refactor all builtins to return status
	if not status and not err then
		status = 0
	end
	self:clear_env_secrets()
	return status, err
end

local run_once = function(self)
	local input = self.input:get_content()
	local p, err = pipeline.parse(input, true)
	if not p then
		return 255, "invalid pipeline: " .. tostring(err)
	end
	if #p == 0 then
		return 0
	end
	local cmd = p[1].cmd
	if tlb[cmd] then
		local status, err = self[cmd](self, cmd, p[1].args)
		return status, err
	else
		local status, err = pipeline.run(p, nil, builtins)
		return status, err
	end
end

local toggle_blocks_combo = function(self, combo)
	local selected = {}
	for _, b in ipairs(self.input.prompt.blocks) do
		selected[b] = true
	end
	local results = widgets.chooser({ "user", "dir", "ssh", "kube", "aws", "git", "vault" }, {
		multiple_choice = true,
		selected = selected,
		rss = theme.widgets.shell,
		title = "Choose prompt blocks to be enabled",
	})
	if results and #results > 0 then
		self.input.prompt.blocks = results
		return true
	end
end

local new = function(input)
	local mode = {
		combos = {
			["ALT+p"] = toggle_blocks_combo,
			["ALT+v"] = env_secrets_combo,
		},
		aliases = {},
		jobs = jobs.new(),
		home = os.getenv("HOME") or "HOMELESS",
		user = os.getenv("USER") or "nobody",
		hostname = std.hostname(),
		pwd = std.fs.cwd() or "",
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
	}
	mode.input = input
	mode:check_config_dirs()
	mode:load_config()
	std.ps.setenv("PWD", mode.pwd)
	if mode.input.prompt then
		mode.input:prompt_set({
			home = mode.home,
			user = mode.user,
			hostname = mode.hostname,
			pwd = mode.pwd,
		})
	end
	if mode.input.completion then
		mode.input.completion.__sources["builtins"]:update(mode.aliases)
	end
	return mode
end

return { new = new }
