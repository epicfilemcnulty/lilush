-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local text = require("text")

local input = require("shell.input")
local shell_mode = require("shell.modes.shell")
local lua_mode = require("shell.modes.lua")
local llm_mode = require("shell.modes.llm")

local shell_prompt = require("shell.prompts.shell")
local lua_prompt = require("shell.prompts.lua")
local llm_prompt = require("shell.prompts.llm")

local shell_completions = require("shell.completions.shell")
local builtins = require("shell.builtins")
local utils = require("shell.utils")
local storage = require("shell.storage")
local theme = require("shell.theme")

local show_error_message = function(status, err)
	local msg = tostring(err) .. " *(" .. tostring(status) .. ")*"
	local out = text.render_djot(msg, theme.renderer.builtin_error)
	io.stderr:write(out)
end

-- these are combos that we always want to process
-- on the highest level first, and then pass to
-- the current mode handler
local exit_combo = function(self, combo)
	if self.mode ~= "shell" then
		self.mode = "shell"
		term.move("line_down")
		return true
	end
	if os.getenv("VIRTUAL_ENV") ~= nil then
		self.modes.shell.deactivate(self.modes.shell, "deactivate")
		term.move("line_down")
		return true
	end
	term.set_sane_mode()
	os.exit(0)
end

local clear_combo = function(self, combo)
	term.clear()
	term.go(1, 1)
	self.modes[self.mode].input:flush()
	return true
end

local change_mode_combo = function(self, combo)
	local map = { ["F1"] = "shell", ["F2"] = "llm", ["F3"] = "lua" }
	self.mode = map[combo]
	term.move("line_down")
	return true
end

local toggle_blocks_combo = function(self, combo)
	local map = { ["Alt+K"] = "kube", ["Alt+A"] = "aws", ["Alt+G"] = "git" }

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
	prompt = table.concat(blocks, ",")
	self.modes.shell.input.prompt:set({ prompts = prompt }, true)
	term.move("line_down")
	return true
end

local combos = {
	["Ctrl+D"] = exit_combo,
	["Ctrl+L"] = clear_combo,
	["Alt+K"] = toggle_blocks_combo,
	["Alt+A"] = toggle_blocks_combo,
	["Alt+G"] = toggle_blocks_combo,
	["F1"] = change_mode_combo,
	["F2"] = change_mode_combo,
	["F3"] = change_mode_combo,
}

local run = function(self)
	term.set_raw_mode()
	term.clear()
	term.write_at(1, 1, self.modes[self.mode].input.prompt:get())
	while true do
		local event, combo = self.modes[self.mode].input:event()
		if event then
			if event == "execute" then
				term.set_sane_mode()
				term.write("\r\n")
				local cwd = std.cwd()
				std.setenv("LILUSH_EXEC_CWD", cwd)
				std.setenv("LILUSH_EXEC_START", os.time())
				local status, err = self.modes[self.mode]:run()
				if status ~= 0 then
					show_error_message(status, err)
				end
				std.setenv("LILUSH_EXEC_END", os.time())
				std.setenv("LILUSH_EXEC_STATUS", tostring(status))
				io.flush()
				self.modes[self.mode].input:flush()
				term.set_raw_mode()
				term.move("column")
				term.write(self.modes[self.mode].input.prompt:get())
			elseif event == "combo" then
				if combos[combo] then
					if combos[combo](self, combo) then
						term.write(self.modes[self.mode].input.prompt:get() .. self.modes[self.mode].input:display())
					end
				elseif self.modes[self.mode].combos[combo] then
					if self.modes[self.mode].combos[combo](self.modes[self.mode], combo) then
						term.write(self.modes[self.mode].input.prompt:get() .. self.modes[self.mode].input:display())
					end
				end
			end
		end
	end
end

local run_once = function(self)
	local cmd = table.concat(arg, " ") or ""
	self.modes.shell.input.buffer = cmd
	local status, err = self.modes.shell:run()
	if err then
		print(err)
	end
	os.exit(status)
end

local new = function()
	local home = os.getenv("HOME") or ""
	std.setenv("SHELL", "/bin/lilush")
	local lilush_modules_path = "./?.lua;"
		.. home
		.. "/.local/share/lilush/packages/?.lua;"
		.. home
		.. "/.local/share/lilush/packages/?/init.lua;/usr/local/share/lilush/?.lua;/usr/local/share/lilush/?/init.lua"
	std.setenv("LUA_PATH", lilush_modules_path)
	package.path = lilush_modules_path
	-- Check if there is the `~/.config/lilush/env` file first,
	-- if there is, we want to export those env vars before
	-- proceeding with the initialization
	local env_file = std.read_file(home .. "/.config/lilush/env")
	if env_file then
		local env_lines = std.lines(env_file)
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
	local data_store = storage.new()
	local shell = {
		modes = {
			shell = shell_mode.new(input.new("shell", shell_completions, data_store), shell_prompt),
			lua = lua_mode.new(input.new("lua", nil, data_store), lua_prompt),
			llm = llm_mode.new(input.new("llm", nil, data_store), llm_prompt, data_store),
		},
		mode = "shell",
		run = run,
	}
	shell.modes.shell.input.completions.source:update()
	return shell
end

local new_mini = function()
	local shell = {
		modes = { shell = shell_mode.new(input.new("mini"), shell_prompt) },
		mode = "shell",
		run = run_once,
	}
	return shell
end

return { new = new, new_mini = new_mini }
