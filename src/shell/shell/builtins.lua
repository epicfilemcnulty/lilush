-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local widgets = require("term.widgets")
local json = require("cjson.safe")
local web = require("web")
local utils = require("shell.utils")
local dig = require("dns.dig")
local theme = require("shell.theme")
local text = require("text")
local argparser = require("argparser")
local buffer = require("string.buffer")
local style = require("term.tss")
local input = require("term.input")

local set_term_title = function(title)
	local term_title_prefix = os.getenv("LILUSH_TERM_TITLE_PREFIX") or ""
	local static_term_title = os.getenv("LILUSH_TERM_TITLE_STATIC") or ""
	if static_term_title ~= "" then
		term.title(static_term_title)
	else
		term.title(term_title_prefix .. title)
	end
end

--[[ 
    Throw errors to STDERR
]]
local errmsg = function(msg)
	local out = text.render_djot(tostring(msg), theme.renderer.builtin_error)
	io.stderr:write(out)
	io.stderr:flush()
end

local helpmsg = function(msg)
	local out = "\n" .. text.render_djot(msg, theme.renderer.kat) .. "\n"
	io.stderr:write(out)
	io.stderr:flush()
end
--[[ 
    DIR FUNCTIONS 
]]
local render_dir
render_dir = function(path, pattern, indent, args)
	local tss = style.new(theme)
	local indent = indent or 0
	local all_files, err = std.fs.list_files(path, pattern, ".", args.long)
	if not all_files then
		return nil, err
	end

	local sys_users = std.system_users()
	local dirs = {}
	local files = {}
	local targets = {}
	for f, s in pairs(all_files) do
		if s.mode == "d" then
			table.insert(dirs, f)
		else
			table.insert(files, f)
			if s.mode == "l" and args.long then
				targets[f] = s.target
			end
		end
	end
	dirs = std.tbl.alphanumsort(dirs)
	files = std.tbl.alphanumsort(files)

	local longest_name_size = 0
	for _, f in ipairs(dirs) do
		if std.utf.len(f) > longest_name_size then
			longest_name_size = std.utf.len(f)
		end
	end
	for _, f in ipairs(files) do
		if std.utf.len(f) > longest_name_size then
			longest_name_size = std.utf.len(f)
		end
	end
	if args.long then
		local longest_target = 0
		for f, _ in pairs(all_files) do
			if targets[f] then
				if std.utf.len(targets[f]) > longest_target then
					longest_target = std.utf.len(targets[f])
				end
			end
		end
		longest_name_size = longest_name_size + longest_target + 4
	end

	local buf = buffer.new()

	for i, dir in ipairs(dirs) do
		local mode = all_files[dir].mode
		local size = all_files[dir].size
		local perms = all_files[dir].perms
		local ext_attr = buffer.new()
		if args.long then
			local atime = std.conv.ts_to_str(all_files[dir].atime)
			local user = sys_users[all_files[dir].uid].login
			local group = sys_users[all_files[dir].gid].login
			ext_attr:put(
				tss:apply("builtins.ls.user", user),
				":",
				tss:apply("builtins.ls.group", group),
				" ",
				tss:apply("builtins.ls.atime", atime),
				" "
			)
		end
		local alignment = longest_name_size - std.utf.len(dir)

		local ind = " "
		if indent > 0 then
			local spaces = (math.floor(indent / 4) - 1) * 4
			local arrows = indent - spaces
			ind = ind
				.. tss:apply("builtins.ls.offset", string.rep(" ", spaces) .. "" .. string.rep("", arrows - 1))
		end
		buf:put(ind, tss:apply("builtins.ls.dir", dir), string.rep(" ", alignment + 2))
		if not args.tree then
			buf:put(
				" ",
				ext_attr:get(),
				tss:apply("builtins.ls.perms", perms),
				" ",
				tss:apply("builtins.ls.size", std.conv.bytes_human(size))
			)
		end
		buf:put("\n")
		if args.tree then
			local tree = render_dir(path .. "/" .. dir, pattern, indent + 4, args)
			if tree then
				buf:put(tree)
			end
		end
	end

	local prefixes = {
		f = "builtins.ls.file",
		l = "builtins.ls.link",
		s = "builtins.ls.socket",
		b = "builtins.ls.block",
		p = "builtins.ls.pipe",
		c = "builtins.ls.char",
		u = "builtins.ls.unknown",
	}
	for i, file in ipairs(files) do
		local mode = all_files[file].mode
		local size = all_files[file].size
		local perms = all_files[file].perms
		local ext_attr = buffer.new()
		local link_target = ""
		local alignment = longest_name_size - std.utf.len(file)
		if args.long then
			local atime = std.conv.ts_to_str(all_files[file].atime)
			local user = sys_users[all_files[file].uid].login
			local group = sys_users[all_files[file].gid].login
			ext_attr:put(
				tss:apply("builtins.ls.user", user),
				":",
				tss:apply("builtins.ls.group", group),
				" ",
				tss:apply("builtins.ls.atime", atime),
				" "
			)
			if targets[file] then
				link_target = " -> "
				link_target = link_target .. tss:apply("builtins.ls.target", targets[file])
				alignment = alignment - std.utf.len(targets[file]) - 4
			end
		end
		local ind = " "
		if indent > 0 then
			local spaces = (math.floor(indent / 4) - 1) * 4
			local arrows = indent - spaces
			ind = ind
				.. tss:apply("builtins.ls.offset", string.rep(" ", spaces) .. "⦁" .. string.rep("", arrows - 1))
		end
		local prefix_and_name = tss:apply(prefixes[mode], file)
		if mode == "f" and perms:match("[75]") then
			prefix_and_name = tss:apply("builtins.ls.exec", file)
		end
		buf:put(ind, prefix_and_name, link_target, string.rep(" ", alignment + 2))
		if not args.tree then
			buf:put(
				" ",
				ext_attr:get(),
				tss:apply("builtins.ls.perms", perms),
				" ",
				tss:apply("builtins.ls.size", std.conv.bytes_human(size))
			)
		end
		buf:put("\n")
	end
	return buf:get()
end

local list_dir_help = [[
: ls

  List directory contents.
]]

local list_dir = function(cmd, args)
	local parser = argparser.new({
		long = { kind = "bool", note = "Show owner, date, permissions and link targets" },
		tree = { kind = "bool", note = "Show directory tree" },
		all = { kind = "bool", note = "Show hidden files" },
		pathname = { kind = "str", default = ".", idx = 1 },
	}, list_dir_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	local pattern = "^[^.]" -- no hidden files by default
	if args.all then
		pattern = ".*"
	end

	-- Parse pathname to see if it contains a pattern
	-- along with the path
	local path, p = args.pathname:match("^(.-)([^/]+)$")
	if p then
		if #path == 0 then
			if p ~= "." and p ~= ".." then
				pattern = p
				args.pathname = "."
			end
		else
			local st = std.fs.stat(args.pathname)
			if not st or st.mode ~= "d" then
				args.pathname = path
				pattern = std.escape_magic_chars(p)
			end
		end
	end
	local out, err = render_dir(args.pathname, pattern, 0, args)
	if not out then
		errmsg(err)
		return 127
	end
	term.write(out)
	return 0
end

local change_dir = function(cmd, args)
	local home = os.getenv("HOME") or ""
	local pathname = args[1] or home
	if std.fs.chdir(pathname) then
		local pwd = std.fs.cwd()
		std.ps.setenv("PWD", pwd)
		set_term_title(pwd)
		return 0
	end
	return 255
end

local mkdir_help = [[
: mkdir

  Make a directory.
]]
local mkdir = function(cmd, args)
	local parser = argparser.new({
		recursive = { kind = "bool", note = "Make all absent directories in the provided path" },
		pathname = { kind = "str", idx = 1 },
	}, mkdir_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end

	local status, err = std.fs.mkdir(args.pathname, nil, args.recursive)
	if not status then
		errmsg(err)
		return 127
	end
	return 0
end

local upper_dir = function(cmd, args)
	local _, count = cmd:gsub("%.", "%1")
	local path = string.rep("../", count - 1)
	if std.fs.chdir(path) then
		local pwd = std.fs.cwd()
		std.ps.setenv("PWD", pwd)
		set_term_title(pwd)
		return 0
	end
	return 255
end

local sys_dirs = {
	["/etc"] = true,
	["/etc/init.d"] = true,
	["/etc/rc.d"] = true,
	["/home"] = true,
	["/bin"] = true,
	["/boot"] = true,
	["/sbin"] = true,
	["/usr/sbin"] = true,
	["/usr/bin"] = true,
}

local file_remove_help = [[
: rm

  Remove files/directories.
]]
local file_remove = function(cmd, args)
	local parser = argparser.new({
		recursive = { kind = "bool", note = "remove non-empty directories" },
		force = { kind = "bool", note = "remove directories too" },
		pathname = { kind = "str", idx = 1, multi = true },
	}, file_remove_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	for i, pathname in ipairs(args.pathname) do
		local st, err = std.fs.stat(pathname)
		if not st then
			errmsg(err)
			return 127
		end
		if st.mode == "d" then
			if not args.force then
				errmsg("use `-f`{.flag} flag to remove a dir")
				return 127
			end
			if std.fs.non_empty_dir(pathname) and not args.recursive then
				errmsg("use `-rf`{.flag} flags to remove a non-empty dir")
				return 127
			end
		end
		-- Do some sanity checks
		local path = pathname:gsub("/-$", "") -- remove all trailing slashes
		local home_dir = os.getenv("HOME") or ""
		local pwd = std.fs.cwd()
		if not path:match("^/") then
			path = pwd .. "/" .. path
		end
		if args.force and (sys_dirs[path] or path == home_dir or pathname == "/") then
			if cmd ~= "rmrf" then
				errmsg("use `rmrf -rf`{.flag} if you do want to delete `" .. path .. "`")
				return 33
			end
		end

		local status, err = std.fs.remove(pathname, args.recursive)
		if not status then
			errmsg(err)
			return 127
		end
	end
	return 0
end

--[[ 
    CAT
]]
local cat_help = [[
: kat

  Show file contents. In Kitty terminal *kat*
  can also show images.

]]
local cat = function(cmd, args)
	local extra = extra or {}
	local parser = argparser.new({
		raw = { kind = "bool", note = "Force raw rendering mode (no pager, no word wraps)" },
		page = { kind = "bool", note = "Force using pager even on one screen documents" },
		indent = { kind = "num", default = 0, note = "Indentation" },
		wrap = { kind = "bool", note = "Wrap text even in raw mode" },
		links = { kind = "bool", note = "Show link's url" },
		pathname = { kind = "file", idx = 1 },
	}, cat_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	local mime = web.mime_type(args.pathname)
	if not mime:match("^text") and not std.txt.valid_utf(args.pathname) then
		std.ps.exec("xdg-open", args.pathname)
		return 0
	end
	local render_mode = "raw"
	if mime:match("djot") then
		render_mode = "djot"
	elseif mime:match("markdown") then
		render_mode = "markdown"
	end
	if not args.raw then
		term.set_raw_mode(true)
		term.hide_cursor()
		local pager = utils.pager({
			exit_on_one_page = not args.page,
			indent = args.indent,
			render_mode = render_mode,
			hide_links = not args.links,
			wrap_in_raw = args.wrap,
		})
		pager:load_content(args.pathname)
		pager:set_render_mode()
		pager:page()
		term.show_cursor()
		term.set_sane_mode()
		return 0
	end
	if args.raw then
		local txt = std.fs.read_file(args.pathname) or ""
		term.write("\n" .. text.render_text(txt, {}, { global_indent = 0, wrap = -1 }) .. "\n")
		return 0
	end
	return 0
end

local exec = function(cmd, args)
	local cmd = table.remove(args, 1)
	std.ps.exec(cmd, unpack(args))
end

local notify = function(cmd, args)
	local parser = argparser.new({
		pause = { kind = "str", default = "0", note = "Notify after the pause of: 5s, 1m, 3h" },
		title = { kind = "str", default = "", note = "Title" },
		message = { kind = "str", idx = 1, multi = true },
	}, "# notify ")
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	local seconds = 0
	for duration, unit in args.pause:gmatch("(%d+)(%w?)") do
		local d = tonumber(duration) or 0
		if unit:match("[hH]") then
			seconds = seconds + d * 3600
		elseif unit:match("[Mm]") then
			seconds = seconds + d * 60
		else
			seconds = seconds + d
		end
	end
	local msg = table.concat(args.message, " ")
	local pid = std.ps.fork()
	if pid and pid == 0 then
		std.sleep(seconds)
		term.kitty_notify(args.title, msg)
		os.exit(0)
	end
	return 0
end
--[[ 
    ENV
]]
local list_env = function(cmd, args)
	local arg = args[1] or ".*" -- for now let's just hardcode the first arg
	local env = std.environ()
	local tss = style.new(theme)
	local matched = std.tbl.include_keys(std.tbl.sort_keys(env), arg)
	tss.__style.builtins.envlist.var.w = std.tbl.longest(matched)

	local out = ""
	for _, entry in ipairs(matched) do
		out = out .. tss:apply("builtins.envlist.var", entry)
		out = out .. tss:apply("builtins.envlist.value", " " .. env[entry]) .. "\n"
	end
	term.write(out)
	return 0
end

local setenv = function(cmd, args)
	local args = args or {}
	local name
	for i, v in ipairs(args) do
		local value
		if not name then
			if v:match("^.+=") then
				name, value = v:match("^(.+)=(.*)")
			else
				name = v
			end
		else
			value = v
		end
		if name and value then
			std.ps.setenv(name, value)
			name = nil
		end
	end
	return 0
end

local unsetenv = function(cmd, args)
	local args = args or {}
	for _, arg in ipairs(args) do
		std.ps.unsetenv(arg)
	end
	return 0
end

--[[ 
    DIG
]]
local render_dns_record = function(records)
	local tss = style.new(theme)
	local out = ""
	for i, rec in ipairs(records) do
		local content = rec[2]
		if type(rec[2]) == "table" then
			content = ""
			for _, v in pairs(rec[2]) do
				content = content .. v .. " "
			end
		end
		out = out
			.. tss:apply("builtins.dig.name", rec[1])
			.. " "
			.. tss:apply("builtins.dig._in", "IN ")
			.. tss:apply("builtins.dig._type", rec[4])
			.. " "
			.. tss:apply("builtins.dig.content", content)
			.. " "
			.. tss:apply("builtins.dig.ttl", rec[3])
			.. "\n"
	end
	return out
end

local dig_help = [[

: dig

  DNS lookup tool.
]]
local dig = function(cmd, args)
	local tss = style.new(theme)
	local parser = argparser.new({
		cache = { kind = "bool" },
		tcp = { kind = "bool" },
		args = { kind = "str", idx = 1, multi = true },
	}, dig_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	local ns
	local rtype = "A"
	local domain
	for _, arg in ipairs(args.args) do
		if arg:match("^@") then
			ns = arg:match("^@(.+)")
		elseif arg:match("^%u") then
			rtype = arg
		else
			domain = arg
		end
	end
	if not domain then
		errmsg("You must provide a domain name to resolve")
		return 127
	end
	if cmd == "dig" then
		local records, glue, ns = dig.simple(domain, rtype, ns, args)
		if records == nil then
			errmsg(glue)
			return 255
		end

		local ns_type = ""
		if dig.config.system and dig.config.system == ns then
			ns_type = "system default"
		elseif dig.config.fallback == ns then
			ns_type = "fallback"
		end
		local out = tss:apply("builtins.dig.ns", "NS: " .. ns)
			.. tss:apply("builtins.dig.ns_type", " " .. ns_type)
			.. "\n"
			.. render_dns_record(records)
		term.write(out)
		return 0
	end
	if cmd == "digg" then
		local response, err = dig.fullchain(domain, rtype, args)
		if response == nil then
			errmsg(err)
			return 255
		end
		local out = "\n"
			.. tss:apply("builtins.dig.query", "Asking ")
			.. tss:apply("builtins.dig.root_ns", response.root_ns_name)
			.. tss:apply("builtins.dig.answer", " who is in charge of ")
			.. tss:apply("builtins.dig.tld", response.tld)
			.. "\n\n"
			.. tss:apply("builtins.dig.answer", "Got ")
			.. tss:apply("builtins.dig.tld_ns", #response.tld_ns)
			.. tss:apply("builtins.dig.answer", " servers, using ")
			.. tss:apply("builtins.dig.tld_ns", response.tld_ns_name)
			.. tss:apply("builtins.dig.answer", " to get NS for ")
			.. tss:apply("builtins.dig.domain", domain)
			.. "\n"
			.. tss:apply("builtins.dig.answer", "Got ")
			.. tss:apply("builtins.dig.domain_ns", #response.domain_ns)
			.. tss:apply("builtins.dig.answer", " servers, asking ")
			.. tss:apply("builtins.dig.domain_ns", response.domain_ns_name)
			.. tss:apply("builtins.dig.answer", " for ")
			.. tss:apply("builtins.dig.rtype", rtype)
			.. "\n\n"
			.. render_dns_record(response.recs)
		term.write(out)
		return 0
	end
	return 255
end

--[[ 
    KTL
]]
local ktl_profile = function(cmd, args)
	if args[1] then
		local home = os.getenv("HOME") or ""
		std.ps.setenv("KUBECONFIG", home .. "/.kube/cfgs/" .. args[1])
		-- We check if there is a `~/.kube/config` file and it is a symlink.
		-- If it is, we remove it and create a new one. If it's not a symlink
		-- we leave it intact.
		local target = std.fs.readlink(home .. "/.kube/config")
		if target then
			std.fs.remove(home .. "/.kube/config")
		end
		if not std.fs.file_exists(home .. "/.kube/config") then
			std.fs.symlink(home .. "/.kube/cfgs/" .. args[1], home .. "/.kube/config")
		end
		return 0
	end
	errmsg("no profile specified")
	return 255
end

local ktl = function(cmd, args)
	local namespace
	for i, arg in ipairs(args) do
		if arg == "-n" or arg == "--namespace" then
			if i + 1 <= #args then
				namespace = args[i + 1]
				std.ps.setenv("KTL_NAMESPACE", namespace)
				break
			end
		end
	end
	if not namespace then
		namespace = os.getenv("KTL_NAMESPACE") or "kube-system"
		table.insert(args, 1, namespace)
		table.insert(args, 1, "--namespace")
	end
	local pid = std.ps.launch("kubectl", nil, nil, nil, unpack(args))
	local ret, status = std.ps.wait(pid)
	if status ~= 0 then
		return status
	end
	return 0
end

--[[ 
    SSH helpers
]]
local ssh_profile = function(cmd, args)
	local home = os.getenv("HOME") or ""
	local args = args or {}
	local profile = args[1] or ""
	local profile_full_path = home .. "/.ssh/profiles/" .. profile
	local ssh_config = home .. "/.ssh/config"

	if not std.fs.file_exists(profile_full_path) then
		errmsg("no such profile")
		return 255
	end
	local st = std.fs.stat(ssh_config)
	if not st then
		local ret, err = std.fs.symlink(profile_full_path, ssh_config)
		if ret then
			return 0
		end
		errmsg(err)
		return 255
	end
	if st.mode == "l" then
		local ret, err = std.fs.remove(ssh_config)
		if not ret then
			errmsg(err)
			return 255
		end
		local ret, err = std.fs.symlink(profile_full_path, ssh_config)
		if not ret then
			errmsg(err)
			return 255
		end
	end
	return 0
end

--[[ 
    AWS tools
]]

local aws_profile = function(cmd, args)
	local aws_config = std.fs.read_file(os.getenv("HOME") .. "/.aws/config")
	if aws_config then
		local content = { title = "Choose   profile", options = {} }
		for p in aws_config:gmatch("%[profile ([^%]]+)%]") do
			table.insert(content.options, p)
		end
		term.set_raw_mode()
		local l, c = term.cursor_position()
		term.switch_screen("alt", true)
		term.hide_cursor()
		local profile = widgets.switcher(content, theme.widgets.aws)
		term.show_cursor()
		term.switch_screen("main", nil, true)
		term.go(l, c)
		term.set_sane_mode()
		if profile ~= "" then
			std.ps.setenv("AWS_PROFILE", profile)
		end
	end
	return 0
end

local aws_region = function(cmd, args)
	local content = { title = "Choose   region", options = {} }
	local regions = os.getenv("AWS_REGIONS")
	if regions and regions ~= "" then
		for region in regions:gmatch("([%w-]+),?") do
			table.insert(content.options, region)
		end
		term.set_raw_mode()
		term.hide_cursor()
		local l, c = term.cursor_position()
		term.switch_screen("alt", true)
		local region = widgets.switcher(content, theme.widgets.aws)
		term.switch_screen("main", nil, true)
		term.go(l, c)
		term.show_cursor()
		term.set_sane_mode()
		if region ~= "" then
			std.ps.setenv("AWS_REGION", region)
		end
	end
	return 0
end
--[[
    NETSTAT
]]
local routes = function()
	local routes_raw, err = std.fs.read_file("/proc/net/route")
	if not routes_raw then
		return nil, err
	end
	local lines = {}
	for line in routes_raw:gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	table.remove(lines, 1)
	local routes = {}
	for _, line in ipairs(lines) do
		local iface, dst, gw, mask = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+(%S+)")
		table.insert(routes, {
			iface = iface,
			dst = std.conv.hex_ipv4(dst),
			gw = std.conv.hex_ipv4(gw),
			mask = std.hex_ipv4(mask),
		})
	end
	return routes
end

local connection_state = {
	["01"] = "ESTABLISHED",
	["02"] = "SYN_SENT",
	["03"] = "SYN_RECV",
	["04"] = "FIN_WAIT1",
	["05"] = "FIN_WAIT2",
	["06"] = "TIME_WAIT",
	["07"] = "CLOSE",
	["08"] = "CLOSE_WAIT",
	["09"] = "LAST_ACK",
	["0A"] = "LISTEN",
	["0B"] = "CLOSING",
}

local netstat = function()
	local tcp_raw, err = std.fs.read_file("/proc/net/tcp")
	if not tcp_raw then
		return nil, err
	end
	local lines = {}
	for line in tcp_raw:gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	table.remove(lines, 1)

	local users = std.system_users()
	local parsed = {}
	for i, line in ipairs(lines) do
		local fields = {}
		for field in line:gmatch("(%S+)") do
			table.insert(fields, field)
		end
		local state = connection_state[fields[4]]
		if not parsed[state] then
			parsed[state] = {}
		end
		local src_ip, src_port = std.conv.hex_ipv4(fields[2])
		local dst_ip, dst_port = std.conv.hex_ipv4(fields[3])
		local uid = tonumber(fields[8]) or 0
		local user = users[uid]
		local inode = fields[10]
		local proc_name = std.ps.find_by_inode(inode)
		table.insert(
			parsed[state],
			{ src = src_ip .. ":" .. src_port, dst = dst_ip .. ":" .. dst_port, user = user.login, process = proc_name }
		)
	end
	return parsed
end

local netstat_help = [[
: netstat

  Tool to lookup network connections information.
]]
local render_netstat = function(cmd, args)
	local tss = style.new(theme)
	local parser = argparser.new({
		listen = { kind = "bool" },
		source = { kind = "str", default = ".*", idx = 1 },
		destination = { kind = "str", default = ".*", idx = 2 },
	}, netstat_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end

	local conns, err = netstat()
	if not conns then
		errmsg(err)
		return 127
	end
	local s = "."
	if args.listen then
		s = "LISTEN"
	end
	local src = args.source
	local dst = args.destination

	local matched = {}
	local longest = { src = 0, dst = 0, state = 0, user = 0, process = 0 }
	for state, connection in pairs(conns) do
		if state:match(s) then
			for i, conn in ipairs(conns[state]) do
				if conn.src:match(src) and conn.dst:match(dst) then
					table.insert(
						matched,
						{ state = state, src = conn.src, dst = conn.dst, user = conn.user, process = conn.process }
					)
					if #conn.src > longest.src then
						longest.src = #conn.src
					end
					if #conn.process > longest.process then
						longest.process = #conn.process
					end
					if #conn.dst > longest.dst then
						longest.dst = #conn.dst
					end
					if #state > longest.state then
						longest.state = #state
					end
					if #conn.user > longest.user then
						longest.user = #conn.user
					end
				end
			end
		end
	end
	local listen = {}
	local other = {}
	local established = {}
	for i, conn in ipairs(matched) do
		if conn.state == "ESTABLISHED" then
			table.insert(established, { src = conn.src, dst = conn.dst, user = conn.user, process = conn.process })
		elseif conn.state == "LISTEN" then
			listen[conn.src] = conn.user
			if conn.process ~= "" then
				listen[conn.src] = conn.user .. "," .. conn.process
			end
		else
			table.insert(
				other,
				{ src = conn.src, dst = conn.dst, state = conn.state, user = conn.user, process = conn.process }
			)
		end
	end
	table.sort(established, function(a, b)
		return a.dst < b.dst
	end)
	table.sort(other, function(a, b)
		return a.dst < b.dst
	end)
	for i, conn in ipairs(established) do
		if not conn.paired and not conn.pair then
			for j, c in ipairs(established) do
				if c.dst == conn.src then
					established[j].paired = i
					established[i].pair = established[j].process
				end
			end
		end
	end
	local out = ""
	for i, conn in pairs(established) do
		if not conn.paired then
			local direction = "--> "
			local process = conn.process
			if conn.pair then
				direction = "<-> "
				if process ~= "" and conn.pair ~= "" then
					process = process .. "," .. conn.pair
				elseif conn.pair ~= "" then
					process = conn.pair
				end
			end
			out = out
				.. tss:apply(
					"builtins.netstat.src",
					conn.src .. string.rep(" ", 2 + longest.src - #conn.src) .. direction
				)
				.. tss:apply("builtins.netstat.dst", conn.dst .. string.rep(" ", 2 + longest.dst - #conn.dst))
				.. tss:apply("builtins.netstat.state", "ESTABLISHED" .. string.rep(" ", 2 + longest.state - 11))
				.. tss:apply("builtins.netstat.user", conn.user .. string.rep(" ", 2 + longest.user - #conn.user))
				.. tss:apply("builtins.netstat.user", process)
				.. "\n"
		end
	end
	for i, conn in ipairs(other) do
		local direction = " ⇢  "
		out = out
			.. tss:apply("builtins.netstat.src", conn.src .. string.rep(" ", 2 + longest.src - #conn.src) .. direction)
			.. tss:apply("builtins.netstat.dst", conn.dst .. string.rep(" ", 2 + longest.dst - #conn.dst))
			.. tss:apply("builtins.netstat.state", conn.state .. string.rep(" ", 2 + longest.state - #conn.state))
			.. tss:apply("builtins.netstat.user", conn.user .. string.rep(" ", 2 + longest.user - #conn.user))
			.. tss:apply("builtins.netstat.user", conn.process)
			.. "\n"
	end
	for src, conn in pairs(listen) do
		out = out
			.. tss:apply("builtins.netstat.src", src .. string.rep(" ", 2 + longest.src - #src + longest.dst + 6))
			.. tss:apply("builtins.netstat.state", "LISTEN" .. string.rep(" ", 2 + longest.state - 6))
			.. tss:apply("builtins.netstat.user", conn)
			.. "\n"
	end
	term.write(out)
	return 0
end

local history_help = [[
: history

  See commands history.
]]
local history = function(cmd, args, extra)
	local tss = style.new(theme)
	local parser = argparser.new({
		short = { kind = "bool" },
		time = { kind = "bool" },
		lines = { kind = "num", default = 15 },
	}, history_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	local size = #extra
	local offset = size - args.lines
	if offset < 0 then
		offset = 1
	end
	local lines = ""
	for i = offset, #extra do
		local date = tss:apply("builtins.history.date", os.date("%Y-%m-%d", extra[i].ts))
		local time = tss:apply("builtins.history.time", os.date("%H:%M:%S", extra[i].ts))
		local duration = extra[i].d
		local status = extra[i].exit
		local cmd = tss:apply("builtins.history.cmd.ok", extra[i].cmd)
		if status > 0 then
			cmd = tss:apply("builtins.history.cmd.fail", extra[i].cmd)
		end
		if args.short then
			lines = lines .. cmd .. "\n"
		elseif args.time then
			lines = lines .. time .. cmd .. "\n"
		else
			lines = lines .. date .. time .. cmd .. "\n"
		end
	end
	local indent = tss.__style.builtins.history.global_indent or 0
	term.write(std.txt.indent(lines, indent) .. "\n")
	return 0
end

local ps_help = [[
# _ps_ provides a snapshot of currently running processes

  You can choose the fields of process information to display with the `-f` flag.
  The available fields are:

  | Field      |  Description                           |
  |:-----------|:---------------------------------------|
  |  `pid`     |  pid                                   |
  |  `ppid`    |  parent's pid                          |
  |  `uid`     |  uid                                   |
  |  `user`    |  user                                  |
  |  `state`   |  state                                 |
  |  `cmd`     |  executable                            |
  |  `cmdline` |  command line                          |
  |  `cpu`     |  Total CPU usage (%) over the lifetime |
  |  `mem`     |  Memory usage (%)                      |
  |  `mem_kb`  |  Memory usage (KB)                     |
  |  `mem_mb`  |  Memory usage (MB)                     |
  |  `mem_gb`  |  Memory usage (GB)                     |

]]

local kinda_ps = function(cmd, args)
	local cur_user = os.getenv("USER") or ""
	local parser = argparser.new({
		all = { kind = "bool", note = "Show processes of all users" },
		json = { kind = "bool", note = "JSON output" },
		kernel = { kind = "bool", note = "Show kernel threads" },
		format = { kind = "str", default = "pid,cmd", note = "Fields to display" },
		extended = { kind = "bool", short = "x", note = "Shortcut for `pid,uid,state,cmdline` format" },
		detailed = { kind = "bool", note = "Shortcut for `pid,user,state,cpu,mem,cmd` format" },
		parent = { kind = "num", default = 0, note = "Show only children of this process" },
		sort = { kind = "num", default = 1, note = "Index of the field to sort by" },
		user = { kind = "str", default = cur_user, note = "Show only processes of this user" },
		pattern = {
			kind = "str",
			idx = 1,
			default = ".*",
			note = "Show only those processes whose cmdline matches the pattern",
		},
	}, ps_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	if args.extended then
		args.format = "pid,uid,state,cmdline"
	end
	if args.detailed then
		args.format = "pid,user,state,cpu,mem,cmd"
	end
	if args.extended and args.detailed then
		args.format = "pid,uid,state,cpu,mem_mb,cmdline"
	end
	-- See https://man7.org/linux/man-pages/man5/proc.5.html (or `man 5 proc`) for
	-- details on the proc pseudo fs
	local pids = std.fs.list_files("/proc", "^%d", "d") or {}
	local processes = {}
	local sys_users = std.system_users()
	local uptime_file = std.fs.read_file("/proc/uptime") or ""
	local uptime_seconds = tonumber(uptime_file:match("^(%S+)")) or 0
	local mem_file = std.fs.read_file("/proc/meminfo") or ""
	local mem_total = tonumber(mem_file:match("MemTotal:%s+(%S+)")) or 0

	for pid_s, _ in pairs(pids) do
		local pid = tonumber(pid_s) or -1
		local cmdline = std.fs.read_file("/proc/" .. pid_s .. "/cmdline") or ""
		cmdline = cmdline:gsub("%z", " ") -- arguments in cmdline are separated with the \0 character
		cmdline = cmdline:gsub("%s$", "")

		-- CPU Usage calculation
		-- See https://stackoverflow.com/questions/16726779/how-do-i-get-the-total-cpu-usage-of-an-application-from-proc-pid-stat for
		-- useful details and links
		local stat_file = std.fs.read_file("/proc/" .. pid_s .. "/stat") or ""
		local utime, stime, cutime, cstime, starttime = stat_file:match(
			"^%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+(%S+)"
		) -- these values are in clock ticks
		-- might also want to include children stats: tonumber(cutime) + tonumber(cstime)
		local proc_total_cpu_time = tonumber(utime) + tonumber(stime)
		local clk_tck = std.clockticks() -- clock ticks per second
		local proc_cpu_seconds = uptime_seconds - (tonumber(starttime) / clk_tck)
		local cpu_usage = 100 * ((proc_total_cpu_time / clk_tck) / proc_cpu_seconds)

		local status = std.fs.read_file("/proc/" .. pid_s .. "/status") or ""
		local uid = tonumber(status:match("Uid:%s+(%S+)")) or -1
		local name = status:match("Name:%s+(%S+)") or ""
		local state = status:match("State:%s+(%S+)") or "U"
		local vm_rss = tonumber(status:match("VmRSS:%s+(%S+)")) or 0
		local ppid = tonumber(status:match("PPid:%s+(%S+)")) or 0
		local user = sys_users[uid].login

		table.insert(processes, {
			cmd = name,
			cmdline = cmdline,
			ppid = ppid,
			pid = pid,
			user = user,
			state = state,
			uid = uid,
			cpu = cpu_usage,
			mem = vm_rss / (mem_total / 100),
			mem_kb = vm_rss,
			mem_mb = vm_rss / 1024,
			mem_gb = vm_rss / 1024 / 1024,
		})
	end

	local ps_tbl_fields = {}
	for field_name in args.format:gmatch("([%w_]+),?") do
		table.insert(ps_tbl_fields, field_name)
	end
	if #ps_tbl_fields == 0 then
		ps_tbl_fields = { "pid" }
	end
	local ps_tbl = {}

	local sort_field_idx = args.sort
	if sort_field_idx > #ps_tbl_fields or sort_field_idx < 1 then
		sort_field_idx = 1
	end

	if args.json then
		for _, proc in ipairs(processes) do
			if proc.user == args.user or args.all then
				if proc.cmdline:match(args.pattern) then
					if proc.ppid ~= 2 or args.kernel then
						if proc.ppid == args.parent or args.parent == 0 then
							local row = {}
							for i, col_name in ipairs(ps_tbl_fields) do
								row[col_name] = proc[col_name]
							end
							table.insert(ps_tbl, row)
						end
					end
				end
			end
		end
		local col_name = ps_tbl_fields[sort_field_idx]
		table.sort(ps_tbl, function(a, b)
			return a[col_name] < b[col_name]
		end)
		local ps_tbl_json = json.encode(ps_tbl) or "[]"
		term.write(ps_tbl_json .. "\n")
		return 0
	end

	for _, proc in ipairs(processes) do
		if proc.user == args.user or args.all then
			if proc.cmdline:match(args.pattern) then
				if proc.ppid ~= 2 or args.kernel then
					if proc.ppid == args.parent or args.parent == 0 then
						local row = {}
						for idx, col_name in ipairs(ps_tbl_fields) do
							local val = proc[col_name] or -1
							row[idx] = val
							if col_name:match("^mem") or col_name == "cpu" then
								row[idx] = string.format("%.2f", row[idx])
							end
							if col_name == "cmd" or col_name == "cmdline" then
								if row[idx] ~= "" then
									row[idx] = "`" .. row[idx] .. "`"
								end
							end
						end
						table.insert(ps_tbl, row)
					end
				end
			end
		end
	end
	local sort_func = function(a, b)
		if tonumber(a[sort_field_idx]) then
			return tonumber(a[sort_field_idx]) < tonumber(b[sort_field_idx])
		end
		return a[sort_field_idx] < b[sort_field_idx]
	end
	table.sort(ps_tbl, sort_func)
	local ps_tbl_djot = std.tbl.pipe_table(ps_tbl_fields, ps_tbl)
	term.write("\n" .. text.render_djot(table.concat(ps_tbl_djot, "\n")) .. "\n")
	return 0
end

local _M

local files_matching_help = [[
: files_matching

  Execute a given command over each file matching a pattern.

By default the name of each matched file will be inserted as
the first argument of the provided command.

Sometimes this is not what you want, so you can specify the exact
placement by using `{}` in place of one of the command's arguments:

```lsh
files_matching .txt chmod 0640 {}
```
]]
local files_matching = function(cmd, args)
	local parser = argparser.new({
		pattern = { kind = "str", idx = 1, note = "literal pattern to match in a filename (not regex)" },
		command = {
			kind = "str",
			idx = 2,
			default = { "echo" },
			multi = true,
			note = "The command to execute, with all required arguments",
		},
	}, files_matching_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	local path, pattern = args.pattern:match("^(.-)([^/]+)$")
	if #path == 0 then
		path = "."
	end
	local files = std.fs.list_files(path, pattern) or {}
	for file, stat in pairs(files) do
		local cmd = ""
		local full_path
		if path == "." then
			full_path = file
		else
			if path:match("/$") then
				full_path = path .. file
			else
				full_path = path .. "/" .. file
			end
		end
		for i, arg in ipairs(args.command) do
			if arg:match("%s") then
				cmd = cmd .. '"' .. arg .. '" '
			else
				cmd = cmd .. arg .. " "
			end
		end
		local pipeline, err = utils.parse_pipeline(cmd, true)
		if not pipeline then
			return 33, err
		end
		local replaced = false
		for i, arg in ipairs(pipeline[1].args) do
			if arg == "{}" then
				pipeline[1].args[i] = full_path
				replaced = true
				break
			end
		end
		if not replaced then
			table.insert(pipeline[1].args, 1, full_path)
		end
		local status, err = utils.run_pipeline(pipeline, nil, _M, nil)
		if status ~= 0 then
			return status, err
		end
	end
	return 0
end

local storage = require("storage")

local zx_help = [[
: zx

  Snippet launcher.
]]
local zx = function(cmd, args)
	local parser = argparser.new({
		pattern = { kind = "str", idx = 1, multi = true },
	}, zx_help)
	local args, err, help = parser:parse(args)
	if err then
		if help then
			helpmsg(err)
			return 0
		end
		errmsg(err)
		return 127
	end
	for _, arg in ipairs(args.pattern) do
		arg = std.escape_magic_chars(arg)
	end
	local store = storage.new()
	local snippets = store:list_hash_keys("snippets") or {}
	for _, snippet in ipairs(snippets) do
		if snippet:match(table.concat(args.pattern, ".-")) then
			local script = store:get_hash_key("snippets", snippet) or {}
			store:close(true)
			local txt = "# Running snippet\n\n```" .. snippet .. "\n" .. script .. "\n```\n"
			term.write("\n" .. text.render_djot(txt, theme.renderer.kat) .. "\n")
			local script_lines = std.txt.lines(script)
			for i, line in ipairs(script_lines) do
				local pipeline, err = utils.parse_pipeline(line, true)
				if err then
					errmsg(err)
					return 33, err
				end
				local status, err = utils.run_pipeline(pipeline, nil, _M, nil)
				if status ~= 0 then
					errmsg(err)
					return status, err
				end
			end
			return 0
		end
	end
	store:close(true)
	return 127
end

local builtins = {
	["ls"] = list_dir,
	["cd"] = change_dir,
	["mkdir"] = mkdir,
	["%.%.+"] = upper_dir,
	["zx"] = zx,
	["rm"] = file_remove,
	["rmrf"] = file_remove,
	["kat"] = cat,
	["envlist"] = list_env,
	["history"] = history,
	["files_matching"] = files_matching,
	["setenv"] = setenv,
	["export"] = setenv,
	["unsetenv"] = unsetenv,
	["exec"] = exec,
	["netstat"] = render_netstat,
	["notify"] = notify,
	["ssh.profile"] = ssh_profile,
	["aws.region"] = aws_region,
	["aws.profile"] = aws_profile,
	["ktl.profile"] = ktl_profile,
	["ktl"] = ktl,
	["dig"] = dig,
	["digg"] = dig,
	["ps"] = kinda_ps,
}

local dont_fork = { z = true, cd = true, setenv = true, export = true, unsetenv = true, ktl = true }

local get = function(cmd)
	for k, f in pairs(builtins) do
		if cmd:match("^" .. k .. "$") then
			local fork = true
			local needy = false
			if dont_fork[cmd] or cmd:match("^%.%.+") or cmd:match("^aws%.") then
				fork = false
			end
			if cmd == "history" or cmd == "kat" then
				needy = true
			end
			return { name = cmd, func = f, fork = fork, needy = needy }
		end
	end
	return nil
end

_M = { get = get, errmsg = errmsg }
return _M
