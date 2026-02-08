-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== shell default modes ==")

local setup_shell = function(options)
	options = options or {}
	local state = {
		input_new_calls = 0,
		mode_new_calls = {},
		read_mode_files = {},
		decode_calls = {},
	}

	local mode_files = options.mode_files or {}
	local mode_payloads = options.mode_payloads or {}
	local decode_map = options.decode_map or {}
	local user_module_names = options.user_module_names or {}
	local user_modules = options.user_modules or {}

	local make_mode = function(input_obj)
		return {
			__state = {
				input = input_obj,
				combos = {},
			},
			get_input = function(self)
				return self.__state.input
			end,
			can_handle_combo = function(self, combo)
				return type(self.__state.combos[combo]) == "function"
			end,
			handle_combo = function(self, combo)
				local handler = self.__state.combos[combo]
				if type(handler) == "function" then
					return handler(self, combo)
				end
				return false
			end,
		}
	end

	helpers.clear_modules({
		"std",
		"cjson.safe",
		"markdown",
		"term",
		"term.input",
		"term.input.history",
		"term.input.completion",
		"term.input.prompt",
		"shell.store",
		"shell.mode.shell",
		"shell.mode.lua",
		"agent.mode.agent",
		"shell.builtins",
		"shell.utils.pipeline",
		"shell.theme",
		"shell",
	})

	helpers.stub_module("std", {
		fs = {
			read_file = function(path)
				if path:match("/%.config/lilush/env$") then
					return nil
				end
				local mode_file = path:match("/%.config/lilush/modes/(.+)$")
				if mode_file then
					state.read_mode_files[mode_file] = (state.read_mode_files[mode_file] or 0) + 1
					return mode_payloads[mode_file]
				end
				return nil
			end,
			list_files = function(path, ext)
				return mode_files
			end,
			cwd = function()
				return "/tmp"
			end,
		},
		txt = {
			lines = function(text)
				return {}
			end,
		},
		ps = {
			setenv = function(name, value)
				return true
			end,
		},
		module_available = function(mod_name)
			return true
		end,
	})
	helpers.stub_module("cjson.safe", {
		decode = function(raw)
			state.decode_calls[tostring(raw)] = (state.decode_calls[tostring(raw)] or 0) + 1
			return decode_map[raw]
		end,
	})
	helpers.stub_module("markdown", {
		render = function(text)
			return text
		end,
	})
	helpers.stub_module("term", {})
	helpers.stub_module("term.input", {
		new = function(config)
			state.input_new_calls = state.input_new_calls + 1
			return {
				cfg = config,
				display = function() end,
				run = function()
					return nil
				end,
			}
		end,
	})
	helpers.stub_module("term.input.history", {
		new = function(mode_name)
			return { mode = mode_name }
		end,
	})
	helpers.stub_module("term.input.completion", {
		new = function(config)
			return { cfg = config }
		end,
	})
	helpers.stub_module("term.input.prompt", {
		new = function(prompt_name)
			return { prompt_name = prompt_name }
		end,
	})
	helpers.stub_module("shell.store", {
		new = function()
			return {}
		end,
	})
	helpers.stub_module("shell.mode.shell", {
		new = function(input_obj)
			state.mode_new_calls.shell = (state.mode_new_calls.shell or 0) + 1
			return make_mode(input_obj)
		end,
	})
	helpers.stub_module("shell.mode.lua", {
		new = function(input_obj)
			state.mode_new_calls.lua = (state.mode_new_calls.lua or 0) + 1
			return make_mode(input_obj)
		end,
	})
	helpers.stub_module("agent.mode.agent", {
		new = function(input_obj)
			state.mode_new_calls.agent = (state.mode_new_calls.agent or 0) + 1
			return make_mode(input_obj)
		end,
	})

	for module_path, mode_name in pairs(user_module_names) do
		local custom_mode = user_modules[module_path]
		helpers.stub_module(module_path, {
			new = function(input_obj)
				state.mode_new_calls[mode_name] = (state.mode_new_calls[mode_name] or 0) + 1
				if custom_mode then
					return custom_mode
				end
				return make_mode(input_obj)
			end,
		})
	end

	helpers.stub_module("shell.builtins", {})
	helpers.stub_module("shell.utils.pipeline", {
		parse_cmdline = function(text)
			return nil
		end,
		run = function()
			return 0
		end,
	})
	helpers.stub_module("shell.theme", {
		renderer = { builtin_error = {} },
	})

	local shell_mod = helpers.load_module_from_src("shell", "src/shell/shell.lua")
	local shell = shell_mod.new()
	return shell, state
end

testify:that("always loads shell/lua/agent built-in modes with fixed shortcuts", function()
	local shell, state = setup_shell({
		mode_files = {},
	})

	testimony.assert_true(shell:has_mode("shell"))
	testimony.assert_true(shell:has_mode("lua"))
	testimony.assert_true(shell:has_mode("agent"))
	testimony.assert_equal("shell", shell:get_mode_for_shortcut("F1"))
	testimony.assert_equal("lua", shell:get_mode_for_shortcut("F2"))
	testimony.assert_equal("agent", shell:get_mode_for_shortcut("F3"))
	testimony.assert_true(shell:has_combo_handler("F1"))
	testimony.assert_true(shell:has_combo_handler("F2"))
	testimony.assert_true(shell:has_combo_handler("F3"))
	testimony.assert_equal(1, state.mode_new_calls.shell)
	testimony.assert_equal(1, state.mode_new_calls.lua)
	testimony.assert_equal(1, state.mode_new_calls.agent)
	testimony.assert_equal(3, state.input_new_calls)
end)

testify:that("ignores reserved shell/lua/agent json configs but still loads custom modes", function()
	local shell, state = setup_shell({
		mode_files = {
			["shell.json"] = true,
			["lua.json"] = true,
			["agent.json"] = true,
			["custom.json"] = true,
		},
		mode_payloads = {
			["shell.json"] = "cfg_shell_reserved",
			["lua.json"] = "cfg_lua_reserved",
			["agent.json"] = "cfg_agent_reserved",
			["custom.json"] = "cfg_custom",
		},
		decode_map = {
			cfg_shell_reserved = { path = "user.mode.override_shell", shortcut = "F9", history = true },
			cfg_lua_reserved = { path = "user.mode.override_lua", shortcut = "F10", history = true },
			cfg_agent_reserved = { path = "user.mode.override_agent", shortcut = "F11", history = true },
			cfg_custom = { path = "user.mode.custom", shortcut = "F4", history = true },
		},
		user_module_names = {
			["user.mode.override_shell"] = "override_shell",
			["user.mode.override_lua"] = "override_lua",
			["user.mode.override_agent"] = "override_agent",
			["user.mode.custom"] = "custom",
		},
	})

	testimony.assert_nil(state.read_mode_files["shell.json"])
	testimony.assert_nil(state.read_mode_files["lua.json"])
	testimony.assert_nil(state.read_mode_files["agent.json"])
	testimony.assert_equal(1, state.read_mode_files["custom.json"])
	testimony.assert_nil(state.mode_new_calls.override_shell)
	testimony.assert_nil(state.mode_new_calls.override_lua)
	testimony.assert_nil(state.mode_new_calls.override_agent)
	testimony.assert_equal(1, state.mode_new_calls.custom)
	testimony.assert_equal("shell", shell:get_mode_for_shortcut("F1"))
	testimony.assert_equal("lua", shell:get_mode_for_shortcut("F2"))
	testimony.assert_equal("agent", shell:get_mode_for_shortcut("F3"))
	testimony.assert_equal("custom", shell:get_mode_for_shortcut("F4"))
end)

testify:that("rebinds reserved and taken user shortcuts to first free F4..F12", function()
	local shell = setup_shell({
		mode_files = {
			["alpha.json"] = true,
			["beta.json"] = true,
			["gamma.json"] = true,
		},
		mode_payloads = {
			["alpha.json"] = "cfg_alpha",
			["beta.json"] = "cfg_beta",
			["gamma.json"] = "cfg_gamma",
		},
		decode_map = {
			cfg_alpha = { path = "user.mode.alpha", shortcut = "F1", history = true },
			cfg_beta = { path = "user.mode.beta", shortcut = "F4", history = true },
			cfg_gamma = { path = "user.mode.gamma", shortcut = "F4", history = true },
		},
		user_module_names = {
			["user.mode.alpha"] = "alpha",
			["user.mode.beta"] = "beta",
			["user.mode.gamma"] = "gamma",
		},
	})

	testimony.assert_equal("alpha", shell:get_mode_for_shortcut("F4"))
	testimony.assert_equal("beta", shell:get_mode_for_shortcut("F5"))
	testimony.assert_equal("gamma", shell:get_mode_for_shortcut("F6"))
	testimony.assert_true(shell:has_combo_handler("F4"))
	testimony.assert_true(shell:has_combo_handler("F5"))
	testimony.assert_true(shell:has_combo_handler("F6"))
end)

testify:that("loads user mode without shortcut when F4..F12 pool is exhausted", function()
	local mode_files = {}
	local mode_payloads = {}
	local decode_map = {}
	local user_module_names = {}

	for i = 1, 10 do
		local mode_name = string.format("m%02d", i)
		mode_files[mode_name .. ".json"] = true
		mode_payloads[mode_name .. ".json"] = "cfg_" .. mode_name
		decode_map["cfg_" .. mode_name] = {
			path = "user.mode." .. mode_name,
			shortcut = "F1",
			history = true,
		}
		user_module_names["user.mode." .. mode_name] = mode_name
	end

	local shell = setup_shell({
		mode_files = mode_files,
		mode_payloads = mode_payloads,
		decode_map = decode_map,
		user_module_names = user_module_names,
	})

	testimony.assert_equal("m01", shell:get_mode_for_shortcut("F4"))
	testimony.assert_equal("m09", shell:get_mode_for_shortcut("F12"))
	testimony.assert_true(shell:has_mode("m10"))

	local m10_bound = false
	for _, bound_mode_name in pairs(shell:list_shortcuts()) do
		if bound_mode_name == "m10" then
			m10_bound = true
			break
		end
	end
	testimony.assert_false(m10_bound)
end)

testify:that("fails fast when mode is missing required get_input contract method", function()
	local stderr = ""
	local real_stderr = io.stderr
	local real_exit = os.exit
	io.stderr = {
		write = function(self, text)
			stderr = stderr .. tostring(text or "")
		end,
	}
	os.exit = function(code)
		error({ kind = "os.exit", code = code })
	end

	local ok, err = pcall(setup_shell, {
		mode_files = {
			["broken.json"] = true,
		},
		mode_payloads = {
			["broken.json"] = "cfg_broken",
		},
		decode_map = {
			cfg_broken = { path = "user.mode.broken", shortcut = "F4", history = true },
		},
		user_module_names = {
			["user.mode.broken"] = "broken",
		},
		user_modules = {
			["user.mode.broken"] = {
				can_handle_combo = function()
					return false
				end,
				handle_combo = function()
					return false
				end,
			},
		},
	})

	io.stderr = real_stderr
	os.exit = real_exit

	testimony.assert_false(ok)
	testimony.assert_equal("os.exit", err.kind)
	testimony.assert_equal(29, err.code)
	testimony.assert_true(stderr:match("mode `broken` is missing required method `get_input`") ~= nil)
end)

testify:that("fails fast when mode is missing required combo contract method", function()
	local stderr = ""
	local real_stderr = io.stderr
	local real_exit = os.exit
	io.stderr = {
		write = function(self, text)
			stderr = stderr .. tostring(text or "")
		end,
	}
	os.exit = function(code)
		error({ kind = "os.exit", code = code })
	end

	local ok, err = pcall(setup_shell, {
		mode_files = {
			["broken2.json"] = true,
		},
		mode_payloads = {
			["broken2.json"] = "cfg_broken2",
		},
		decode_map = {
			cfg_broken2 = { path = "user.mode.broken2", shortcut = "F4", history = true },
		},
		user_module_names = {
			["user.mode.broken2"] = "broken2",
		},
		user_modules = {
			["user.mode.broken2"] = {
				get_input = function()
					return {}
				end,
				handle_combo = function()
					return false
				end,
			},
		},
	})

	io.stderr = real_stderr
	os.exit = real_exit

	testimony.assert_false(ok)
	testimony.assert_equal("os.exit", err.kind)
	testimony.assert_equal(29, err.code)
	testimony.assert_true(stderr:match("mode `broken2` is missing required method `can_handle_combo`") ~= nil)
end)

testify:conclude()
