-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local widgets = require("term.widgets")
local utils = require("shell.utils")
local builtins = require("shell.builtins")
local theme = require("shell.theme")
local tss_gen = require("term.tss")
local tss = tss_gen.new(theme)

local check_config_dirs = function(self)
	if not std.dir_exists(self.home .. "/.config/lilush") then
		std.mkdir(self.home .. "/.config/lilush")
	end
	if not std.dir_exists(self.home .. "/.local/share/lilush") then
		std.mkdir(self.home .. "/.local/share/lilush")
	end
end

-- Top Level Builtins
local tlb = { rehash = true, alias = true, unalias = true, run_script = true, activate = true, deactivate = true }

local load_shell_config = function()
	local settings = {
		renderer = {
			wrap = 100,
			codeblock_wrap = true,
			global_indent = 2,
			hide_links = true,
		},
		aws = {
			regions = os.getenv("AWS_REGIONS") or "us-east-1",
		},
		python = {
			venvs_dir = os.getenv("LILUSH_PYTHON_VENVS_DIR"),
		},
	}
	return settings
end

local settings = function(self, combo)
	local l, c = term.cursor_position()
	term.switch_screen("alt")
	term.set_raw_mode()
	term.hide_cursor()
	widgets.settings(self.conf, "Shell Settings", theme.widgets.shell, 3, 5)
	-- This is dubious, what if it was already changed via setenv?
	std.setenv("AWS_REGIONS", self.conf.aws.regions)
	term.switch_screen("main")
	term.show_cursor()
	term.go(l, c)
	term.move("column")
	return true
end

local run_script = function(self, cmd, args)
	local args = args or {}
	local script_file = args[1] or ""
	if not script_file:match("^/") then
		script_file = std.cwd() .. "/" .. script_file
	end
	local script, err = io.open(script_file, "r")
	if script then
		local line_num = 0
		for line in script:lines() do
			line_num = line_num + 1
			if not line:match("^#") and #line > 0 then
				local cmd, args = utils.parse_cmdline(line, true)
				local status
				if cmd then
					if tlb[cmd] then
						status = self[cmd](self, cmd, args)
					else
						status = utils.run_pipeline({ { cmd = cmd, args = args } }, nil, builtins)
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
	self:run_script("run_script", { os.getenv("HOME") .. "/.config/lilush/init.lsh" })
end

local replace_aliases = function(self, input)
	local input = input
	input = input:gsub("^%s-([%w._]+)", self.aliases)
	input = input:gsub("|%s-([%w._]+)", self.aliases)
	return input
end

-- TOP BUILTINS
-- These are the builtins that we have to process here,
-- cause they need access to the mode's self object.

local rehash = function(self, cmd, args)
	if self.input.completions then
		self.input.completions.source:update()
	end
	return 0
end

local alias = function(self, cmd, args)
	local args = args or {}
	if cmd == "alias" then
		if #args == 0 then
			local max = 0
			local sorted = std.sort_keys(self.aliases)
			local out = ""
			tss.__style.builtins.alias.name.w = std.longest(sorted)
			for _, entry in ipairs(sorted) do
				out = out .. tss:apply("builtins.alias.name", entry)
				out = out .. tss:apply("builtins.alias.value", self.aliases[entry]) .. "\n"
			end
			term.write(out)
		elseif #args > 1 then
			local a = table.remove(args, 1)
			self.aliases[a] = table.concat(args, " ")
			if self.input.completions then
				self.input.completions.source.sources.builtins:update(self.aliases)
			end
		end
	elseif cmd == "unalias" then
		if #args > 0 then
			self.aliases[args[1]] = nil
			if self.input.completions then
				self.input.completions.source.sources.builtins:update(self.aliases)
			end
		end
	end
	return 0
end

local python_env = function(self, cmd, args)
	local args = args or {}
	local cmd = cmd or "activate"
	local deactivate = function()
		local virtual_env = os.getenv("VIRTUAL_ENV")
		if virtual_env then
			std.setenv("PATH", self.old_path)
			std.unsetenv("VIRTUAL_ENV")
			local prompt = os.getenv("LILUSH_PROMPT") or ""
			local new_prompt = prompt:gsub("python,?", "")
			std.setenv("LILUSH_PROMPT", new_prompt)
			self:rehash()
		end
	end
	if cmd == "activate" then
		local base_dir = self.conf.python.venvs_dir
		local virtual_env = args[1] or ""
		if virtual_env == "" and base_dir then
			local files = std.list_files(base_dir, nil, "d") or {}
			local venvs = {}
			for f, s in pairs(files) do
				table.insert(venvs, f)
			end
			venvs = std.alphanumsort(venvs)
			local content = { title = "Choose a python venv", options = venvs }
			local l, c = term.cursor_position()
			term.switch_screen("alt")
			term.set_raw_mode()
			term.hide_cursor()
			local choice = widgets.switcher(content, theme.widgets.python)
			term.switch_screen("main")
			term.show_cursor()
			term.go(l, c)
			term.set_sane_mode()
			virtual_env = base_dir .. "/" .. choice
		end
		if not virtual_env:match("^/") then
			virtual_env = std.cwd() .. "/" .. virtual_env
		end
		virtual_env = virtual_env:gsub("/$", "")
		local python_path = virtual_env .. "/bin"
		if std.dir_exists(python_path) and python_path ~= "/bin" then
			if os.getenv("VIRTUAL_ENV") ~= nil then
				deactivate()
			end
			std.setenv("VIRTUAL_ENV", virtual_env)
			local path = os.getenv("PATH") or ""
			self.old_path = path
			std.setenv("PATH", python_path .. ":" .. path)
			self:rehash()
			local prompt = os.getenv("LILUSH_PROMPT") or ""
			std.setenv("LILUSH_PROMPT", "python," .. prompt)
		end
	else
		deactivate()
	end
	return 0
end

local run = function(self)
	local input = self:replace_aliases(self.input:render())
	local pipeline, err = utils.parse_pipeline(input, true)
	if not pipeline then
		return 255, "invalid pipeline: " .. tostring(err)
	end
	if #pipeline == 0 then
		return 0
	end

	if self.input.completions then
		for _, cmdline in ipairs(pipeline) do
			local cmd = cmdline.cmd
			if
				not builtins.get(cmd)
				and not self.input.completions.source.sources.bin.binaries[cmd]
				and not tlb[cmd]
			then
				if not cmd:match("^%.?/") then
					return 255, "uknown command in pipeline: `" .. cmdline.cmd .. "`"
				end
			end
		end
	end
	local cmd = pipeline[1].cmd
	if tlb[cmd] then
		return self[cmd](self, cmd, pipeline[1].args)
	else
		local extra = {}
		if cmd == "history" then
			extra = self.input.history.entries
		end
		if cmd == "kat" then
			extra = self.conf.renderer
		end
		return utils.run_pipeline(pipeline, nil, builtins, extra)
	end
end

local new = function(input, prompt)
	local mode = {
		combos = {
			["Ctrl+S"] = settings,
		},
		aliases = {},
		home = os.getenv("HOME") or "HOMELESS",
		user = os.getenv("USER") or "nobody",
		hostname = tostring(std.read_file("/etc/hostname")):gsub("\n", ""),
		pwd = std.cwd() or "",
		check_config_dirs = check_config_dirs,
		load_config = load_config,
		run_script = run_script,
		run = run,
		replace_aliases = replace_aliases,
		rehash = rehash,
		activate = python_env,
		deactivate = python_env,
		alias = alias,
		unalias = alias,
	}
	mode.input = input
	mode.input.prompt = prompt
	mode:check_config_dirs()
	mode:load_config()
	mode.conf = load_shell_config()
	std.setenv("PWD", mode.pwd)
	local prompts = os.getenv("LILUSH_PROMPT") or "user,dir"
	mode.input.prompt:set({
		home = mode.home,
		user = mode.user,
		hostname = mode.hostname,
		pwd = mode.pwd,
		prompts = prompts,
	})
	return mode
end

return { new = new }
