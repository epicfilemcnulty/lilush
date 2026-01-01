-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

--[[

  Command line arguments parser, inspired by python's argparse.

  Example usage:

  ```Lua
  local argparser = require("argparser")
  local help_msg = "Command's help message"
  local parser = argparser.new(
    {
        long = { kind = "bool", note = "Flag's description" },
        count = { kind = "num", default = 1, note = "Flag's description" },
        pathname = { kind = "file", idx = 1 },
    }, help_msg
  )
  local args, err, help = parser:parse(args)
  if err then
      if help then
          -- when the first flag is set to `-?` or `--help`
          -- parser will return usage message in the `err` and set `help` to true.
          print(err)
          return 0
      end
      errmsg(err)
      return 127
  end
  -- Now all args are set and validated, you can use them safely:
  print(args.long)
  print(args.count + 1)
  ```

  Note: use `--` to stop flag parsing and pass positional arguments
  that start with a hyphen (e.g., `-- -file`).
]]

local std = require("std")

local new

local map_short_flag = function(self, flag)
	if self.short_flag_conflicts[flag] then
		return nil, "Ambiguous short flag `" .. flag .. "`{.flag}"
	end
	return self.short_flag_map[flag]
end

local map_positional_arg = function(self, arg)
	for i, v in ipairs(self.positionals) do
		if self.parsed[v.name] == nil then
			return v.name
		end
		if v.multi then
			return v.name
		end
	end
	return nil
end

local validate_arg = function(self, name, arg)
	local kind = self.schema[name].kind
	local arg = arg
	if kind == "num" then
		arg = tonumber(arg)
		if arg == nil then
			return nil, "`" .. name .. "`{.num} must be a number"
		end
	end
	if kind == "file" then
		local stat = std.fs.stat(arg)
		if not stat or not stat.mode:match("[fl]") then
			return nil, "`" .. arg .. "`{.file} file does not exist"
		end
	end
	if kind == "dir" then
		local stat = std.fs.stat(arg)
		if not stat or not stat.mode:match("[dl]") then
			return nil, "`" .. arg .. "`{.dir} directory does not exist"
		end
	end
	if kind == "str" then
		arg = tostring(arg)
		if arg == nil then
			return "`" .. name .. "`{.str} must be a string"
		end
	end
	if kind == "bool" then
		arg = true
	end
	if self.schema[name].multi then
		if self.parsed[name] == nil then
			self.parsed[name] = {}
		end
		table.insert(self.parsed[name], arg)
	else
		self.parsed[name] = arg
	end
	return true
end

local apply_defaults = function(self)
	for name, obj in pairs(self.schema) do
		if obj.kind == "bool" and self.parsed[name] == nil then
			self.parsed[name] = false
		end
		if obj.default == nil and self.parsed[name] == nil then
			return nil, "`" .. name .. "` argument is not provided"
		end
		if obj.default and self.parsed[name] == nil then
			self.parsed[name] = obj.default
		end
	end
	return true
end

local format_subcommands = function(self)
	if not self.subs then
		return ""
	end
	local names = {}
	for name, _ in pairs(self.subs) do
		table.insert(names, name)
	end
	table.sort(names)
	local lines = { "\n## Subcommands\n" }
	for _, name in ipairs(names) do
		local note = ""
		if self.subs[name].help then
			note = self.subs[name].help
		elseif self.subs[name].note then
			note = self.subs[name].note
		end
		if note ~= "" then
			table.insert(lines, "- `" .. name .. "`: " .. note)
		else
			table.insert(lines, "- `" .. name .. "`")
		end
	end
	return "\n" .. table.concat(lines, "\n") .. "\n"
end

local slice_args = function(args, start_idx)
	local sliced = {}
	for i = start_idx, #args do
		table.insert(sliced, args[i])
	end
	return sliced
end

local parse_core = function(self, args, stop_at_subcommand)
	local i = 1
	local stop_parsing = false
	while i <= #args do
		if not stop_parsing and args[i] == "--" then
			stop_parsing = true
			i = i + 1
		else
			local hyphens, flags = nil, nil
			if not stop_parsing then
				hyphens, flags = args[i]:match("^(%-%-?)(%w+)")
			end
			if hyphens and flags then
				if #hyphens == 2 then
					local flag = flags
					if not self.schema[flag] or self.schema[flag].idx then
						return nil, "No such flag `" .. flag .. "`{.flag}"
					end
					if self.schema[flag].kind ~= "bool" and args[i + 1] == nil then
						return nil, "`" .. flag .. "`{.flag} flag requires a value"
					end
					local ok, err = self:validate_arg(flag, args[i + 1])
					if ok == nil then
						return nil, err
					end
					if self.schema[flag].kind ~= "bool" then
						i = i + 1
					end
				else
					for f in flags:gmatch(".") do
						local flag, flag_err = self:map_short_flag(f)
						if not flag then
							return nil, flag_err or ("No such flag `" .. f .. "`{.flag}")
						end
						-- when the flag requires a value, it should be
						-- the last flag in the string of flags
						if self.schema[flag].kind ~= "bool" and not flags:match(f .. "$") then
							return nil, "`" .. flag .. "`{.flag} flag requires a value"
						end
						if self.schema[flag].kind ~= "bool" and args[i + 1] == nil then
							return nil, "`" .. flag .. "`{.flag} flag requires a value"
						end
						local ok, err = self:validate_arg(flag, args[i + 1])
						if ok == nil then
							return nil, err
						end
						if self.schema[flag].kind ~= "bool" then
							i = i + 1
						end
					end
				end
			else
				local arg = args[i]
				if stop_at_subcommand and self.subs and self.subs[arg] then
					return true, nil, i, arg
				end
				local flag = self:map_positional_arg(arg)
				if not flag then
					if stop_at_subcommand and self.subs and #self.positionals == 0 then
						return nil, "No such subcommand `" .. arg .. "`{.flag}"
					end
					return nil, "Too many arguments"
				end
				local ok, err = self:validate_arg(flag, arg)
				if ok == nil then
					return nil, err
				end
			end
			i = i + 1
		end
	end
	return true
end

local parse = function(self, args)
	local args = args or {}
	if args[1] == "--help" or args[1] == "-?" then
		return nil, self.help_text .. tostring(self.schema) .. format_subcommands(self), true
	end
	if self.schema_error then
		return nil, self.schema_error
	end
	local ok, err, sub_idx, sub_name = parse_core(self, args, self.subs ~= nil)
	if ok == nil then
		return nil, err
	end
	local ok_defaults, err_defaults = apply_defaults(self)
	if ok_defaults == nil then
		return nil, err_defaults
	end
	if self.subs then
		if not sub_name then
			if self.default_subcommand then
				sub_name = self.default_subcommand
				sub_idx = #args + 1
			elseif self.subcommand_required then
				return nil, "No subcommand provided"
			end
			if not sub_name then
				return self.parsed
			end
		end
		local sub = self.subs[sub_name]
		if not sub or not sub.schema then
			return nil, "Subcommand `" .. sub_name .. "`{.flag} does not define a schema"
		end
		local subparser = new(sub.schema, sub.help)
		local sub_args = slice_args(args, sub_idx + 1)
		local sub_parsed, sub_err, sub_help = subparser:parse(sub_args)
		if sub_err then
			return nil, sub_err, sub_help
		end
		self.parsed.__sub = sub_name
		self.parsed.__args = sub_parsed
		return self.parsed
	end
	return self.parsed
end

-- Auxiliary function to covert `tbl` into a format suitable for std.pipe_table().
-- We use djot formatting.
local prepare_data = function(tbl)
	local headers = { "name", { "default", "center" }, { "flag/pos", "center" }, "note" }
	local data = {}

	for name, rest in pairs(tbl) do
		local default = rest.default
		if type(rest.default) == "table" then
			default = table.concat(rest.default, " ")
		end
		local fmt_name = "`" .. name .. "`"

		if rest.kind == "bool" and default == nil then
			default = "false"
		end
		if default == nil then
			default = ""
			fmt_name = fmt_name .. "{.req ." .. rest.kind .. "}"
		else
			if default == "" then
				-- empty string here breaks the pipe table rendering somehow,
				-- and it should be fixed! But for now let's just replace the empty
				-- string with a space :)
				default = " "
			end
			fmt_name = fmt_name .. "{." .. rest.kind .. "}"
			default = "`" .. tostring(default) .. "`{.def ." .. rest.kind .. "}"
		end
		local flag = rest.short or name:match("^(.)")
		if rest.idx then
			flag = rest.idx
			if rest.multi then
				flag = flag .. " .. "
			end
		end
		local note = ""
		if rest.note then
			note = rest.note
		end
		table.insert(data, { fmt_name, default, "*" .. flag .. "*", note })
	end
	table.sort(data, function(a, b)
		return tostring(a[3]) < tostring(b[3])
	end)
	return headers, data
end

new = function(schema, help, opts)
	local help = help or ""
	local schema = schema or {}
	local opts = opts or {}
	local subs = opts.subs
	local positionals = {}
	local short_flag_map = {}
	local short_flag_conflicts = {}
	for name, obj in pairs(schema) do
		if obj.idx then
			table.insert(positionals, { name = name, idx = obj.idx, multi = obj.multi })
		else
			local short = obj.short or name:match("^(.)")
			if short_flag_map[short] and short_flag_map[short] ~= name then
				short_flag_conflicts[short] = true
			else
				short_flag_map[short] = name
			end
		end
	end
	table.sort(positionals, function(a, b)
		return a.idx < b.idx
	end)
	local schema_error = nil
	for i, v in ipairs(positionals) do
		if v.multi and i < #positionals then
			schema_error = "`" .. v.name .. "` argument is multi and must be the last positional"
			break
		end
	end
	if not schema_error and subs and #positionals > 0 then
		schema_error = "Subcommands do not support positional arguments in the root command"
	end
	local default_subcommand = nil
	if not schema_error and subs then
		for name, sub in pairs(subs) do
			if sub.default then
				if default_subcommand and default_subcommand ~= name then
					schema_error = "Multiple default subcommands are not allowed"
					break
				end
				default_subcommand = name
			end
		end
	end
	local mt = {
		__tostring = function(tbl)
			if std.tbl.empty(tbl) then
				return "\n"
			end
			return "\n## Arguments table\n\n" .. table.concat(std.tbl.pipe_table(prepare_data(tbl)), "\n") .. "\n"
		end,
	}
	setmetatable(schema, mt)
	return {
		help_text = help,
		parsed = {},
		parse = parse,
		positionals = positionals,
		schema = schema,
		schema_error = schema_error,
		short_flag_conflicts = short_flag_conflicts,
		short_flag_map = short_flag_map,
		subs = subs,
		default_subcommand = default_subcommand,
		subcommand_required = opts.subcommand_required ~= false,
		validate_arg = validate_arg,
		map_short_flag = map_short_flag,
		map_positional_arg = map_positional_arg,
	}
end

return { new = new }
