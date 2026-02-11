-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local json = require("cjson.safe")
local term = require("term")
local input = require("term.input")
local history = require("term.input.history")
local completion = require("term.input.completion")
local prompt = require("term.input.prompt")

local storage = require("shell.store")
local shell_mode = require("shell.mode.shell")
local builtins = require("shell.builtins")
local messages = require("shell.messages")
local pipeline = require("shell.utils.pipeline")

local change_mode_combo

local get_mode = function(self, mode_name)
	local name = mode_name or ""
	return self.__state.modes[name]
end

local get_current_mode = function(self)
	local chosen = self.__state.chosen_mode
	if not self.__state.modes[chosen] then
		chosen = "shell"
		self.__state.chosen_mode = chosen
	end
	return self.__state.modes[chosen]
end

local required_mode_methods = { "get_input", "can_handle_combo", "handle_combo" }

local validate_mode_contract = function(mode_name, mode)
	if type(mode) ~= "table" then
		return nil, "mode `" .. tostring(mode_name) .. "` must return a table"
	end
	for _, method_name in ipairs(required_mode_methods) do
		if type(mode[method_name]) ~= "function" then
			return nil, "mode `" .. tostring(mode_name) .. "` is missing required method `" .. method_name .. "`"
		end
	end
	return true
end

local activate_mode = function(self, mode_name)
	local mode = get_mode(self, mode_name)
	if not mode then
		return nil, "mode `" .. tostring(mode_name) .. "` is not available"
	end

	if type(mode.on_activate) ~= "function" then
		return true
	end

	local ok, activated, err = pcall(function()
		return mode:on_activate()
	end)
	if not ok then
		return nil, tostring(activated)
	end
	if not activated then
		return nil, err or ("failed to activate mode `" .. tostring(mode_name) .. "`")
	end

	return true
end

local run_in_sane_mode = function(handler)
	term.disable_kkbp()
	term.set_sane_mode()
	local redraw = handler()
	term.set_raw_mode()
	term.enable_kkbp()
	return redraw
end

local load_mode = function(self, mode_name, mode_cfg, history_store)
	local mode_module, mode_prompt, mode_completion, mode_history
	if not std.module_available(mode_cfg.path) then
		messages.error("no such module: " .. mode_cfg.path, { status = 29 })
		os.exit(29)
	end
	if mode_cfg.prompt then
		if not std.module_available(mode_cfg.prompt) then
			messages.error("no such module: " .. mode_cfg.prompt, { status = 29 })
			os.exit(29)
		end
		mode_prompt = prompt.new(mode_cfg.prompt)
	end
	if mode_cfg.completion then
		if not std.module_available(mode_cfg.completion.path) then
			messages.error("no such module: " .. mode_cfg.completion.path, { status = 29 })
			os.exit(29)
		end
		local completion_obj, completion_err = completion.new(mode_cfg.completion)
		if not completion_obj then
			messages.error("failed to initialize completion: " .. tostring(completion_err), { status = 29 })
			os.exit(29)
		end
		mode_completion = completion_obj
	end
	mode_module = require(mode_cfg.path)
	if mode_cfg.history then
		mode_history = history.new(mode_name, history_store)
	end

	local mode_input =
		input.new({ completion = mode_completion, history = mode_history, prompt = mode_prompt, l = 1, c = 1 })
	local mode = mode_module.new(mode_input, mode_cfg)
	local valid, validation_err = validate_mode_contract(mode_name, mode)
	if not valid then
		messages.error(validation_err, { status = 29 })
		os.exit(29)
	end
	self.__state.modes[mode_name] = mode
end

local bind_mode_shortcut = function(self, mode_name, shortcut)
	if type(shortcut) ~= "string" or shortcut == "" then
		return false
	end
	self.__state.shortcuts[shortcut] = mode_name
	self.__state.ctrls[shortcut] = change_mode_combo
	return true
end

local has_mode = function(self, mode_name)
	return get_mode(self, mode_name) ~= nil
end

local list_modes = function(self)
	local mode_names = {}
	for mode_name, _ in pairs(self.__state.modes) do
		table.insert(mode_names, mode_name)
	end
	table.sort(mode_names)
	return mode_names
end

local get_mode_for_shortcut = function(self, shortcut)
	if type(shortcut) ~= "string" then
		return nil
	end
	return self.__state.shortcuts[shortcut]
end

local list_shortcuts = function(self)
	local shortcuts = {}
	for shortcut, mode_name in pairs(self.__state.shortcuts) do
		shortcuts[shortcut] = mode_name
	end
	return shortcuts
end

local has_combo_handler = function(self, combo)
	if type(combo) ~= "string" then
		return false
	end
	return type(self.__state.ctrls[combo]) == "function"
end

-- these are combos that we always want to process
-- on the highest level first, and then pass to
-- the current mode handler
local clear_combo = function(self, combo)
	term.clear()
	local mode = get_current_mode(self)
	if mode then
		local mode_input = mode:get_input()
		if mode_input then
			mode_input:set_position(1, 1)
			mode_input:flush()
		end
	end
	return true
end

local exit_combo = function(self, combo)
	if self.__state.chosen_mode ~= "shell" then
		self.__state.chosen_mode = "shell"
		return clear_combo(self)
	end
	local mode = get_mode(self, "shell")
	if os.getenv("VIRTUAL_ENV") ~= nil and mode and type(mode.on_shell_exit) == "function" then
		return mode:on_shell_exit()
	end
	term.disable_kkbp()
	term.disable_bracketed_paste()
	term.set_sane_mode()
	os.exit(0)
end

change_mode_combo = function(self, combo)
	local next_mode_name = self.__state.shortcuts[combo] or "shell"
	local activated, activate_err = activate_mode(self, next_mode_name)
	if not activated then
		messages.error(activate_err)
		return true
	end

	self.__state.chosen_mode = next_mode_name
	return clear_combo(self)
end

local run = function(self)
	if not term.is_tty() then
		messages.error("Not connected to a TTY", { status = 29 })
		os.exit(29)
	end
	term.set_raw_mode()
	if not term.has_kkbp() then
		term.write("This terminal does not seem to support kitty keyboard protocol\r\n")
		term.set_sane_mode()
		os.exit(29)
	end
	term.enable_kkbp()
	term.enable_bracketed_paste()
	term.clear()

	local mode = get_current_mode(self)
	local mode_input = mode and mode:get_input() or nil
	if mode_input then
		mode_input:display(true)
	end

	while true do
		local active_mode = get_current_mode(self)
		local active_input = active_mode and active_mode:get_input() or nil
		if not active_mode or not active_input then
			messages.error("active mode is not available", { status = 29 })
			os.exit(29)
		end

		local event, combo = active_input:run({ execute = true, exit = false, combo = true })
		if event then
			if event == "execute" then
				-- Clear any pending input
				io.flush()
				term.write("\r\n")
				term.disable_kkbp()
				term.set_sane_mode()

				local cwd = std.fs.cwd()
				std.ps.setenv("LILUSH_EXEC_CWD", cwd)
				std.ps.setenv("LILUSH_EXEC_START", os.time())
				local status, err, next_input, skip_history = active_mode:run()
				if status == nil and err == nil then
					status = 0
				end
				if status ~= 0 then
					messages.error(err, { status = status })
				end
				std.ps.setenv("LILUSH_EXEC_END", os.time())
				std.ps.setenv("LILUSH_EXEC_STATUS", tostring(status))
				if not skip_history then
					active_input:add_to_history()
				end

				term.set_raw_mode()
				io.flush()
				term.enable_kkbp()

				local l, _ = term.cursor_position()
				active_input:set_position(l, 1)
				active_input:flush()
				if next_input then
					active_input:set_content(next_input)
				end
				active_input:display(true)
			elseif event == "combo" then
				if self.__state.ctrls[combo] then
					local redraw = run_in_sane_mode(function()
						return self.__state.ctrls[combo](self, combo)
					end)
					if redraw then
						local current_mode = get_current_mode(self)
						local current_input = current_mode and current_mode:get_input() or nil
						if current_input then
							current_input:display(true)
						end
					end
				elseif active_mode:can_handle_combo(combo) then
					local redraw = run_in_sane_mode(function()
						return active_mode:handle_combo(combo)
					end)
					if redraw then
						active_input:display(true)
					end
				end
			end
		end
	end
end

local run_once = function(self)
	local cmd = table.concat(arg, " ") or ""
	local mode = get_mode(self, "shell")
	if not mode then
		messages.error("shell mode is not available", { status = 29 })
		os.exit(29)
	end
	local mode_input = mode:get_input()
	mode_input:set_content(cmd)
	local status, err = mode:run_once()
	if status ~= 0 then
		messages.error(err, { status = status })
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
				local cmd, args = pipeline.parse_cmdline("setenv " .. line, true)
				if cmd then
					pipeline.run({ { cmd = cmd, args = args } }, nil, builtins)
				end
			end
		end
	end
	local builtin_mode_configs = {
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
		lua = {
			shortcut = "F2",
			path = "shell.mode.lua",
			history = true,
			prompt = "shell.mode.lua.prompt",
			completion = {
				path = "shell.completion.lua",
				sources = {
					"shell.completion.source.lua_keywords",
					"shell.completion.source.lua_symbols",
				},
			},
		},
		agent = {
			shortcut = "F3",
			path = "agent.mode.agent",
			history = true,
			prompt = "agent.mode.agent.prompt",
			completion = {
				path = "agent.completion.slash",
				sources = {
					"agent.completion.source.slash",
				},
			},
		},
	}
	local builtin_mode_order = { "shell", "lua", "agent" }
	local reserved_shortcuts = { F1 = true, F2 = true, F3 = true }
	local user_shortcut_pool = { "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" }
	local history_store = storage.new()

	local shell = {
		cfg = {
			builtin_mode_configs = builtin_mode_configs,
			builtin_mode_order = builtin_mode_order,
			reserved_shortcuts = reserved_shortcuts,
			user_shortcut_pool = user_shortcut_pool,
		},
		__state = {
			modes = {},
			shortcuts = {},
			ctrls = {
				["CTRL+d"] = exit_combo,
				["CTRL+l"] = clear_combo,
			},
			chosen_mode = "shell",
			history_store = history_store,
			assigned_shortcuts = {},
		},
		run = run,
		has_mode = has_mode,
		get_mode = get_mode,
		list_modes = list_modes,
		get_mode_for_shortcut = get_mode_for_shortcut,
		list_shortcuts = list_shortcuts,
		has_combo_handler = has_combo_handler,
	}

	local next_free_user_shortcut = function()
		for _, shortcut in ipairs(shell.cfg.user_shortcut_pool) do
			if not shell.__state.assigned_shortcuts[shortcut] then
				return shortcut
			end
		end
		return nil
	end

	for _, mode_name in ipairs(shell.cfg.builtin_mode_order) do
		local mode_cfg = shell.cfg.builtin_mode_configs[mode_name]
		load_mode(shell, mode_name, mode_cfg, shell.__state.history_store)
		bind_mode_shortcut(shell, mode_name, mode_cfg.shortcut)
		shell.__state.assigned_shortcuts[mode_cfg.shortcut] = mode_name
	end

	local modes = std.fs.list_files(home .. "/.config/lilush/modes", "json") or {}
	local mode_files = {}
	for mode_file, _ in pairs(modes) do
		table.insert(mode_files, mode_file)
	end
	table.sort(mode_files)
	for _, mode_file in ipairs(mode_files) do
		local mode_name = mode_file:match("^(.+)%.json$")
		if mode_name then
			if shell.cfg.builtin_mode_configs[mode_name] then
				messages.warning(
					"ignoring reserved mode config `" .. mode_file .. "`: built-in mode `" .. mode_name .. "` is fixed"
				)
			else
				local mode_json = std.fs.read_file(home .. "/.config/lilush/modes/" .. mode_file)
				local m = json.decode(mode_json)
				if not m then
					messages.error("failed to decode mode config", { status = 29 })
					os.exit(29)
				end
				local requested_shortcut = m.shortcut
				local assigned_shortcut = requested_shortcut
				local collision_reason = nil
				if type(requested_shortcut) ~= "string" or requested_shortcut == "" then
					assigned_shortcut = nil
				elseif shell.cfg.reserved_shortcuts[requested_shortcut] then
					assigned_shortcut = next_free_user_shortcut()
					collision_reason = "reserved"
				elseif shell.__state.assigned_shortcuts[requested_shortcut] then
					assigned_shortcut = next_free_user_shortcut()
					collision_reason = "taken"
				end
				if collision_reason == "reserved" then
					if assigned_shortcut then
						messages.warning(
							"mode `"
								.. mode_name
								.. "` requested reserved shortcut `"
								.. requested_shortcut
								.. "`, reassigned to `"
								.. assigned_shortcut
								.. "`"
						)
					else
						messages.warning(
							"mode `"
								.. mode_name
								.. "` requested reserved shortcut `"
								.. requested_shortcut
								.. "`, no free shortcuts in F4..F12, loaded without shortcut"
						)
					end
				elseif collision_reason == "taken" then
					if assigned_shortcut then
						messages.warning(
							"mode `"
								.. mode_name
								.. "` requested taken shortcut `"
								.. requested_shortcut
								.. "`, reassigned to `"
								.. assigned_shortcut
								.. "`"
						)
					else
						messages.warning(
							"mode `"
								.. mode_name
								.. "` requested taken shortcut `"
								.. requested_shortcut
								.. "`, no free shortcuts in F4..F12, loaded without shortcut"
						)
					end
				end
				m.shortcut = assigned_shortcut
				load_mode(shell, mode_name, m, shell.__state.history_store)
				if bind_mode_shortcut(shell, mode_name, assigned_shortcut) then
					shell.__state.assigned_shortcuts[assigned_shortcut] = mode_name
				end
			end
		end
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
	local mini_shell_mode = shell_mode.new(input.new({}))
	local valid, validation_err = validate_mode_contract("shell", mini_shell_mode)
	if not valid then
		messages.error(validation_err, { status = 29 })
		os.exit(29)
	end
	local shell = {
		cfg = {},
		__state = {
			modes = { shell = mini_shell_mode },
			shortcuts = {},
			ctrls = {},
			chosen_mode = "shell",
		},
		run = run_once,
		has_mode = has_mode,
		get_mode = get_mode,
		list_modes = list_modes,
		get_mode_for_shortcut = get_mode_for_shortcut,
		list_shortcuts = list_shortcuts,
		has_combo_handler = has_combo_handler,
	}
	return shell
end

return { new = new, new_mini = new_mini }
