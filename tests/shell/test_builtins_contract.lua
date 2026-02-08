-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== shell builtins contract ==")

local setup_builtins = function()
	helpers.clear_modules({
		"std",
		"term",
		"term.widgets",
		"cjson.safe",
		"shell.utils",
		"dns.dig",
		"shell.theme",
		"shell.store",
		"markdown",
		"argparser",
		"string.buffer",
		"term.tss",
		"zxscr",
		"shell.builtins",
	})

	helpers.stub_module("std", {
		ps = {
			exec = function()
				return nil, "exec failed"
			end,
			setenv = function()
				return true
			end,
			unsetenv = function()
				return true
			end,
		},
		conv = {
			time_diff_human = function()
				return "1s"
			end,
			bytes_human = function(n)
				return tostring(n)
			end,
		},
		environ = function()
			return {}
		end,
	})
	helpers.stub_module("term", {
		write = function()
			return true
		end,
		title = function()
			return true
		end,
	})
	helpers.stub_module("term.widgets", {})
	helpers.stub_module("cjson.safe", {
		decode = function()
			return {}
		end,
		encode = function()
			return "{}"
		end,
	})
	helpers.stub_module("shell.utils", {
		wg_info = function()
			return {
				wg0 = {
					pub_key = "pub",
					peers = {
						peer = {
							endpoint = nil,
							last_handshake = 0,
							bytes = { rx = 1, tx = 2 },
							nets = { "10.0.0.0/24" },
						},
					},
				},
			}
		end,
		wg_apply = function()
			return true
		end,
		wg_down = function()
			return true
		end,
	})
	helpers.stub_module("dns.dig", { config = {} })
	helpers.stub_module("shell.theme", {
		renderer = {
			builtin_error = {},
		},
	})
	helpers.stub_module("shell.store", {
		new = function()
			return {
				list_snippets = function()
					return {}
				end,
				get_snippet = function()
					return nil
				end,
				close = function()
					return true
				end,
				load_history = function()
					return {}
				end,
			}
		end,
	})
	helpers.stub_module("markdown", {
		render = function(text)
			return tostring(text or "")
		end,
	})
	helpers.stub_module("argparser", {
		command = function()
			return {
				summary = function(self)
					return self
				end,
				description = function(self)
					return self
				end,
				option = function(self)
					return self
				end,
				argument = function(self)
					return self
				end,
				command = function(self, _, _)
					return self
				end,
				build = function(self)
					return {
						cfg = {},
						parse = function()
							return nil, { kind = "help" }
						end,
					}
				end,
			}
		end,
		format_error = function()
			return ""
		end,
	})
	helpers.stub_module("string.buffer", {
		new = function()
			return {
				put = function() end,
				get = function()
					return ""
				end,
			}
		end,
	})
	helpers.stub_module("term.tss", {
		new = function()
			return {
				apply = function(_, _, value)
					return { text = tostring(value or "") }
				end,
				set_property = function()
					return true
				end,
				get_property = function()
					return 0
				end,
			}
		end,
	})
	helpers.stub_module("zxscr", {
		display = function()
			return true
		end,
	})

	return helpers.load_module_from_src("shell.builtins", "src/shell/shell/builtins.lua")
end

testify:that("wgcli list path returns explicit success status", function()
	local builtins = setup_builtins()
	local wgcli = builtins.get("wgcli")
	local status = wgcli.func("wgcli", {})
	testimony.assert_equal(0, status)
end)

testify:that("exec builtin returns explicit error when command is missing", function()
	local builtins = setup_builtins()
	local exec_builtin = builtins.get("exec")
	local status = exec_builtin.func("exec", {})
	testimony.assert_equal(127, status)
end)

testify:conclude()
