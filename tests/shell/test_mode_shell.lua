-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== shell.mode.shell ==")

local setup_mode = function(options)
	options = options or {}
	local state = {
		completion_updates = {},
		completion_source_updates = {},
		prompt_toggles = {},
		prompt_set_calls = {},
		prompt_set_blocks_calls = {},
		setenv_calls = {},
		unsetenv_calls = {},
	}

	local chooser_result = options.chooser_result
	local parsed_pipeline = options.parsed_pipeline
	local pipeline_status = options.pipeline_status
	local lookup_binary = options.lookup_binary

	helpers.clear_modules({
		"std",
		"term",
		"term.widgets",
		"shell.utils.pipeline",
		"shell.builtins",
		"shell.theme",
		"term.tss",
		"shell.store",
		"vault",
		"shell.jobs",
		"shell.mode.shell",
	})

	helpers.stub_module("std", {
		fs = {
			dir_exists = function(path)
				return true
			end,
			mkdir = function(path)
				return true
			end,
			cwd = function()
				return "/tmp"
			end,
			file_exists = function(path)
				return false
			end,
			list_files = function(path)
				return {}
			end,
			list_dir = function(path)
				return {}
			end,
			read_file = function(path)
				return nil
			end,
		},
		hostname = function()
			return "host"
		end,
		tbl = {
			sort_keys = function(tbl)
				local keys = {}
				for k, _ in pairs(tbl or {}) do
					table.insert(keys, k)
				end
				table.sort(keys)
				return keys
			end,
			longest = function(items)
				local max = 0
				for _, v in ipairs(items or {}) do
					if #tostring(v) > max then
						max = #tostring(v)
					end
				end
				return max
			end,
			contains = function(items, value)
				for i, v in ipairs(items or {}) do
					if v == value then
						return i
					end
				end
				return false
			end,
			alphanumsort = function(items)
				table.sort(items)
				return items
			end,
		},
		ps = {
			setenv = function(name, value)
				table.insert(state.setenv_calls, { name = name, value = value })
				return true
			end,
			unsetenv = function(name)
				table.insert(state.unsetenv_calls, name)
				return true
			end,
		},
		environ = function()
			return {}
		end,
	})

	helpers.stub_module("term", {
		write = function(text)
			return true
		end,
	})
	helpers.stub_module("term.widgets", {
		chooser = function(items, opts)
			return chooser_result
		end,
		form = function(fields, opts)
			return { username = "u", password = "p" }
		end,
	})
	helpers.stub_module("shell.utils.pipeline", {
		parse = function(input)
			return parsed_pipeline or {}
		end,
		parse_cmdline = function(line)
			return nil
		end,
		run = function(p)
			return pipeline_status or 0
		end,
	})
	helpers.stub_module("shell.builtins", {
		errmsg = function(msg)
			return true
		end,
		get = function(cmd)
			return nil
		end,
	})
	helpers.stub_module("shell.theme", {
		widgets = {
			shell = {},
			python = {},
		},
	})
	helpers.stub_module("term.tss", {
		new = function()
			return {
				set_property = function(self, key, prop, value)
					return true
				end,
				apply = function(self, key, value)
					return { text = tostring(value or "") }
				end,
			}
		end,
	})
	helpers.stub_module("shell.store", {
		new = function()
			return {
				get_vault_token = function()
					return nil
				end,
				save_vault_token = function(self)
					return true
				end,
				close = function(self)
					return true
				end,
			}
		end,
	})
	helpers.stub_module("vault", {
		new = function(_, token)
			return {
				get_token = function(self)
					return token or "tok"
				end,
				get_token_ttl = function(self)
					return 60
				end,
				login = function(self)
					return true
				end,
				healthy = function(self)
					return true
				end,
				get_secret = function(self)
					return "secret"
				end,
			}
		end,
	})
	helpers.stub_module("shell.jobs", {
		new = function()
			return {
				poll = function() end,
			}
		end,
	})

	local mode_mod = helpers.load_module_from_src("shell.mode.shell", "src/shell/shell/mode/shell.lua")
	local input = {
		get_content = function(self)
			return self.content or ""
		end,
		completion_update = function(self)
			table.insert(state.completion_updates, true)
		end,
		completion_update_source = function(self, source_name, value)
			table.insert(state.completion_source_updates, { source = source_name, value = value })
		end,
		prompt_toggle_block = function(self, block)
			table.insert(state.prompt_toggles, block)
		end,
		prompt_set = function(self, payload)
			table.insert(state.prompt_set_calls, payload)
		end,
		prompt_blocks = function(self)
			return options.prompt_blocks or {}
		end,
		prompt_set_blocks = function(self, blocks)
			table.insert(state.prompt_set_blocks_calls, blocks)
		end,
		lookup_binary = function(self, cmd)
			if type(lookup_binary) == "function" then
				return lookup_binary(cmd)
			end
			if type(lookup_binary) == "table" then
				return lookup_binary[cmd]
			end
			return false
		end,
	}

	local mode = mode_mod.new(input)
	return mode, input, state
end

testify:that("alias and unalias update completion source and command expansion", function()
	local mode, input, state = setup_mode()

	local status = mode:alias("alias", { "ll", "ls", "-la" })
	testimony.assert_equal(0, status)
	testimony.assert_equal("ls -la /tmp", mode:replace_aliases("ll /tmp"))
	testimony.assert_equal("builtins", state.completion_source_updates[2].source)

	status = mode:unalias("unalias", { "ll" })
	testimony.assert_equal(0, status)
	testimony.assert_equal("ll /tmp", mode:replace_aliases("ll /tmp"))
end)

testify:that("combo contract delegates to prompt block chooser", function()
	local mode, input, state = setup_mode({ chooser_result = { "user", "dir" }, prompt_blocks = { "user" } })

	testimony.assert_true(mode:can_handle_combo("ALT+p"))
	local redraw = mode:handle_combo("ALT+p")
	testimony.assert_true(redraw)
	testimony.assert_equal(1, #state.prompt_set_blocks_calls)
	testimony.assert_equal("user", state.prompt_set_blocks_calls[1][1])
	testimony.assert_equal("dir", state.prompt_set_blocks_calls[1][2])
end)

testify:that("on_shell_exit deactivates python venv through pyvenv", function()
	local mode, input, state = setup_mode()

	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "VIRTUAL_ENV" then
			return "/tmp/venv"
		end
		if name == "PATH" then
			return "/usr/bin"
		end
		if name == "HOME" then
			return "/tmp"
		end
		if name == "USER" then
			return "tester"
		end
		return real_getenv(name)
	end

	mode.__state.old_path = "/opt/bin"
	local ok = mode:on_shell_exit()
	os.getenv = real_getenv

	testimony.assert_true(ok)
	testimony.assert_equal("PATH", state.setenv_calls[#state.setenv_calls].name)
	testimony.assert_equal("/opt/bin", state.setenv_calls[#state.setenv_calls].value)
	testimony.assert_equal("VIRTUAL_ENV", state.unsetenv_calls[1])
	testimony.assert_equal("python", state.prompt_toggles[1])
	testimony.assert_equal(1, #state.completion_updates)
end)

testify:that("run allows external commands found by binary lookup", function()
	local mode = setup_mode({
		parsed_pipeline = {
			{ cmd = "curl", args = { "http://example.com" } },
		},
		lookup_binary = {
			curl = true,
		},
		pipeline_status = 0,
	})

	local status, err = mode:run()
	testimony.assert_equal(0, status)
	testimony.assert_nil(err)
end)

testify:conclude()
