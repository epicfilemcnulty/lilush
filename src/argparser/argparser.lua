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
]]

local std = require("std")

local map_short_flag = function(self, flag)
	for name, obj in pairs(self.schema) do
		local short = obj.short or name:match("^(.)")
		-- positional arguments are not allowed to have flags, they have positions, for chrissake!
		if short == flag and not obj.idx then
			return name
		end
	end
	return nil
end

local map_positional_arg = function(self, arg)
	local positionals = {}
	for name, obj in pairs(self.schema) do
		if obj.idx then
			table.insert(positionals, obj)
			positionals[#positionals].name = name
		end
	end
	table.sort(positionals, function(a, b)
		return a.idx < b.idx
	end)
	for i, v in ipairs(positionals) do
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
		if not std.file_exists(arg) then
			return nil, "`" .. arg .. "`{.file} file does not exist"
		end
	end
	if kind == "dir" then
		if not std.dir_exists(arg) then
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

local parse = function(self, args)
	local args = args or {}
	if args[1] == "--help" or args[1] == "-?" then
		return nil, self.help_text .. tostring(self.schema), true
	end
	local i = 1
	while i <= #args do
		local hyphens, flags = args[i]:match("^(%-%-?)(%w+)")
		if hyphens and flags then
			if #hyphens == 2 then
				local flag = flags
				if not self.schema[flag] or self.schema[flag].idx then
					return nil, "No such flag `" .. flag .. "`{.flag}"
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
					local flag = self:map_short_flag(f)
					if not flag then
						return nil, "No such flag `" .. f .. "`{.flag}"
					end
					-- when the flag requires a value, it should be
					-- the last flag in the string of flags
					if self.schema[flag].kind ~= "bool" and not flags:match(f .. "$") then
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
			local flag = self:map_positional_arg(arg)
			if not flag then
				return nil, "Too many arguments"
			end
			local ok, err = self:validate_arg(flag, arg)
			if ok == nil then
				return nil, err
			end
		end
		i = i + 1
	end
	-- Set defaults and check for required arguments
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

local new = function(schema, help)
	local help = help or ""
	local schema = schema or {}
	local mt = {
		__tostring = function(tbl)
			return "\n## Arguments table\n\n" .. table.concat(std.pipe_table(prepare_data(tbl)), "\n") .. "\n"
		end,
	}
	setmetatable(schema, mt)
	return {
		help_text = help,
		parsed = {},
		parse = parse,
		schema = schema,
		validate_arg = validate_arg,
		map_short_flag = map_short_flag,
		map_positional_arg = map_positional_arg,
	}
end

return { new = new }
