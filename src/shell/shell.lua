-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local text = require("text")
local storage = require("storage")
local term = require("term")
local input = require("term.input")
local history = require("term.input.history")
local completion = require("term.input.completion")
local json = require("cjson.safe")
local prompt = require("term.input.prompt")

local shell_mode = require("shell.mode.shell")

local builtins = require("shell.builtins")
local utils = require("shell.utils")
local theme = require("shell.theme")

local show_error_msg = function(status, err)
	local msg = tostring(err) .. " *(" .. tostring(status) .. ")*"
	local out = text.render_djot(msg, theme.renderer.builtin_error)
	io.stderr:write(out)
end

-- these are combos that we always want to process
-- on the highest level first, and then pass to
-- the current mode handler
local clear_combo = function(self, combo)
	term.clear()
	self.__mode[self.__chosen_mode].input.__config.l = 1
	self.__mode[self.__chosen_mode].input.__config.c = 1
	self.__mode[self.__chosen_mode].input:flush()
	return true
end

local exit_combo = function(self, combo)
	if self.__chosen_mode ~= "shell" then
		self.__chosen_mode = "shell"
		return clear_combo(self)
	end
	if os.getenv("VIRTUAL_ENV") ~= nil and self.__mode.shell then
		self.__mode.shell.pyvenv(self.__mode.shell, "pyvenv", { "exit" })
		return true
	end
	term.set_sane_mode()
	os.exit(0)
end

local change_mode_combo = function(self, combo)
	self.__chosen_mode = self.__shortcuts[combo] or "shell"
	return clear_combo(self)
end

local run = function(self)
	term.set_raw_mode()
	if not term.has_kkbp() then
		term.write("This terminal does not seem to support kitty keyboard protocol\r\n")
		term.set_sane_mode()
		os.exit(29)
	end
	term.enable_kkbp()
	term.clear()
	self.__mode[self.__chosen_mode].input:display(true)
	while true do
		if term.resized() then
			if self.__mode[self.__chosen_mode].input:resize() then
				term.clear_line(2)
				self.__mode[self.__chosen_mode].input:display(true)
			end
		end
		local event, combo = self.__mode[self.__chosen_mode].input:event()
		if event then
			if event == "execute" then
				-- Let's eat up whatever might be left in the input buffer first:
				io.read("*a")
				term.write("\r\n")
				term.set_sane_mode()
				local cwd = std.fs.cwd()
				std.ps.setenv("LILUSH_EXEC_CWD", cwd)
				std.ps.setenv("LILUSH_EXEC_START", os.time())
				local status, err = self.__mode[self.__chosen_mode]:run()
				if status ~= 0 then
					show_error_msg(status, err)
				end
				std.ps.setenv("LILUSH_EXEC_END", os.time())
				std.ps.setenv("LILUSH_EXEC_STATUS", tostring(status))
				io.flush()
				self.__mode[self.__chosen_mode].input:flush()
				term.set_raw_mode()
				io.read("*a")
				local l, c = term.cursor_position()
				term.enable_kkbp()
				self.__mode[self.__chosen_mode].input.__config.l = l
				self.__mode[self.__chosen_mode].input.__config.c = 1
				self.__mode[self.__chosen_mode].input:display(true)
			elseif event == "combo" then
				if self.__ctrls[combo] then
					if self.__ctrls[combo](self, combo) then
						self.__mode[self.__chosen_mode].input:display(true)
					end
				elseif self.__mode[self.__chosen_mode].combos[combo] then
					if self.__mode[self.__chosen_mode].combos[combo](self.__mode[self.__chosen_mode], combo) then
						self.__mode[self.__chosen_mode].input:display(true)
					end
				end
			end
		end
	end
end

local run_once = function(self)
	local cmd = table.concat(arg, " ") or ""
	self.__mode.shell.input.buffer = cmd
	local status, err = self.__mode.shell:run()
	if err then
		print(err)
	end
	os.exit(status)
end

local new = function()
	local home = os.getenv("HOME") or "/tmp"
	std.ps.setenv("SHELL", "/usr/bin/lilush")
	local lilush_modules_path = "./?.lua;"
		.. home
		.. "/.local/share/lilush/packages/?.lua;"
		.. home
		.. "/.local/share/lilush/packages/?/init.lua;/usr/local/share/lilush/?.lua;/usr/local/share/lilush/?/init.lua"
	std.ps.setenv("LUA_PATH", lilush_modules_path)
	package.path = lilush_modules_path
	-- Check if there is the `~/.config/lilush/env` file first,
	-- if there is, we want to export those env vars before
	-- proceeding with the initialization
	local env_file = std.fs.read_file(home .. "/.config/lilush/env")
	if env_file then
		local env_lines = std.txt.lines(env_file)
		for _, line in ipairs(env_lines) do
			if not line:match("^#") then
				local cmd, args = utils.parse_cmdline("setenv " .. line, true)
				local status
				if cmd then
					status = utils.run_pipeline({ { cmd = cmd, args = args } }, nil, builtins)
				end
			end
		end
	end
	local shell_config_json = std.fs.read_file(home .. "/.config/lilush/config.json")
	local shell_config = json.decode(shell_config_json)
		or {
			chosen_mode = "shell",
			modes = {
				shell = {
					shortcut = "F1",
					path = "shell.mode.shell",
					history = true,
					prompt = "shell.mode.shell.prompt",
					completion = {
						path = "shell.completion.shell",
						sources = {
							"shell.completion.source.bin",
							"shell.completion.source.builtins",
							"shell.completion.source.cmds",
							"shell.completion.source.env",
							"shell.completion.source.fs",
						},
					},
				},
			},
		}
	local history_store = storage.new()
	local shell = {
		__mode = {},
		__shortcuts = {},
		__ctrls = {
			["CTRL+d"] = exit_combo,
			["CTRL+l"] = clear_combo,
		},
		__chosen_mode = shell_config.chosen_mode,
		run = run,
	}
	for name, m in pairs(shell_config.modes) do
		local mod, pt, cmpl, hst
		if not std.module_available(m.path) then
			show_error_msg(29, "no such module: " .. m.path)
			os.exit(29)
		end
		if m.prompt then
			if not std.module_available(m.prompt) then
				show_error_msg(29, "no such module: " .. m.prompt)
				os.exit(29)
			end
			pt = prompt.new(m.prompt)
		end
		if m.completion then
			if not std.module_available(m.completion.path) then
				show_error_msg(29, "no such module: " .. m.completion.path)
				os.exit(29)
			end
			cmpl = completion.new(m.completion)
		end
		local mod = require(m.path)
		if m.history then
			hst = history.new(name, history_store)
		end
		shell.__shortcuts[m.shortcut] = name
		shell.__mode[name] = mod.new(input.new({ completion = cmpl, history = hst, prompt = pt }))
		shell.__ctrls[m.shortcut] = change_mode_combo
	end
	return shell
end

local new_mini = function()
	local home = os.getenv("HOME") or "/tmp"
	local lilush_modules_path = "./?.lua;"
		.. home
		.. "/.local/share/lilush/packages/?.lua;"
		.. home
		.. "/.local/share/lilush/packages/?/init.lua;/usr/local/share/lilush/?.lua;/usr/local/share/lilush/?/init.lua"
	std.ps.setenv("LUA_PATH", lilush_modules_path)
	package.path = lilush_modules_path
	local shell = {
		__mode = { shell = shell_mode.new(input.new({})) },
		__chosen_mode = "shell",
		run = run_once,
	}
	return shell
end

return { new = new, new_mini = new_mini }
