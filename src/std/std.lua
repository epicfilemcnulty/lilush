-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local core = require("std.core")
local bit = require("bit")
local byte = string.byte
local buffer = require("string.buffer")

local utf
utf = {
	-- U+FFFD, generally used to replace invalid UTF-8 sequences
	replacement_symbol = string.char(0xEF, 0xBF, 0xBD),
	patterns = {
		glob = "[\1-\x7F\xC2-\xF4][\x80-\xBF]*",
		multibyte = "[\xC2-\xF4][\x80-\xBF]+",
		onebyte = "[\1-\x7F]",
		-- Although not UTF-8 related, but we alse want to have the ability
		-- to detect and count the number or of ANSI ESC sequences in the string
		sgr_csi_pattern = "\27%[[0-9;]-m",
	},
	-- Check if a byte is a valid starting byte for a multi-byte UTF-8 sequence
	valid_b1 = function(b1)
		if not b1 then
			return false
		end
		if byte(b1) < 0xC2 or byte(b1) > 0xF4 then
			return false
		end
		return true
	end,
	byte_count = function(b1)
		local first = string.byte(b1)
		return first >= 0xF0 and 3 or first >= 0xE0 and 2 or first >= 0xC0 and 1
	end,
	valid_seq = function(seq)
		if not seq or #seq == 0 then
			return false
		end
		local i = 0
		local first = ""
		for char in seq:gmatch(".") do
			i = i + 1
			if i == 1 then
				if not utf.valid_b1(char) then
					return false
				end
				first = char
			end
			if i == 2 then
				if byte(first) == 0xE0 and (byte(char) < 0xA0 or byte(char) > 0xBF) then
					return false
				elseif byte(first) == 0xED and (byte(char) < 0x80 or byte(char) > 0x9F) then
					return false
				elseif byte(first) == 0xF0 and (byte(char) < 0x90 or byte(char) > 0xBF) then
					return false
				elseif byte(first) == 0xF4 and (byte(char) < 0x90 or byte(char) > 0x8F) then
					return false
				end
			end
			if i >= 2 and (byte(char) < 0x80 or byte(char) > 0xBF) then
				return false
			end
		end
		return true
	end,
	len = function(str)
		local count = 0
		local esc_count = 0
		local str = str or ""
		if str:match(utf.patterns.sgr_csi_pattern) then
			str, esc_count = str:gsub(utf.patterns.sgr_csi_pattern, "")
		end
		for char in str:gmatch(utf.patterns.glob) do
			count = count + 1
		end
		return count, esc_count
	end,
	sub = function(str, i, j)
		if not str or not i then
			return nil, "no string or index"
		end
		local l = utf.len(str)
		local j = j or l
		-- Check and translate negative indices first
		if j < 0 then
			j = l + 1 + j
		end
		if i < 0 then
			i = l + 1 + i
		end
		-- Now do sanity checks
		if i < 1 then
			i = 1
		end
		if j > l then
			j = l
		end
		if i > j then
			return ""
		end
		local idx = 0
		local result = ""
		for char in str:gmatch(utf.patterns.glob) do
			idx = idx + 1
			if idx >= i and idx <= j then
				result = result .. char
			end
		end
		return result
	end,
	-- The `char()` func below is taken verbatim from [Lua-5.1-UTF-8](https://github.com/meepen/Lua-5.1-UTF-8),
	-- credits to [willox](https://github.com/willox), I suppose, judging by the commit history...
	--
	-- Takes zero or more integers and returns a string containing the UTF-8 representation of each
	char = function(...)
		local buf = {}
		for k, v in ipairs({ ... }) do
			if v < 0 or v > 0x10FFFF then
				return nil, "bad argument #" .. k .. " to char (out of range)"
			end

			local b1, b2, b3, b4 = nil, nil, nil, nil
			if v < 0x80 then -- Single-byte sequence
				table.insert(buf, string.char(v))
			elseif v < 0x800 then -- Two-byte sequence
				b1 = bit.bor(0xC0, bit.band(bit.rshift(v, 6), 0x1F))
				b2 = bit.bor(0x80, bit.band(v, 0x3F))
				table.insert(buf, string.char(b1, b2))
			elseif v < 0x10000 then -- Three-byte sequence
				b1 = bit.bor(0xE0, bit.band(bit.rshift(v, 12), 0x0F))
				b2 = bit.bor(0x80, bit.band(bit.rshift(v, 6), 0x3F))
				b3 = bit.bor(0x80, bit.band(v, 0x3F))
				table.insert(buf, string.char(b1, b2, b3))
			else -- Four-byte sequence
				b1 = bit.bor(0xF0, bit.band(bit.rshift(v, 18), 0x07))
				b2 = bit.bor(0x80, bit.band(bit.rshift(v, 12), 0x3F))
				b3 = bit.bor(0x80, bit.band(bit.rshift(v, 6), 0x3F))
				b4 = bit.bor(0x80, bit.band(v, 0x3F))
				table.insert(buf, string.char(b1, b2, b3, b4))
			end
		end
		return table.concat(buf, "")
	end,
}

local function setenv(name, value)
	return core.setenv(name, value)
end

local function readlink(pathname)
	return core.readlink(pathname)
end

local function unsetenv(name)
	return core.unsetenv(name)
end

local function kill(pid, signal)
	return core.kill(pid, signal)
end

local function dup(oldfd)
	return core.dup(oldfd)
end

local function dup2(oldfd, newfd)
	return core.dup2(oldfd, newfd)
end

local function fork()
	return core.fork()
end

-- It might be better to just return Lua FILE
-- objects from core.pipe instead of raw file descriptors,
-- then we could use io.write, io.read & co...
-- If only I were smart enough to do that, duh.
local function pipe()
	local p, err = core.pipe()
	if p == nil then
		return nil, err
	end
	local read = function(self, count)
		return core.read(self.out, count)
	end
	local write = function(self, data, count)
		return core.write(self.inn, data, count)
	end
	local close_read = function(self)
		core.close(self.out)
	end
	local close_write = function(self)
		core.close(self.inn)
	end
	setmetatable(p, { __index = { read = read, write = write, close_out = close_read, close_inn = close_write } })
	return p
end

local function getpid()
	return core.getpid()
end

local function exec(pathname, ...)
	local cmd_name = pathname:match("^.*/([^/]+)$")
	if not cmd_name then
		cmd_name = pathname
	end
	return core.exec(pathname, cmd_name, ...)
end

local function launch(cmd, stdin, stdout, stderr, ...)
	local pid = fork()
	if pid < 0 then
		return nil, "failed to fork"
	end
	if pid == 0 then --child
		if stdin then
			dup2(stdin, 0)
			core.close(stdin)
		end
		if stderr then
			dup2(stderr, 2)
			core.close(stderr)
		end
		if stdout then
			dup2(stdout, 1)
			core.close(stdout)
		end
		if type(cmd) == "table" then
			local status = cmd.func(cmd.name, { ... }, cmd.extra)
			os.exit(status)
		end
		exec(cmd, ...)
		os.exit(-1)
	end
	return pid
end

local function waitpid(pid)
	return core.waitpid(pid)
end

local function wait(pid)
	return core.wait(pid)
end

local function lines(raw)
	local raw = raw or ""
	local lines = {}
	if not raw:match("\n") then
		table.insert(lines, raw)
		return lines
	end
	for line in raw:gmatch("(.-)\r?\n") do
		table.insert(lines, line)
	end
	local tail = raw:match("\n([^\n\r]+)$")
	if tail then
		table.insert(lines, tail)
	end
	return lines
end

local exec_simple = function(cmd)
	local args = {}
	for arg in cmd:gmatch("%S+") do
		table.insert(args, arg)
	end
	local cmd = table.remove(args, 1)

	local stdout = pipe()
	local stderr = pipe()
	local pid = launch(cmd, nil, stdout.inn, stderr.inn, unpack(args))
	stdout:close_inn()
	stderr:close_inn()
	local out = stdout:read() or ""
	local err = stderr:read() or ""
	local out_lines = lines(out)
	local err_lines = lines(err)
	stdout:close_out()
	stderr:close_out()
	local _, code = waitpid(pid)

	return {
		status = code or 255,
		stdout = out_lines,
		stderr = err_lines,
	}
end

local exec_one_line = function(cmd)
	local result = exec_simple(cmd)
	if result and result.stdout[1] then
		return result.stdout[1]
	end
	return ""
end

local function sleep(seconds)
	core.sleep(seconds)
end

local function sleep_ms(milliseconds)
	core.sleep_ms(milliseconds)
end

local function chdir(pathname)
	return core.chdir(pathname)
end

local function cwd()
	return core.cwd()
end

local function stat(path)
	return core.stat(path)
end

local split_path_by_dir = function(pathname)
	local dirs = {}
	local path, last_dir = pathname:match("^(.-)/?([^/]-)$")
	repeat
		table.insert(dirs, last_dir)
		path, last_dir = path:match("^(.-)/?([^/]-)$")
	until path == ""
	table.insert(dirs, last_dir)
	local reversed = {}
	for i = #dirs, 1, -1 do
		table.insert(reversed, dirs[i])
	end
	return reversed
end

local function mkdir(pathname, mode, recursive)
	if recursive then
		local dirs = split_path_by_dir(pathname)
		local prefix = ""
		if pathname:match("^/") then
			prefix = "/"
		end
		for i, _ in ipairs(dirs) do
			local dir = prefix .. table.concat(dirs, "/", 1, i)
			local st = stat(dir)
			if not st then
				local s, err = core.mkdir(dir, mode)
				if not s then
					return nil, err
				end
			end
		end
		return true
	end
	return core.mkdir(pathname, mode)
end

local function list_dir(path)
	return core.list_dir(path)
end

local function fast_list_dir(path)
	return core.fast_list_dir(path)
end

local function symlink(src, dst)
	return core.symlink(src, dst)
end

local function empty_dir(path)
	local st = core.stat(path)
	if st and st.mode == "d" then
		local items = list_dir(path)
		if not items then
			return nil, "failed to get dir items"
		end
		if #items == 2 then
			return true
		end
		return false
	end
	return nil, "not a dir"
end

local function non_empty_dir(path)
	local r, err = empty_dir(path)
	if err then
		return nil, err
	end
	return not r
end

local function remove(path, recursive)
	if recursive then
		local st = core.stat(path)
		if st and st.mode == "d" then
			local items, err = list_dir(path)
			if not items then
				return nil, err
			end
			for _, f in ipairs(items) do
				if f ~= "." and f ~= ".." then
					local s, err = remove(path .. "/" .. f, true)
					if not s then
						return nil, err
					end
				end
			end
			return core.remove(path)
		end
	end
	return core.remove(path)
end

local function list_files(dir, pattern, mode, resolve_links)
	local resolve_links = resolve_links or false
	local files = {}
	local mode = mode or "f"
	local items, err = list_dir(dir)
	if items then
		local pattern = pattern or "^.*"
		for _, f in ipairs(items) do
			if f ~= "." and f ~= ".." then
				if f:match(pattern) then
					local st = core.stat(dir .. "/" .. f)
					if st and st.mode:match(mode) then
						local target
						if st.mode == "l" and resolve_links then
							target = readlink(dir .. "/" .. f)
						end
						files[f] = {
							mode = st.mode,
							size = st.size,
							perms = st.perms,
							uid = st.uid,
							gid = st.gid,
							target = target,
							atime = st.atime,
						}
					end
				end
			end
		end
		return files
	end
	return nil, err
end

local function dir_exists(filename)
	local st = core.stat(filename)
	if st and st.mode == "d" then
		return true
	end
	return false
end

local function file_exists(filename, mode)
	local mode = mode or "f"
	local st = core.stat(filename)
	if st and st.mode:match(mode) then
		return true
	end
	return false
end

local function read_file(filename)
	local f, err = io.open(filename, "r")
	if f then
		local lines = f:read("*a")
		f:close()
		return lines
	end
	return nil, err
end

local function write_file(filename, text)
	local f, err = io.open(filename, "w+")
	if f then
		f:write(text)
		f:close()
		return true
	end
	return nil, err
end

local system_users = function()
	local passwd_raw, err = read_file("/etc/passwd")
	local users = {}
	if passwd_raw then
		for line in passwd_raw:gmatch("(.-)\n") do
			local user, uid, gid = line:match("^([^:]+):x:([^:]+):([^:]+)")
			if user and uid and gid then
				users[tonumber(uid)] = { login = user, gid = tonumber(gid) }
			end
		end
	end
	setmetatable(users, {
		__index = function(tbl, key)
			return { login = "unknown", gid = "unknown" }
		end,
	})
	return users
end

local function render_table(t, indent)
	local t = t or "nil"
	if type(t) ~= "table" then
		return tostring(t)
	end
	local indent = indent or 1
	local buf = buffer.new()
	if indent == 1 then
		buf:put("{\n")
	end
	for k, v in pairs(t) do
		formatting = string.rep("  ", indent) .. k .. " = "
		if type(v) == "table" then
			buf:put(formatting .. "{\n", render_table(v, indent + 1), string.rep(" ", indent + indent), "},\n")
		elseif type(v) == "string" then
			buf:put(formatting, '"', v, '",\n')
		else
			buf:put(formatting, tostring(v), ",\n")
		end
	end
	if indent == 1 then
		buf:put("}\n")
	end
	return buf:get()
end

local print_table = function(t)
	print(render_table(t))
end

local table_deep_copy
table_deep_copy = function(source_table, _cyclic_cache)
	-- NOTE: We remember "seen" source tables, to avoid infinite loops with cyclic tables.
	local result = {}
	_cyclic_cache = _cyclic_cache or {}
	_cyclic_cache[source_table] = result
	for key, value in pairs(source_table) do
		if type(value) == "table" then
			-- Check cyclic cache for a previous result.
			-- NOTE: We use "ternary" assignment, since we can be sure that every
			-- value in the "cyclic cache" is "truthy" (they're always tables).
			result[key] = _cyclic_cache[value] or table_deep_copy(value, _cyclic_cache)
		else
			result[key] = value
		end
	end

	return result
end

local function merge_tables(defaults, options)
	local defaults = defaults or {}
	if options then
		for k, v in pairs(options) do
			if (type(v) == "table") and (type(defaults[k] or false) == "table") then
				merge_tables(defaults[k], options[k])
			else
				defaults[k] = v
			end
		end
	end
	return defaults
end

local function get_nested_value(tbl, value)
	local obj = tbl
	for e in value:gmatch("([^.]+)%.?") do
		if not obj[e] then
			return nil
		end
		obj = obj[e]
	end
	return obj
end
--[[
    `alphanumsort` below is authored by [Paul Kulchenko](http://kulchenko.com/), 
    the creator of [ZeroBrane Studio Lua IDE](https://studio.zerobrane.com/).

    See [notebook](http://notebook.kulchenko.com/algorithms/alphanumeric-natural-sorting-for-humans-in-lua)
    for the details and variants of the implementation with different "precision".

]]
--
local alphanumsort = function(o)
	local function padnum(d)
		local r = string.match(d, "0*(.+)")
		return ("%03d%s"):format(#r, r)
	end
	table.sort(o, function(a, b)
		return tostring(a):gsub("%d+", padnum) < tostring(b):gsub("%d+", padnum)
	end)
	return o
end

local function sort_keys(t)
	local tkeys = {}
	for k in pairs(t) do
		table.insert(tkeys, k)
	end
	return alphanumsort(tkeys)
end

local function include_keys(t, pattern)
	local t = t or {}
	local pattern = pattern or ".*"
	local matched = {}
	for _, v in ipairs(t) do
		if v:match("^" .. pattern) then
			table.insert(matched, v)
		end
	end
	return matched
end

local function exclude_keys(t, pattern)
	local t = t or {}
	local pattern = pattern or ".*"
	local matched = {}
	for _, v in ipairs(t) do
		if not v:match("^" .. pattern) then
			table.insert(matched, v)
		end
	end
	return matched
end

local function longest(t)
	local max = 0
	local t = t or {}
	for _, v in ipairs(t) do
		local utf_len = utf.len(v)
		if utf_len > max then
			max = utf_len
		end
	end
	return max
end

local function envsubst(filename)
	local content, err = read_file(filename)
	if content then
		return content:gsub("{{([%w%d_]+)}}", function(cap)
			return os.getenv(cap)
		end)
	end
	return nil, err
end

local function template(tmpl, subs)
	return string.gsub(tmpl, "{{([%w_%d]+)}}", subs)
end

local escape_magic_chars = function(str)
	return str:gsub("[+*%%%.%$[%]%(%)-]", "%%%1") -- escape all possible magic characters that are used in Lua string patterns
end

local function salt(length)
	math.randomseed(os.time())
	local length = length or 16
	local salt = ""
	for i = 1, length do
		salt = salt .. string.char(math.random(255))
	end
	return salt
end

local function uuid()
	math.randomseed(os.time())
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return string.gsub(template, "[xy]", function(c)
		local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
		return string.format("%x", v)
	end)
end

local human_size = function(size)
	local human_size = size .. " B"
	if size / 1024 / 1024 / 1024 >= 1 then
		human_size = string.format("%.2f", size / 1024 / 1024 / 1024) .. " GB"
	elseif size / 1024 / 1024 >= 1 then
		human_size = string.format("%.2f", size / 1024 / 1024) .. " MB"
	elseif size / 1024 >= 1 then
		human_size = string.format("%.2f", size / 1024) .. " KB"
	end
	return human_size
end

local indent_lines = function(input, ind, exclude)
	local input = input or {}
	local ind = ind or 0
	local exclude = exclude or {}
	setmetatable(exclude, {
		__index = function(t, k)
			return false
		end,
	})
	local indent_content = ""
	if type(ind) == "number" then
		indent_content = "\027[0m" .. string.rep(" ", ind)
	else
		indent_content = ind
	end
	local input_lines
	if type(input) == "table" then
		input_lines = input
	else
		input_lines = lines(input)
	end
	if ind == 0 then
		return input_lines
	end
	local output = {}
	for i, l in ipairs(input_lines) do
		if exclude[i] then
			table.insert(output, l)
		else
			table.insert(output, indent_content .. l)
		end
	end
	return output
end

local indent_all_lines_but_first = function(input, ind)
	return indent_lines(input, ind, { true })
end

local indent = function(input, ind, newline)
	local indented = indent_lines(input, ind)
	local newline = newline or "\r\n"
	return table.concat(indented, newline)
end

--[[

    `lines_of` splits the `input` string into strings
    of `width` length and returns them in an array.

    When `force_split` is false, which is the default,
    the splits won't neccessarily be exactly of `width` length.

    That's because in this case the `input` string is only split 
    on spaces and hyphens. In other words, when we are processing a chunk
    and the chunk has reached the length of `width`, we continue to
    add characters to the chunk unil we encounter a space or a hyphen 
    in the `input`. 

    When `force_split` is true, all splits will be exactly of `width` length,
    and the `input` string is split on any character.
    
    When `remove_extra_spaces` is true (default is false), all
    occurences of consecutive spaces will be replaced by a single space.

]]
--
local lines_of = function(input, width, force_split, remove_extra_spaces)
	local input = input or ""
	local width = tonumber(width) or 80
	local margin = math.ceil(width * 0.05)
	local buf = buffer.new()
	local state = {
		count = 0,
		esc = false,
		last_esc = "",
		last_space = 0,
	}
	for char in input:gmatch(utf.patterns.glob) do
		if state.esc then
			buf:put(char)
			if char == "m" then
				state.esc = false
			end
			state.last_esc = state.last_esc .. char
			if state.last_esc:match("\027%[0m$") then
				state.last_esc = ""
			end
		else
			if char == "\27" then
				state.esc = true
				state.last_esc = state.last_esc .. char
				buf:put(char)
			else
				state.count = state.count + 1
				if char == "\n" then
					buf:put("\n")
					if state.last_esc ~= "" then
						buf:put(state.last_esc)
					end
					state.count = 0
				else
					if
						(state.count == width and force_split)
						or (state.count >= width - margin and char:match("[%s-]"))
					then
						if char:match("%s") then
							char = "\n"
						else
							char = char .. "\n"
						end
						if state.last_esc ~= "" then
							char = char .. state.last_esc
						end
						state.count = 0
					else
						if char:match("^%s") then
							if state.count - state.last_space == 1 and remove_extra_spaces then
								char = ""
								state.count = state.count - 1
							else
								state.last_space = state.count
							end
						else
							state.last_space = 0
						end
					end
					buf:put(char)
				end
			end
		end
	end
	return lines(buf:get())
end

local parse_hex_ipv4 = function(hex_ip_str)
	local ip_hex = hex_ip_str:sub(1, 8)
	local port_hex = hex_ip_str:sub(10)

	local decimal_ip_str = ""
	for i = 8, 2, -2 do
		local octet_hex = ip_hex:sub(i - 1, i)
		local octet_decimal = tonumber(octet_hex, 16)
		decimal_ip_str = decimal_ip_str .. octet_decimal .. "."
	end
	local decimal_port_str = tonumber(port_hex, 16) or ""
	return decimal_ip_str:sub(1, -2), decimal_port_str
end

local function module_available(name)
	if package.loaded[name] then
		return true
	else
		for _, searcher in ipairs(package.searchers or package.loaders) do
			local loader = searcher(name)
			if type(loader) == "function" then
				package.preload[name] = loader
				return true
			end
		end
		return false
	end
end

local function environ()
	local env = {}
	local strings = core.environ()
	for i, s in ipairs(strings) do
		local name = s:match("^([^=]+)")
		local value = s:match("^[^=]+=(.*)")
		env[name] = value
	end
	return env
end

local date_str_to_ts = function(date_str)
	local date_ts
	if tonumber(date_str) then
		date_ts = date_str
	elseif date_str:match("%d%dT%d%d") then
		local y, m, d, h, min, s = date_str:match("^([%d]+)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
		date_ts = os.time({
			year = tonumber(y),
			month = tonumber(m),
			day = tonumber(d),
			hour = tonumber(h),
			min = tonumber(min),
			sec = tonumber(s),
		})
	else
		local w_day, d, month_str, y, h, min, s = date_str:match("(%w+), (%d+) (%w+) (%d%d%d%d) (%d+):(%d+):(%d+)")
		local months = {
			Jan = 1,
			Feb = 2,
			Mar = 3,
			Apr = 4,
			May = 5,
			Jun = 6,
			Jul = 7,
			Aug = 8,
			Sep = 9,
			Oct = 10,
			Nov = 11,
			Dec = 12,
		}
		local m = months[month_str]
		date_ts = os.time({
			year = tonumber(y),
			month = tonumber(m),
			day = tonumber(d),
			hour = tonumber(h),
			min = tonumber(min),
			sec = tonumber(s),
		})
	end
	return date_ts
end

local ts_tostring = function(ts, fmt)
	local ts = ts or os.time()
	local fmt = fmt or "%Y-%m-%d %H:%M"
	return os.date(fmt, ts)
end

local human_time = function(date)
	local date_ts
	if tonumber(date) then
		date_ts = date
	else
		date_ts = date_str_to_ts(date)
	end
	local age = os.time() - date_ts
	local human_time
	local plural = ""
	if age / 86400 > 1 then
		local days = math.ceil(age / 86400)
		if days > 1 then
			plural = "s"
		end
		human_time = days .. " day" .. plural .. " ago"
	elseif age / 3600 > 1 then
		local hours = math.ceil(age / 3600)
		if hours > 1 then
			plural = "s"
		end
		human_time = hours .. " hour" .. plural .. " ago"
	else
		local minutes = math.ceil(age / 60)
		if minutes > 1 then
			plural = "s"
		end
		human_time = minutes .. " minute" .. plural .. " ago"
	end
	return human_time, date_ts
end

local limit = function(str, max, prefix)
	local prefix = prefix or 1
	local utf_len = utf.len(str)
	if utf_len > max then
		local extra = utf_len - max
		local s = utf.sub(str, 1, prefix - 1) .. "…" .. utf.sub(str, extra + prefix + 2)
		return s
	end
	return str
end

local find_all_positions = function(input, pattern)
	if not input or not pattern then
		return nil
	end
	local i = 1
	local results = {}
	while i <= #input do
		local s, e = input:find(pattern, i)
		if not s then
			break
		end
		table.insert(results, { s, e })
		i = e + 1
	end
	return results
end

local split_by = function(input, pattern, ltrim, rtrim)
	local splits = find_all_positions(input, pattern)
	if not splits or #splits == 0 then
		return { { t = "reg", c = input } }
	end
	local ltrim = ltrim or 0
	local rtrim = rtrim or 0
	local lines = {}
	local idx = 1
	for i, v in ipairs(splits) do
		local reg = input:sub(idx, v[1] - 1)
		local cap = input:sub(v[1] + ltrim, v[2] - rtrim)
		idx = v[2] + 1
		if reg ~= "" then
			table.insert(lines, { t = "reg", c = reg })
		end
		table.insert(lines, { t = "cap", c = cap })
		if i == #splits then
			local reg = input:sub(v[2] + 1)
			if reg and reg ~= "" then
				table.insert(lines, { t = "reg", c = reg })
			end
		end
	end
	return lines
end

local find_process_by_inode = function(inode)
	local pids = list_files("/proc", "^%d", "d") or {}
	for pid, _ in pairs(pids) do
		local fds = list_files("/proc/" .. pid .. "/fd", ".", "l", true) or {}
		for fd, st in pairs(fds) do
			-- might be misleading -- with this clause we are only looking for sockets...
			if st.target:match("socket:%[" .. inode .. "%]") then
				local proc_stats = read_file("/proc/" .. pid .. "/stat") or ""
				local proc_name = proc_stats:match("^%d+ %(([^)]+)%)") or "n/a"
				return proc_name .. "(" .. pid .. ")"
			end
		end
	end
	return ""
end

local align_text = function(text, max, side)
	local side = side or "left"
	local text = tostring(text)
	if side == "left" then
		local suf = max - utf.len(text)
		return text .. string.rep(" ", suf)
	end
	if side == "right" then
		local pre = max - utf.len(text)
		return string.rep(" ", pre) .. text
	end
	local pre, frac = math.modf((max - utf.len(text)) / 2)
	local suf = pre
	if frac == 0.5 then
		pre = pre + 1
	end
	return string.rep(" ", pre) .. text .. string.rep(" ", suf)
end

local parse_pipe_table_header = function(header)
	local name = header
	local align = "left"
	if type(header) == "table" then
		name = header[1]
		align = header[2]
	end
	return name, align
end

local calc_table_maxes = function(headers, tbl)
	local maxes = {}
	for i, header in ipairs(headers) do
		local h_name, h_align = parse_pipe_table_header(header)
		maxes[h_name] = utf.len(h_name)
	end
	for i, row in ipairs(tbl) do
		for j, col in ipairs(row) do
			if headers[j] then
				local len = utf.len(tostring(col))
				local h_name = parse_pipe_table_header(headers[j])
				if len > maxes[h_name] then
					maxes[h_name] = len
				end
			end
		end
	end
	return maxes
end

local pipe_table = function(headers, tbl)
	local lines = {}
	local maxes = calc_table_maxes(headers, tbl)
	local h_line = "|"
	local s_line = "|"
	for i, header in ipairs(headers) do
		local h_name, h_align = parse_pipe_table_header(header)
		-- We want headers themselves to be centrally aligned
		h_line = h_line .. " " .. align_text(h_name, maxes[h_name], "center") .. " |"
		if h_align == "center" then
			s_line = s_line .. ":" .. string.rep("-", maxes[h_name]) .. ":|"
		elseif h_align == "right" then
			s_line = s_line .. string.rep("-", maxes[h_name] + 1) .. ":|"
		else
			s_line = s_line .. ":" .. string.rep("-", maxes[h_name] + 1) .. "|"
		end
	end
	lines[1] = h_line
	lines[2] = s_line
	for i, row in ipairs(tbl) do
		local line = "|"
		for j, col in ipairs(row) do
			local h_name, h_align = parse_pipe_table_header(headers[j])
			line = line .. " " .. align_text(col, maxes[h_name], h_align) .. " |"
		end
		lines[i + 2] = line
	end
	return lines
end

local progress_icons = { "⣿", "⣗", "⡯", "⣦", "⣢", "⣲", "⣶", "⣮", "⣦", "⢿", "⡟", "⣤" }
local progress_icon = function()
	local pid = launch({
		name = "progress_bar",
		func = function(cmd, args)
			while true do
				for _, icon in ipairs(progress_icons) do
					io.write(icon)
					io.flush()
					sleep_ms(200)
					io.write("\b \b")
					io.flush()
				end
			end
		end,
	}, nil, nil, nil)
	return {
		stop = function()
			kill(pid, 9)
			wait(pid)
			io.write("\b \b")
			io.flush()
		end,
	}
end

local deviant = {
	utf = utf,
	print = print_table,
	render_table = render_table,
	merge_tables = merge_tables,
	copy_table = table_deep_copy,
	pipe_table = pipe_table,
	parse_pipe_table_header = parse_pipe_table_header,
	calc_table_maxes = calc_table_maxes,
	alphanumsort = alphanumsort,
	sort_keys = sort_keys,
	get_nested_value = get_nested_value,
	lines = lines,
	lines_of = lines_of,
	include_keys = include_keys,
	exclude_keys = exclude_keys,
	limit = limit,
	longest = longest,
	indent = indent,
	align_text = align_text,
	indent_lines = indent_lines,
	indent_all_lines_but_first = indent_all_lines_but_first,
	read_file = read_file,
	write_file = write_file,
	dir_exists = dir_exists,
	empty_dir = empty_dir,
	non_empty_dir = non_empty_dir,
	file_exists = file_exists,
	list_files = list_files,
	list_dir = list_dir,
	fast_list_dir = fast_list_dir,
	split_path_by_dir = split_path_by_dir,
	symlink = symlink,
	chdir = chdir,
	mkdir = mkdir,
	cwd = cwd,
	remove = remove,
	stat = stat,
	setenv = setenv,
	environ = environ,
	unsetenv = unsetenv,
	fork = fork,
	kill = kill,
	dup = dup,
	dup2 = dup2,
	pipe = pipe,
	exec = exec,
	readlink = readlink,
	launch = launch,
	exec_simple = exec_simple,
	exec_one_line = exec_one_line,
	waitpid = waitpid,
	wait = wait,
	clockticks = core.clockticks,
	getpid = getpid,
	sleep = sleep,
	sleep_ms = sleep_ms,
	module_available = module_available,
	find_all_positions = find_all_positions,
	envsubst = envsubst,
	template = template,
	date_str_to_ts = date_str_to_ts,
	human_time = human_time,
	ts_tostring = ts_tostring,
	escape_magic_chars = escape_magic_chars,
	uuid = uuid,
	salt = salt,
	split_by = split_by,
	system_users = system_users,
	parse_hex_ipv4 = parse_hex_ipv4,
	human_size = human_size,
	find_process_by_inode = find_process_by_inode,
	progress_icon = progress_icon,
}
return deviant
