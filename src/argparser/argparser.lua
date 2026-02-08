-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local command

local normalize_type = function(kind)
	local mapping = {
		bool = "boolean",
		str = "string",
		num = "number",
		file = "file",
		dir = "dir",
		boolean = "boolean",
		string = "string",
		number = "number",
	}
	return mapping[kind] or "string"
end

local levenshtein = function(a, b)
	local la = #a
	local lb = #b
	if la == 0 then
		return lb
	end
	if lb == 0 then
		return la
	end
	local matrix = {}
	for i = 0, la do
		matrix[i] = { [0] = i }
	end
	for j = 0, lb do
		matrix[0][j] = j
	end
	for i = 1, la do
		for j = 1, lb do
			local cost = 1
			if a:sub(i, i) == b:sub(j, j) then
				cost = 0
			end
			local del = matrix[i - 1][j] + 1
			local ins = matrix[i][j - 1] + 1
			local sub = matrix[i - 1][j - 1] + cost
			local best = del
			if ins < best then
				best = ins
			end
			if sub < best then
				best = sub
			end
			matrix[i][j] = best
		end
	end
	return matrix[la][lb]
end

local suggest_one = function(target, candidates)
	local best
	local best_score
	for _, candidate in ipairs(candidates) do
		local score = levenshtein(target, candidate)
		if not best_score or score < best_score then
			best = candidate
			best_score = score
		end
	end
	if best and best_score and best_score <= 3 then
		return best
	end
	return nil
end

local build_usage_spec = function(cmd)
	local parts = { cmd.cfg.name }
	if #cmd.cfg.options > 0 then
		table.insert(parts, "[options]")
	end
	for _, arg in ipairs(cmd.cfg.arguments) do
		if arg.nargs == "1" then
			table.insert(parts, "<" .. arg.name .. ">")
		elseif arg.nargs == "?" then
			table.insert(parts, "[" .. arg.name .. "]")
		elseif arg.nargs == "*" then
			table.insert(parts, "[" .. arg.name .. "...]")
		elseif arg.nargs == "+" then
			table.insert(parts, "<" .. arg.name .. "...>")
		end
	end
	if next(cmd.cfg.subcommands) then
		table.insert(parts, "<subcommand>")
		table.insert(parts, "[args]")
	end
	return table.concat(parts, " ")
end

local build_usage = function(cmd)
	return "Usage: " .. build_usage_spec(cmd)
end

local code_type_class = function(kind)
	local mapping = {
		boolean = "bool",
		number = "num",
		string = "str",
		file = "file",
		dir = "dir",
	}
	return mapping[kind] or "str"
end

local fmt_code = function(text, classes)
	if not classes or #classes == 0 then
		return "`" .. text .. "`"
	end
	return "`" .. text .. "`{." .. table.concat(classes, " .") .. "}"
end

local fmt_default = function(value, kind)
	if value == nil then
		return ""
	end
	local t = type(value)
	local repr
	if t == "table" then
		local out = {}
		for i = 1, #value do
			out[i] = tostring(value[i])
		end
		if #out == 0 then
			repr = "[]"
		else
			repr = "[" .. table.concat(out, ", ") .. "]"
		end
	elseif t == "string" and value == "" then
		repr = '""'
	else
		repr = tostring(value)
	end
	return fmt_code(repr, { "def", code_type_class(kind or "string") })
end

local option_forms = function(opt, base_classes)
	local forms = {}
	local classes = std.tbl.copy(base_classes)
	table.insert(classes, "flag")
	if opt.short then
		if opt.type == "boolean" then
			table.insert(forms, fmt_code("-" .. opt.short, classes))
		else
			local short = fmt_code("-" .. opt.short, classes)
			local meta =
				fmt_code("<" .. (opt.metavar or string.upper(opt.name)) .. ">", { "meta", code_type_class(opt.type) })
			table.insert(forms, short .. " " .. meta)
		end
	end
	if opt.type == "boolean" then
		table.insert(forms, fmt_code("--" .. opt.long, classes))
		if opt.negatable then
			table.insert(forms, fmt_code("--no-" .. opt.long, { "opt", "flag", "neg", "bool" }))
		end
	else
		local long = fmt_code("--" .. opt.long, classes)
		local meta =
			fmt_code("<" .. (opt.metavar or string.upper(opt.name)) .. ">", { "meta", code_type_class(opt.type) })
		table.insert(forms, long .. " " .. meta)
	end
	return table.concat(forms, ", ")
end

local format_help = function(cmd)
	local lines = { "# " .. cmd.cfg.name, "" }
	if cmd.cfg.summary ~= "" then
		table.insert(lines, cmd.cfg.summary)
		table.insert(lines, "")
	end
	if cmd.cfg.description ~= "" then
		table.insert(lines, cmd.cfg.description)
		table.insert(lines, "")
	end
	table.insert(lines, "## Usage")
	table.insert(lines, "")
	table.insert(lines, fmt_code(build_usage_spec(cmd), { "meta" }))
	table.insert(lines, "")
	if #cmd.cfg.options > 0 then
		table.insert(lines, "## Options")
		table.insert(lines, "")
		table.insert(
			lines,
			table.concat(
				std.tbl.pipe_table(
					{ "name", "default:center", "forms", "note" },
					(function()
						local rows = {}
						for _, opt in ipairs(cmd.cfg.options) do
							local classes = { "opt", code_type_class(opt.type) }
							if opt.required then
								table.insert(classes, "req")
							end
							if opt.repeatable then
								table.insert(classes, "multi")
							end
							local name = fmt_code(opt.name, classes)
							local default = fmt_default(opt.default, opt.type)
							if default == "" and opt.type == "boolean" then
								default = fmt_default(false, "boolean")
							end
							local forms = option_forms(opt, classes)
							local notes = {}
							if opt.note ~= "" then
								table.insert(notes, opt.note)
							end
							if opt.repeatable then
								table.insert(notes, "repeatable")
							end
							if opt.choices and #opt.choices > 0 then
								table.insert(notes, "choices: " .. table.concat(opt.choices, ", "))
							end
							table.insert(rows, { name, default, forms, table.concat(notes, "; ") })
						end
						return rows
					end)()
				),
				"\n"
			)
		)
		table.insert(lines, "")
	end
	if #cmd.cfg.arguments > 0 then
		table.insert(lines, "## Arguments")
		table.insert(lines, "")
		table.insert(
			lines,
			table.concat(
				std.tbl.pipe_table(
					{ "name", "arity:center", "default:center", "note" },
					(function()
						local rows = {}
						for _, arg in ipairs(cmd.cfg.arguments) do
							local required = arg.required or arg.nargs == "+"
							local classes = { "arg", code_type_class(arg.type) }
							if required then
								table.insert(classes, "req")
							end
							if arg.nargs == "*" or arg.nargs == "+" then
								table.insert(classes, "multi")
							end
							local notes = {}
							if arg.note ~= "" then
								table.insert(notes, arg.note)
							end
							if arg.nargs == "+" then
								table.insert(notes, "one or more values")
							elseif arg.nargs == "*" then
								table.insert(notes, "zero or more values")
							elseif arg.nargs == "?" then
								table.insert(notes, "optional")
							end
							local arity_classes = { "meta" }
							if arg.nargs == "*" or arg.nargs == "+" then
								table.insert(arity_classes, "multi")
							else
								table.insert(arity_classes, "arg")
							end
							table.insert(rows, {
								fmt_code(arg.name, classes),
								fmt_code(arg.nargs, arity_classes),
								fmt_default(arg.default, arg.type),
								table.concat(notes, "; "),
							})
						end
						return rows
					end)()
				),
				"\n"
			)
		)
		table.insert(lines, "")
	end
	if #cmd.cfg.subcommand_order > 0 then
		table.insert(lines, "## Subcommands")
		table.insert(lines, "")
		table.insert(
			lines,
			table.concat(
				std.tbl.pipe_table(
					{ "name", "default:center", "summary" },
					(function()
						local rows = {}
						for _, name in ipairs(cmd.cfg.subcommand_order) do
							local sub = cmd.cfg.subcommands[name]
							local is_default = cmd.cfg.default_subcommand == name
							local default_cell = ""
							if is_default then
								default_cell = fmt_code("yes", { "def", "bool" })
							end
							table.insert(rows, {
								fmt_code(name, { "arg", "str" }),
								default_cell,
								sub.cfg.summary or "",
							})
						end
						return rows
					end)()
				),
				"\n"
			)
		)
	end
	return table.concat(lines, "\n")
end

local new_error = function(cmd, kind, code, message, suggestions)
	return {
		kind = kind,
		code = code,
		message = message,
		usage = build_usage(cmd),
		suggestions = suggestions,
	}
end

local validate_typed = function(kind, value)
	local t = normalize_type(kind)
	if t == "string" then
		return tostring(value)
	end
	if t == "number" then
		local num = tonumber(value)
		if num == nil then
			return nil, "must be a number"
		end
		return num
	end
	if t == "file" then
		local stat = std.fs.stat(value)
		if not stat or not stat.mode:match("[fl]") then
			return nil, "file does not exist"
		end
		return value
	end
	if t == "dir" then
		local stat = std.fs.stat(value)
		if not stat or not stat.mode:match("[dl]") then
			return nil, "directory does not exist"
		end
		return value
	end
	if t == "boolean" then
		if type(value) == "boolean" then
			return value
		end
		local lowered = tostring(value):lower()
		if lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on" then
			return true
		end
		if lowered == "0" or lowered == "false" or lowered == "no" or lowered == "off" then
			return false
		end
		return nil, "must be a boolean"
	end
	return tostring(value)
end

local add_option_value = function(parsed, opt, raw_value)
	local converted, err = validate_typed(opt.type, raw_value)
	if converted == nil then
		return nil, "`--" .. opt.long .. "` value " .. err
	end
	if opt.choices and #opt.choices > 0 then
		local found = false
		for _, choice in ipairs(opt.choices) do
			if tostring(choice) == tostring(converted) then
				found = true
				break
			end
		end
		if not found then
			return nil, "`--" .. opt.long .. "` must be one of: " .. table.concat(opt.choices, ", ")
		end
	end
	if opt.repeatable then
		if parsed[opt.name] == nil then
			parsed[opt.name] = {}
		end
		table.insert(parsed[opt.name], converted)
	else
		parsed[opt.name] = converted
	end
	return true
end

local apply_option_defaults = function(parsed, options)
	for _, opt in ipairs(options) do
		if parsed[opt.name] == nil then
			if opt.default ~= nil then
				parsed[opt.name] = opt.default
			elseif opt.type == "boolean" then
				parsed[opt.name] = false
			end
		end
		if opt.required and parsed[opt.name] == nil then
			return nil, "missing required option --" .. opt.long
		end
	end
	return true
end

local apply_argument_defaults = function(parsed, arguments)
	for _, arg in ipairs(arguments) do
		if parsed[arg.name] == nil then
			if arg.default ~= nil then
				parsed[arg.name] = arg.default
			elseif arg.nargs == "*" then
				parsed[arg.name] = {}
			end
		end
		if arg.required and parsed[arg.name] == nil then
			return nil, "missing required argument `" .. arg.name .. "`"
		end
		if arg.nargs == "+" then
			if parsed[arg.name] == nil or #parsed[arg.name] == 0 then
				return nil, "argument `" .. arg.name .. "` expects at least one value"
			end
		end
	end
	return true
end

local parse_tokens = function(cmd, argv)
	local parsed = {}
	local positionals = {}
	local stop_options = false
	local i = 1
	local long_keys = {}
	for long, _ in pairs(cmd.cfg.options_long) do
		table.insert(long_keys, long)
	end
	while i <= #argv do
		local token = argv[i]
		if token == "--help" or token == "-h" or token == "-?" then
			return nil, new_error(cmd, "help", "help", format_help(cmd))
		end
		if not stop_options and token == "--" then
			stop_options = true
			i = i + 1
		elseif not stop_options and token:match("^%-%-") then
			local long_expr = token:sub(3)
			local negated = false
			if long_expr:match("^no%-") then
				negated = true
				long_expr = long_expr:sub(4)
			end
			local name = long_expr
			local inline_value = nil
			if long_expr:find("=", 1, true) then
				name, inline_value = long_expr:match("^([^=]+)=(.*)$")
			end
			local opt = cmd.cfg.options_long[name]
			if not opt then
				local suggestion = suggest_one(name, long_keys)
				local suggestions = {}
				if suggestion then
					table.insert(suggestions, "--" .. suggestion)
				end
				return nil,
					new_error(cmd, "parse_error", "unknown_option", "unknown option `--" .. name .. "`", suggestions)
			end
			if negated then
				if opt.type ~= "boolean" then
					return nil,
						new_error(
							cmd,
							"parse_error",
							"invalid_negation",
							"`--no-" .. name .. "` only works for bool options"
						)
				end
				if not opt.negatable then
					return nil, new_error(cmd, "parse_error", "invalid_negation", "`--" .. name .. "` is not negatable")
				end
				parsed[opt.name] = false
				i = i + 1
			else
				if opt.type == "boolean" then
					local value = true
					if inline_value ~= nil then
						local converted, conv_err = validate_typed("boolean", inline_value)
						if converted == nil then
							return nil,
								new_error(cmd, "parse_error", "invalid_value", "`--" .. name .. "` " .. conv_err)
						end
						value = converted
					end
					parsed[opt.name] = value
					i = i + 1
				else
					local value = inline_value
					if value == nil then
						if argv[i + 1] == nil then
							return nil,
								new_error(
									cmd,
									"parse_error",
									"missing_value",
									"option `--" .. name .. "` requires a value"
								)
						end
						value = argv[i + 1]
						i = i + 1
					end
					local ok, val_err = add_option_value(parsed, opt, value)
					if ok == nil then
						return nil, new_error(cmd, "parse_error", "invalid_value", val_err)
					end
					i = i + 1
				end
			end
		elseif not stop_options and token:match("^%-%w") then
			local short_expr = token:sub(2)
			if short_expr:find("=", 1, true) then
				local short_name, value = short_expr:match("^([^=])=(.*)$")
				local opt = cmd.cfg.options_short[short_name]
				if not opt then
					return nil,
						new_error(cmd, "parse_error", "unknown_option", "unknown option `-" .. short_name .. "`")
				end
				if opt.type == "boolean" then
					return nil,
						new_error(
							cmd,
							"parse_error",
							"invalid_value",
							"boolean option `-" .. short_name .. "` does not take a value"
						)
				end
				local ok, val_err = add_option_value(parsed, opt, value)
				if ok == nil then
					return nil, new_error(cmd, "parse_error", "invalid_value", val_err)
				end
				i = i + 1
			else
				local j = 1
				while j <= #short_expr do
					local short_name = short_expr:sub(j, j)
					local opt = cmd.cfg.options_short[short_name]
					if not opt then
						return nil,
							new_error(cmd, "parse_error", "unknown_option", "unknown option `-" .. short_name .. "`")
					end
					if opt.type == "boolean" then
						parsed[opt.name] = true
						j = j + 1
					else
						local value = short_expr:sub(j + 1)
						if value == "" then
							if argv[i + 1] == nil then
								return nil,
									new_error(
										cmd,
										"parse_error",
										"missing_value",
										"option `-" .. short_name .. "` requires a value"
									)
							end
							value = argv[i + 1]
							i = i + 1
						end
						local ok, val_err = add_option_value(parsed, opt, value)
						if ok == nil then
							return nil, new_error(cmd, "parse_error", "invalid_value", val_err)
						end
						break
					end
				end
				i = i + 1
			end
		else
			table.insert(positionals, token)
			i = i + 1
		end
	end
	return parsed, nil, positionals
end

local parse_positionals = function(cmd, parsed, positionals)
	local arg_index = 1
	local pos_index = 1
	while arg_index <= #cmd.cfg.arguments do
		local arg = cmd.cfg.arguments[arg_index]
		if arg.nargs == "1" then
			local token = positionals[pos_index]
			if token == nil then
				return nil, "missing required argument `" .. arg.name .. "`"
			end
			local converted, err = validate_typed(arg.type, token)
			if converted == nil then
				return nil, "argument `" .. arg.name .. "` " .. err
			end
			parsed[arg.name] = converted
			pos_index = pos_index + 1
		elseif arg.nargs == "?" then
			local token = positionals[pos_index]
			if token ~= nil then
				local converted, err = validate_typed(arg.type, token)
				if converted == nil then
					return nil, "argument `" .. arg.name .. "` " .. err
				end
				parsed[arg.name] = converted
				pos_index = pos_index + 1
			end
		elseif arg.nargs == "*" or arg.nargs == "+" then
			local values = {}
			while pos_index <= #positionals do
				local converted, err = validate_typed(arg.type, positionals[pos_index])
				if converted == nil then
					return nil, "argument `" .. arg.name .. "` " .. err
				end
				table.insert(values, converted)
				pos_index = pos_index + 1
			end
			parsed[arg.name] = values
		end
		arg_index = arg_index + 1
	end
	if pos_index <= #positionals then
		return nil, "too many positional arguments"
	end
	return true
end

local parse = function(self, argv)
	local args = argv or {}
	self.__state = { parsed = {} }

	if next(self.cfg.subcommands) and #self.cfg.options == 0 and #self.cfg.arguments == 0 then
		local sub_name = args[1]
		if sub_name == "--help" or sub_name == "-h" or sub_name == "-?" then
			return nil, new_error(self, "help", "help", format_help(self))
		end
		if sub_name == nil then
			if self.cfg.default_subcommand then
				sub_name = self.cfg.default_subcommand
			elseif self.cfg.subcommand_required then
				return nil, new_error(self, "parse_error", "missing_subcommand", "no subcommand provided")
			else
				return {}
			end
		end
		local sub = self.cfg.subcommands[sub_name]
		if not sub then
			local names = {}
			for name, _ in pairs(self.cfg.subcommands) do
				table.insert(names, name)
			end
			local suggestion = suggest_one(sub_name, names)
			local suggestions = {}
			if suggestion then
				table.insert(suggestions, suggestion)
			end
			return nil,
				new_error(
					self,
					"parse_error",
					"unknown_subcommand",
					"unknown subcommand `" .. sub_name .. "`",
					suggestions
				)
		end
		local sub_argv = {}
		for i = 2, #args do
			table.insert(sub_argv, args[i])
		end
		local sub_parsed, sub_err = sub:parse(sub_argv)
		if sub_err then
			return nil, sub_err
		end
		local root_parsed = {
			__sub = sub_name,
			__args = sub_parsed,
			subcommand = sub_name,
			args = sub_parsed,
		}
		self.__state.parsed = root_parsed
		return root_parsed
	end

	local root_parsed, parse_err, positionals = parse_tokens(self, args)
	if parse_err then
		return nil, parse_err
	end

	if next(self.cfg.subcommands) then
		local sub_name = positionals[1]
		if sub_name == nil then
			if self.cfg.default_subcommand then
				sub_name = self.cfg.default_subcommand
			else
				if self.cfg.subcommand_required then
					return nil, new_error(self, "parse_error", "missing_subcommand", "no subcommand provided")
				end
			end
		end
		if sub_name then
			local sub = self.cfg.subcommands[sub_name]
			if not sub then
				local names = {}
				for name, _ in pairs(self.cfg.subcommands) do
					table.insert(names, name)
				end
				local suggestion = suggest_one(sub_name, names)
				local suggestions = {}
				if suggestion then
					table.insert(suggestions, suggestion)
				end
				return nil,
					new_error(
						self,
						"parse_error",
						"unknown_subcommand",
						"unknown subcommand `" .. sub_name .. "`",
						suggestions
					)
			end
			local sub_argv = {}
			for i = 2, #positionals do
				table.insert(sub_argv, positionals[i])
			end
			local sub_parsed, sub_err = sub:parse(sub_argv)
			if sub_err then
				return nil, sub_err
			end
			local ok_defaults, defaults_err = apply_option_defaults(root_parsed, self.cfg.options)
			if ok_defaults == nil then
				return nil, new_error(self, "parse_error", "missing_option", defaults_err)
			end
			root_parsed.__sub = sub_name
			root_parsed.__args = sub_parsed
			root_parsed.subcommand = sub_name
			root_parsed.args = sub_parsed
			self.__state.parsed = root_parsed
			return root_parsed
		end
	end

	local ok_positionals, pos_err = parse_positionals(self, root_parsed, positionals)
	if ok_positionals == nil then
		return nil, new_error(self, "parse_error", "invalid_argument", pos_err)
	end
	local ok_defaults, defaults_err = apply_option_defaults(root_parsed, self.cfg.options)
	if ok_defaults == nil then
		return nil, new_error(self, "parse_error", "missing_option", defaults_err)
	end
	local ok_arg_defaults, arg_defaults_err = apply_argument_defaults(root_parsed, self.cfg.arguments)
	if ok_arg_defaults == nil then
		return nil, new_error(self, "parse_error", "missing_argument", arg_defaults_err)
	end

	self.__state.parsed = root_parsed
	return root_parsed
end

local summary = function(self, text)
	self.cfg.summary = text or ""
	return self
end

local description = function(self, text)
	self.cfg.description = text or ""
	return self
end

local option = function(self, name, spec)
	local cfg = spec or {}
	local long_name = cfg.long or name:gsub("_", "-")
	local opt = {
		name = name,
		long = long_name,
		short = cfg.short,
		type = normalize_type(cfg.type or cfg.kind or "string"),
		default = cfg.default,
		required = cfg.required == true,
		repeatable = cfg.repeatable == true,
		negatable = cfg.negatable ~= false,
		choices = cfg.choices,
		metavar = cfg.metavar,
		note = cfg.note or cfg.help or "",
	}
	table.insert(self.cfg.options, opt)
	self.cfg.options_long[opt.long] = opt
	if opt.short then
		self.cfg.options_short[opt.short] = opt
	end
	return self
end

local argument = function(self, name, spec)
	local cfg = spec or {}
	local arg = {
		name = name,
		type = normalize_type(cfg.type or cfg.kind or "string"),
		nargs = cfg.nargs or "1",
		default = cfg.default,
		required = cfg.required ~= false,
		note = cfg.note or cfg.help or "",
	}
	if arg.nargs ~= "1" and arg.nargs ~= "?" and arg.nargs ~= "*" and arg.nargs ~= "+" then
		arg.nargs = "1"
	end
	if arg.nargs ~= "1" then
		arg.required = false
	end
	table.insert(self.cfg.arguments, arg)
	return self
end

local add_command = function(self, name, spec)
	local sub = command(name)
	if type(spec) == "function" then
		spec(sub)
	elseif type(spec) == "table" then
		if spec.summary then
			sub:summary(spec.summary)
		end
		if spec.description then
			sub:description(spec.description)
		end
	end
	if not self.cfg.subcommands[name] then
		table.insert(self.cfg.subcommand_order, name)
	end
	self.cfg.subcommands[name] = sub
	return self
end

local action = function(self, fn)
	self.cfg.action = fn
	return self
end

local build = function(self)
	for name, sub in pairs(self.cfg.subcommands) do
		if sub.cfg.default then
			if self.cfg.default_subcommand and self.cfg.default_subcommand ~= name then
				error("Multiple default subcommands are not allowed")
			end
			self.cfg.default_subcommand = name
		end
	end
	return self
end

command = function(name, opts)
	local cfg_opts = opts or {}
	return {
		cfg = {
			name = name or "cmd",
			summary = "",
			description = "",
			options = {},
			options_long = {},
			options_short = {},
			arguments = {},
			subcommands = {},
			subcommand_order = {},
			default_subcommand = cfg_opts.default_subcommand,
			subcommand_required = cfg_opts.subcommand_required ~= false,
			action = nil,
		},
		__state = { parsed = {} },
		summary = summary,
		description = description,
		option = option,
		argument = argument,
		command = add_command,
		action = action,
		build = build,
		parse = parse,
	}
end

local format_error = function(err)
	if not err then
		return ""
	end
	if type(err) ~= "table" then
		return tostring(err)
	end
	if err.kind == "help" and err.message and err.message ~= "" then
		return err.message
	end
	local parts = {}
	local has_usage_in_message = err.message and err.message:match("^Usage:")
	if err.usage and err.usage ~= "" and not has_usage_in_message then
		table.insert(parts, err.usage)
	end
	if err.message and err.message ~= "" then
		table.insert(parts, err.message)
	end
	if err.suggestions and #err.suggestions > 0 then
		table.insert(parts, "Did you mean: " .. table.concat(err.suggestions, ", ") .. "?")
	end
	return table.concat(parts, "\n")
end

return {
	command = command,
	format_help = format_help,
	format_error = format_error,
}
