-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local term = require("term")
local theme = require("theme").get("shell")
local style = require("term.tss")
local tss = style.new(theme)
local style_text = function(ctx, ...)
	return ctx:apply(...).text
end

local defaults = {
	auto_echo = true,
	continue_on_incomplete = true,
	meta_prefix = ":",
	pretty_print = true,
	pretty_max_depth = 3,
	pretty_max_items = 24,
	preloads = {
		std = "std",
		web = "web",
		redis = "redis",
		crypto = "crypto",
		json = "cjson.safe",
		term = "term",
		dig = "dns.dig",
		wg = "wireguard",
	},
}

local normalize_error = function(err)
	local msg = tostring(err or "")
	msg = msg:gsub('^%[string "=?[^"]+"%]:(%d+):%s*', "")
	msg = msg:gsub("^[^:]+:%d+:%s*", "")
	return msg
end

local is_incomplete_error = function(err)
	return tostring(err or ""):match("<eof>") ~= nil
end

local write_separator = function()
	term.write(style_text(tss, "repl.lua.separator") .. "\n")
end

local format_value = function(self, value, visited, depth)
	visited = visited or {}
	depth = depth or 0

	local value_type = type(value)
	if value_type == "string" then
		return string.format("%q", value)
	end
	if value_type ~= "table" then
		return tostring(value)
	end

	if visited[value] then
		return "{<cycle>}"
	end
	if depth >= self.cfg.pretty_max_depth then
		return "{...}"
	end

	visited[value] = true
	local keys = {}
	for key, _ in pairs(value) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local out = {}
	for idx, key in ipairs(keys) do
		if idx > self.cfg.pretty_max_items then
			table.insert(out, "...")
			break
		end
		local rendered_key
		if type(key) == "string" and key:match("^[%a_][%w_]*$") then
			rendered_key = key
		else
			rendered_key = "[" .. format_value(self, key, visited, depth + 1) .. "]"
		end
		local rendered_value = format_value(self, value[key], visited, depth + 1)
		table.insert(out, rendered_key .. "=" .. rendered_value)
	end
	visited[value] = nil
	return "{" .. table.concat(out, ", ") .. "}"
end

local write_values = function(self, ...)
	local count = select("#", ...)
	if count == 0 then
		return
	end
	local out = {}
	for i = 1, count do
		local value = select(i, ...)
		if self.cfg.pretty_print then
			out[i] = format_value(self, value)
		else
			out[i] = tostring(value)
		end
	end
	term.write(table.concat(out, "\t") .. "\n")
end

local get_input = function(self)
	return self.__state.input
end

local compile_in_env = function(self, code)
	local ok, chunk_or_nil, err_or_nil = pcall(load, code, "=lua", "t", self.__state.repl_env)
	if ok and chunk_or_nil then
		return chunk_or_nil, nil
	end

	local err = err_or_nil
	if not ok then
		err = chunk_or_nil
	end

	if setfenv then
		local chunk
		chunk, err = load(code, "=lua")
		if chunk then
			setfenv(chunk, self.__state.repl_env)
			return chunk, nil
		end
	end
	return nil, err
end

local compile_chunk = function(self, code)
	local chunk, err = compile_in_env(self, code)
	if chunk then
		return chunk, "statement", nil, false
	end

	if self.cfg.continue_on_incomplete and is_incomplete_error(err) then
		return nil, nil, normalize_error(err), true
	end

	if self.cfg.auto_echo then
		local expression_chunk, expression_err = compile_in_env(self, "return " .. code)
		if expression_chunk then
			return expression_chunk, "expression", nil, false
		end
		if self.cfg.continue_on_incomplete and is_incomplete_error(expression_err) then
			return nil, nil, normalize_error(expression_err), true
		end
		return nil, nil, normalize_error(expression_err), false
	end

	return nil, nil, normalize_error(err), false
end

local execute_chunk = function(self, chunk, chunk_mode)
	local result = table.pack(xpcall(chunk, function(runtime_err)
		return debug.traceback(tostring(runtime_err), 2)
	end))
	if not result[1] then
		return 255, normalize_error(result[2])
	end

	if chunk_mode == "expression" and self.cfg.auto_echo then
		write_values(self, table.unpack(result, 2, result.n))
	end

	get_input(self):completion_update_source("lua_symbols", self.__state.repl_env)
	return 0, nil
end

local build_repl_env = function(self)
	local repl_env = {}
	setmetatable(repl_env, { __index = _G })
	repl_env._G = repl_env
	repl_env._VERSION = _VERSION

	local preload_errors = {}
	local names = std.tbl.sort_keys(self.cfg.preloads)
	for _, name in ipairs(names) do
		local module_name = self.cfg.preloads[name]
		local ok, mod_or_err = pcall(require, module_name)
		if ok then
			repl_env[name] = mod_or_err
		else
			preload_errors[name] = tostring(mod_or_err)
		end
	end

	return repl_env, preload_errors
end

local reset_env = function(self)
	self.__state.repl_env, self.__state.preload_errors = build_repl_env(self)
	get_input(self):completion_update_source("lua_symbols", self.__state.repl_env)
end

local parse_meta_command = function(self, code)
	local trimmed = (code or ""):match("^%s*(.-)%s*$") or ""
	if trimmed == "" then
		return nil
	end
	local escaped_prefix = std.escape_magic_chars(self.cfg.meta_prefix)
	if not trimmed:match("^" .. escaped_prefix) then
		return nil
	end

	local body = trimmed:sub(#self.cfg.meta_prefix + 1)
	local cmd, args = body:match("^([%w_%-]+)%s*(.*)$")
	if not cmd then
		return "", ""
	end
	return cmd, args
end

local globals_meta = function(self, args)
	local keys = {}
	local pattern = args ~= "" and args or nil
	if pattern then
		local ok = pcall(string.match, "", pattern)
		if not ok then
			return 255, "invalid lua pattern for :globals"
		end
	end
	for key, _ in pairs(self.__state.repl_env) do
		if type(key) == "string" and (not pattern or key:match(pattern)) then
			table.insert(keys, key)
		end
	end
	table.sort(keys)

	if #keys == 0 then
		term.write("no globals\n")
		return 0
	end

	for _, key in ipairs(keys) do
		term.write(key .. "\t" .. type(self.__state.repl_env[key]) .. "\n")
	end
	return 0
end

local help_meta = function(self)
	term.write("Lua REPL commands:\n")
	term.write(":help                     show this help\n")
	term.write(":reset                    reset REPL state\n")
	term.write(":globals [pattern]        list REPL globals\n")
	term.write(":modules                  list configured preloaded modules\n")
	term.write(":type <expr-or-name>      show result types\n")
	term.write(":doc <name>               inspect symbol information\n")
	term.write("SHIFT+ENTER               insert newline\n")
	term.write("ENTER                     execute when chunk is complete\n")
	local failures = std.tbl.sort_keys(self.__state.preload_errors)
	if #failures > 0 then
		term.write("failed preloads:\n")
		for _, name in ipairs(failures) do
			term.write("  " .. name .. ": " .. self.__state.preload_errors[name] .. "\n")
		end
	end
	return 0
end

local run_meta_command = function(self, cmd, args)
	if cmd == "" or cmd == "help" then
		return help_meta(self)
	end
	if cmd == "reset" then
		self:reset_env()
		term.write("lua state has been reset\n")
		return 0
	end
	if cmd == "globals" then
		return globals_meta(self, args)
	end
	if cmd == "modules" then
		local modules = std.tbl.sort_keys(self.cfg.preloads)
		for _, name in ipairs(modules) do
			local loaded = self.__state.repl_env[name] ~= nil
			term.write(name .. "\t" .. self.cfg.preloads[name] .. "\t" .. (loaded and "loaded" or "missing") .. "\n")
		end
		return 0
	end
	if cmd == "type" then
		if args == "" then
			return 255, "usage: :type <expression-or-name>"
		end
		local type_chunk, type_err = compile_in_env(self, "return " .. args)
		if not type_chunk then
			return 255, normalize_error(type_err)
		end
		local result = table.pack(xpcall(type_chunk, function(runtime_err)
			return debug.traceback(tostring(runtime_err), 2)
		end))
		if not result[1] then
			return 255, normalize_error(result[2])
		end
		if result.n == 1 then
			term.write("nil\n")
			return 0
		end
		local out = {}
		for i = 2, result.n do
			out[#out + 1] = type(result[i])
		end
		term.write(table.concat(out, "\t") .. "\n")
		return 0
	end
	if cmd == "doc" then
		if args == "" then
			return 255, "usage: :doc <name>"
		end
		local value = self.__state.repl_env[args]
		if value == nil and args:match("^[%a_][%w_]*(%.[%a_][%w_]*)*$") then
			local ctx = self.__state.repl_env
			for part in args:gmatch("([%a_][%w_]*)") do
				if type(ctx) ~= "table" then
					ctx = nil
					break
				end
				local next_value = rawget(ctx, part)
				if next_value == nil then
					local mt = getmetatable(ctx)
					local idx = mt and mt.__index
					if type(idx) == "table" then
						next_value = idx[part]
					end
				end
				ctx = next_value
			end
			value = ctx
		end
		if value == nil then
			term.write(args .. ": nil\n")
			return 0
		end
		local value_type = type(value)
		term.write(args .. ": " .. value_type .. "\n")
		if value_type == "table" then
			local keys = {}
			for key, _ in pairs(value) do
				if type(key) == "string" then
					table.insert(keys, key)
				end
			end
			table.sort(keys)
			if #keys == 0 then
				term.write("table is empty\n")
				return 0
			end
			for i, key in ipairs(keys) do
				if i > self.cfg.pretty_max_items then
					term.write("...\n")
					break
				end
				term.write("  " .. key .. "\t" .. type(value[key]) .. "\n")
			end
			return 0
		end
		if value_type == "function" then
			local info = debug.getinfo(value, "nSu")
			if info then
				if info.name and info.name ~= "" then
					term.write("name: " .. info.name .. "\n")
				end
				if info.short_src then
					term.write("source: " .. info.short_src .. "\n")
				end
				if info.linedefined then
					term.write("line: " .. tostring(info.linedefined) .. "\n")
				end
			end
			return 0
		end
		term.write(format_value(self, value) .. "\n")
		return 0
	end
	return 255, "unknown lua repl command: :" .. tostring(cmd)
end

local run = function(self)
	local code = get_input(self):get_content() or ""
	if code:match("^%s*$") then
		return 0
	end

	local cmd, args = parse_meta_command(self, code)
	if cmd then
		return self:run_meta_command(cmd, args)
	end

	local chunk, chunk_mode, err, incomplete = compile_chunk(self, code)
	if incomplete then
		return 0, nil, code .. "\n\n", true
	end
	if not chunk then
		return 255, err
	end

	write_separator()
	local status, run_err = execute_chunk(self, chunk, chunk_mode)
	write_separator()
	return status, run_err
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

local new = function(input, config)
	local cfg = std.tbl.merge({}, defaults)
	cfg.preloads = std.tbl.merge({}, defaults.preloads)
	if config then
		cfg = std.tbl.merge(cfg, config)
		if config.preloads then
			cfg.preloads = std.tbl.merge(cfg.preloads, config.preloads)
		end
	end

	local mode = {
		cfg = cfg,
		__state = {
			repl_env = {},
			preload_errors = {},
			input = input,
			combos = {},
		},
		run = run,
		reset_env = reset_env,
		run_meta_command = run_meta_command,
		get_input = get_input,
		can_handle_combo = can_handle_combo,
		handle_combo = handle_combo,
	}
	mode:reset_env()
	return mode
end

return {
	new = new,
}
