-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local widgets = require("term.widgets")
local utils = require("shell.utils")
local builtins = require("shell.builtins")
local theme = require("shell.theme")
local style = require("term.tss")
local tss = style.new(theme)

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
	term.switch_screen("alt", true)
	term.hide_cursor()
	widgets.settings(self.conf, "Shell Settings", theme.widgets.shell, 3, 5)
	-- This is dubious, what if it was already changed via setenv?
	std.ps.setenv("AWS_REGIONS", self.conf.aws.regions)
	term.switch_screen("main", nil, true)
	term.show_cursor()
	return true
end

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
	local home = os.getenv("HOME") or "/tmp"
	local config_file = home .. "/.config/lilush/init.lsh"
	if std.fs.file_exists(config_file) then
		self:run_script("run_script", { config_file })
	end
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
			local prompt = os.getenv("LILUSH_PROMPT") or ""
			local new_prompt = prompt:gsub("python,?", "")
			std.ps.setenv("LILUSH_PROMPT", new_prompt)
			self:rehash()
		end
	end
	if args[1] and args[1] == "exit" or args[1] == "deactivate" then
		deactivate()
		return 0
	end
	local base_dir = self.conf.python.venvs_dir
	local virtual_env = args[1] or ""
	if virtual_env == "" and base_dir then
		local files = std.fs.list_files(base_dir, nil, "d") or {}
		local venvs = {}
		for f, s in pairs(files) do
			table.insert(venvs, f)
		end
		venvs = std.tbl.alphanumsort(venvs)
		term.set_raw_mode()
		local l, c = term.cursor_position()
		local content = { title = "Choose a python venv", options = venvs }
		term.switch_screen("alt", true)
		term.hide_cursor()
		local choice = widgets.switcher(content, theme.widgets.python)
		term.switch_screen("main", nil, true)
		term.show_cursor()
		term.go(l, c)
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
		local prompt = os.getenv("LILUSH_PROMPT") or ""
		std.ps.setenv("LILUSH_PROMPT", "python," .. prompt)
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

	if self.input.completion then
		for _, cmdline in ipairs(pipeline) do
			local cmd = cmdline.cmd
			if not builtins.get(cmd) and not self.input.completion.__sources["bin"].binaries[cmd] and not tlb[cmd] then
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

local toggle_blocks_combo = function(self, combo)
	local map = { ["ALT+k"] = "kube", ["ALT+a"] = "aws", ["ALT+g"] = "git" }

	local prompt = os.getenv("LILUSH_PROMPT") or ""
	local blocks = {}
	local toggled = false
	for b in prompt:gmatch("(%w+),?") do
		if b ~= map[combo] then
			table.insert(blocks, b)
		else
			toggled = true
		end
	end
	if not toggled then
		if map[combo] == "git" then
			table.insert(blocks, map[combo])
		else
			table.insert(blocks, 1, map[combo])
		end
	end
	enabled_blocks = table.concat(blocks, ",")
	self.input.prompt:set({ blocks = enabled_blocks }, true)
	return true
end

local new = function(input)
	local mode = {
		combos = {
			["CTRL+s"] = settings,
			["ALT+k"] = toggle_blocks_combo,
			["ALT+a"] = toggle_blocks_combo,
			["ALT+g"] = toggle_blocks_combo,
		},
		aliases = {},
		home = os.getenv("HOME") or "HOMELESS",
		user = os.getenv("USER") or "nobody",
		hostname = tostring(std.fs.read_file("/etc/hostname")):gsub("\n", ""),
		pwd = std.fs.cwd() or "",
		check_config_dirs = check_config_dirs,
		load_config = load_config,
		run_script = run_script,
		run = run,
		replace_aliases = replace_aliases,
		rehash = rehash,
		pyvenv = python_env,
		alias = alias,
		unalias = alias,
	}
	mode.input = input
	mode:check_config_dirs()
	mode:load_config()
	mode.conf = load_shell_config()
	std.ps.setenv("PWD", mode.pwd)
	local prompts = os.getenv("LILUSH_PROMPT") or "user,dir"
	if mode.input.prompt then
		mode.input.prompt:set({
			home = mode.home,
			user = mode.user,
			hostname = mode.hostname,
			pwd = mode.pwd,
			prompts = prompts,
		})
	end
	if mode.input.completion then
		mode.input.completion.__sources["builtins"]:update(mode.aliases)
	end
	return mode
end

return { new = new }
