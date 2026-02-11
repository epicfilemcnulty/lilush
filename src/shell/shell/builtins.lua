-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local term = require("term")
local widgets = require("term.widgets")
local json = require("cjson.safe")
local utils = require("shell.utils")
local messages = require("shell.messages")
local dig = require("dns.dig")
local theme = require("theme").get("shell")
local storage = require("shell.store")
local markdown = require("markdown")
local argparser = require("argparser")
local buffer = require("string.buffer")
local style = require("term.tss")
local zxscr_mod = require("zxscr")

local set_term_title = function(title)
	local term_title_prefix = os.getenv("LILUSH_TERM_TITLE_PREFIX") or ""
	local static_term_title = os.getenv("LILUSH_TERM_TITLE_STATIC") or ""
	if static_term_title ~= "" then
		term.title(static_term_title)
	else
		term.title(term_title_prefix .. title)
	end
end

local errmsg = messages.report
local helpmsg = messages.help

local style_text = function(tss, ...)
	return tss:apply(...).text
end

local parse_or_report = function(parser, args)
	local parsed, err = parser:parse(args)
	if err then
		local msg = argparser.format_error(err)
		if err.kind == "help" then
			helpmsg(msg)
			return nil, 0
		end
		errmsg(msg)
		return nil, 127
	end
	return parsed
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

	for _, dir in ipairs(dirs) do
		local mode = all_files[dir].mode
		local size = all_files[dir].size
		local perms = all_files[dir].perms
		local ext_attr = buffer.new()
		if args.long then
			local atime = std.conv.ts_to_str(all_files[dir].atime)
			local user = sys_users[all_files[dir].uid].login
			local group = sys_users[all_files[dir].gid].login
			ext_attr:put(
				style_text(tss, "builtin.ls.user", user),
				":",
				style_text(tss, "builtin.ls.group", group),
				" ",
				style_text(tss, "builtin.ls.atime", atime),
				" "
			)
		end
		local alignment = longest_name_size - std.utf.len(dir)

		local ind = " "
		if indent > 0 then
			local spaces = (math.floor(indent / 4) - 1) * 4
			local arrows = indent - spaces
			ind = ind
				.. style_text(
					tss,
					"builtin.ls.offset",
					string.rep(" ", spaces) .. "" .. string.rep("", arrows - 1)
				)
		end
		buf:put(ind, style_text(tss, "builtin.ls.dir", dir), string.rep(" ", alignment + 2))
		if not args.tree then
			buf:put(
				" ",
				ext_attr:get(),
				style_text(tss, "builtin.ls.perms", perms),
				" ",
				style_text(tss, "builtin.ls.size", std.conv.bytes_human(size))
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
		f = "builtin.ls.file",
		l = "builtin.ls.link",
		s = "builtin.ls.socket",
		b = "builtin.ls.block",
		p = "builtin.ls.pipe",
		c = "builtin.ls.char",
		u = "builtin.ls.unknown",
	}
	for _, file in ipairs(files) do
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
				style_text(tss, "builtin.ls.user", user),
				":",
				style_text(tss, "builtin.ls.group", group),
				" ",
				style_text(tss, "builtin.ls.atime", atime),
				" "
			)
			if targets[file] then
				link_target = " -> "
				link_target = link_target .. style_text(tss, "builtin.ls.target", targets[file])
				alignment = alignment - std.utf.len(targets[file]) - 4
			end
		end
		local ind = " "
		if indent > 0 then
			local spaces = (math.floor(indent / 4) - 1) * 4
			local arrows = indent - spaces
			ind = ind
				.. style_text(
					tss,
					"builtin.ls.offset",
					string.rep(" ", spaces) .. "⦁" .. string.rep("", arrows - 1)
				)
		end
		local prefix_and_name = style_text(tss, prefixes[mode], file)
		if mode == "f" and perms:match("[75]") then
			prefix_and_name = style_text(tss, "builtin.ls.exec", file)
		end
		buf:put(ind, prefix_and_name, link_target, string.rep(" ", alignment + 2))
		if not args.tree then
			buf:put(
				" ",
				ext_attr:get(),
				style_text(tss, "builtin.ls.perms", perms),
				" ",
				style_text(tss, "builtin.ls.size", std.conv.bytes_human(size))
			)
		end
		buf:put("\n")
	end
	return buf:get()
end

local list_dir = function(cmd, args)
	local parser = argparser
		.command("ls")
		:summary("List directory contents.")
		:option("all", { type = "boolean", short = "a", note = "Show hidden files" })
		:option("tree", { type = "boolean", short = "t", note = "Show directory tree" })
		:option("long", { type = "boolean", short = "l", note = "Show owner, date, permissions and link targets" })
		:argument("path", { type = "string", nargs = "?", default = "." })
		:build()
	local parsed, status = parse_or_report(parser, args)
	if status then
		return status
	end
	local pattern = "^[^.]" -- no hidden files by default
	if parsed.all then
		pattern = ".*"
	end

	-- Parse pathname to see if it contains a pattern
	-- along with the path
	local path, p = parsed.path:match("^(.-)([^/]+)$")
	if p then
		if #path == 0 then
			if p ~= "." and p ~= ".." then
				pattern = p
				parsed.path = "."
			end
		else
			local st = std.fs.stat(parsed.path)
			if not st or st.mode ~= "d" then
				parsed.path = path
				pattern = std.escape_magic_chars(p)
			end
		end
	end
	local out, err = render_dir(parsed.path, pattern, 0, parsed)
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

local mkdir = function(cmd, args)
	local parser = argparser
		.command("mkdir")
		:summary("Make a directory.")
		:option("parents", { type = "boolean", short = "p", note = "Make all absent directories in the provided path" })
		:argument("path", { type = "string" })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end

	local status, err = std.fs.mkdir(parsed.path, nil, parsed.parents)
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

local file_remove = function(cmd, args)
	local parser = argparser
		.command("rm")
		:summary("Remove files/directories.")
		:option("recursive", { type = "boolean", short = "r", note = "remove non-empty directories" })
		:option("force", { type = "boolean", short = "f", note = "remove directories too" })
		:argument("paths", { type = "string", nargs = "+" })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end
	for i, pathname in ipairs(parsed.paths) do
		local st, err = std.fs.stat(pathname)
		if not st then
			errmsg(err)
			return 127
		end
		if st.mode == "d" then
			if not parsed.force then
				errmsg("use `-f`{.flag} flag to remove a dir")
				return 127
			end
			if std.fs.non_empty_dir(pathname) and not parsed.recursive then
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
		if parsed.force and (sys_dirs[path] or path == home_dir or pathname == "/") then
			if cmd ~= "rmrf" then
				errmsg("use `rmrf -rf`{.flag} if you do want to delete `" .. path .. "`")
				return 33
			end
		end

		local status, err = std.fs.remove(pathname, parsed.recursive)
		if not status then
			errmsg(err)
			return 127
		end
	end
	return 0
end

--[[ 
    KAT
]]
local kat_help = [[
For text files shows contents in a pager.
For non-text files, opens a file with
a registered MIME handler.
]]
local kat = function(cmd, args, jobs)
	local parser = argparser
		.command("kat")
		:summary("Show file contents.")
		:description(kat_help)
		:option("raw", { type = "boolean", note = "Force raw rendering mode (no pager, no word wraps)" })
		:option("pager", { type = "boolean", note = "Force using pager even on one screen documents" })
		:option("markdown", { type = "boolean", short = "m", note = "Force markdown rendering mode" })
		:option("indent", { type = "number", default = 0, note = "Indentation" })
		:option("wrap", { type = "number", default = 100, note = "Wrap width" })
		:option("links", { type = "boolean", note = "Show link's url" })
		:argument("path", { type = "file" })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end
	local mime_info = std.mime.info(parsed.path)
	if not mime_info.type:match("^text") and not std.txt.valid_utf(parsed.path) then
		local viewer = mime_info.cmdline:match("^%S+")
		if not viewer then
			errmsg("no handler for file type: " .. mime_info.type)
			return 127
		end
		local job, err = jobs:start(viewer, { parsed.path }, { log = false })
		if not job then
			errmsg(err)
			return 127
		end
		term.write("Started background job [" .. job.id .. "]\n")
		return 0
	end
	local render_mode = "raw"
	if mime_info.type:match("djot") or mime_info.type:match("markdown") then
		render_mode = "markdown"
	end
	if parsed.markdown then
		render_mode = "markdown"
	end
	if parsed.raw then
		local txt = std.fs.read_file(parsed.path) or ""
		term.write("\n" .. txt .. "\n")
		return 0
	end
	term.set_raw_mode()
	term.hide_cursor()
	local pager = utils.pager.new({
		exit_on_one_page = not parsed.pager,
		indent = parsed.indent,
		render_mode = render_mode,
		hide_links = not parsed.links,
		wrap = parsed.wrap,
	})
	pager:load_content(parsed.path)
	pager:set_render_mode()
	pager:page()
	term.show_cursor()
	term.set_sane_mode()
	return 0
end

local job_help = [[
Default detach key is *Ctrl+]*.
]]
local job = function(cmd, args, jobs)
	local parser = argparser
		.command("job")
		:summary("Manage background jobs.")
		:description(job_help)
		:command("list", function(sub)
			sub:summary("List all jobs")
				:option("json", { type = "boolean", note = "output as JSON" })
				:option("text", { type = "boolean", note = "plain text output" })
		end)
		:command("reap", function(sub)
			sub:summary("Clean up exited jobs")
		end)
		:command("start", function(sub)
			sub:summary("Start a new job")
				:option("quiet", { type = "boolean", short = "q", note = "Don't log the output" })
				:argument("cmd", { type = "string" })
				:argument("args", { type = "string", nargs = "*", default = {} })
		end)
		:command("kill", function(sub)
			sub:summary("Kill a job")
				:option("signal", { type = "number", short = "s", default = 15, note = "Signal to send" })
				:argument("id", { type = "number" })
		end)
		:command("attach", function(sub)
			sub:summary("Attach to a job"):argument("id", { type = "number" })
		end)
		:build()
	parser.cfg.default_subcommand = "list"
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end

	if parsed.__sub == "start" then
		local j, err = jobs:start(parsed.__args.cmd, parsed.__args.args, { log = not parsed.__args.quiet })
		if not j then
			errmsg(err)
			return 127
		end
		term.write("Started job [" .. j.id .. "] pid " .. j.pid .. "\n")
		return 0
	end

	if parsed.__sub == "list" then
		local entries = jobs:list()
		if #entries == 0 then
			term.write("No jobs\n")
			return 0
		end

		if parsed.__args.json then
			std.tbl.print(json.encode(entries))
			return 0
		end

		if parsed.__args.text then
			local buf = buffer.new()
			for _, entry in ipairs(entries) do
				local status = entry.status
				if entry.status ~= "running" then
					status = status .. "(" .. tostring(entry.exit_status) .. ")"
				end
				buf:put(
					"ID=",
					entry.id,
					" PID=",
					entry.pid,
					" status=",
					status,
					" [",
					entry.cmd,
					" ",
					table.concat(entry.args, " "),
					"] log=",
					entry.log_path or "/dev/null",
					"\n"
				)
			end
			term.write(buf:get())
			return 0
		end

		local tbl_headers = { "ID", "PID", "Status", "Command", "Log path" }
		local tbl_entries = {}
		for _, entry in ipairs(entries) do
			local status = entry.status
			if entry.status ~= "running" then
				status = status .. "(" .. tostring(entry.exit_status) .. ")"
			end
			table.insert(tbl_entries, {
				"*" .. entry.id .. "*",
				"_" .. entry.pid .. "_",
				"`" .. status .. "`{.status}",
				"`" .. entry.cmd .. " " .. table.concat(entry.args, " ") .. "`{.str}",
				"`" .. (entry.log_path or "/dev/null") .. "`{.file}",
			})
		end
		local out = table.concat(std.tbl.pipe_table(tbl_headers, tbl_entries), "\n")
		helpmsg(out)
		return 0
	end

	if parsed.__sub == "kill" then
		local ok, err = jobs:kill(parsed.__args.id, parsed.__args.signal)
		if not ok then
			errmsg(err)
			return 127
		end
		return 0
	end

	if parsed.__sub == "reap" then
		jobs:reap()
		return 0
	end

	if parsed.__sub == "attach" then
		term.disable_kkbp()
		term.disable_bracketed_paste()
		term.set_raw_mode()
		local ok, err = jobs:attach(parsed.__args.id)
		term.set_sane_mode()
		if not ok then
			errmsg(err)
			return 127
		end
		return 0
	end
end

local exec = function(cmd, args)
	local launch_args = args or {}
	local launch_cmd = table.remove(launch_args, 1)
	if not launch_cmd then
		errmsg("no command specified")
		return 127
	end
	std.ps.exec(launch_cmd, unpack(launch_args))
	return 127, "failed to exec command: `" .. tostring(launch_cmd) .. "`"
end

local notify = function(cmd, args)
	local parser = argparser
		.command("notify")
		:summary("Desktop notification helper.")
		:option("after", { type = "string", default = "0", note = "Notify after pause: 5s, 1m, 3h" })
		:option("title", { type = "string", default = "", note = "Title" })
		:argument("message", { type = "string", nargs = "+" })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end
	local seconds = 0
	for duration, unit in parsed.after:gmatch("(%d+)(%w?)") do
		local d = tonumber(duration) or 0
		if unit:match("[hH]") then
			seconds = seconds + d * 3600
		elseif unit:match("[Mm]") then
			seconds = seconds + d * 60
		else
			seconds = seconds + d
		end
	end
	local msg = table.concat(parsed.message, " ")
	local pid = std.ps.fork()
	if pid and pid == 0 then
		std.sleep(seconds)
		term.kitty_notify(parsed.title, msg)
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
	tss:set_property("builtin.envlist.var", "w", std.tbl.longest(matched))

	local out = buffer.new()
	for _, entry in ipairs(matched) do
		out:put(
			style_text(tss, "builtin.envlist.var", entry),
			" ",
			style_text(tss, "builtin.envlist.value", env[entry]),
			"\n"
		)
	end
	term.write(out:get())
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
	local out = buffer.new()
	for _, rec in ipairs(records) do
		local content = rec[2]
		if type(rec[2]) == "table" then
			content = ""
			for _, v in pairs(rec[2]) do
				content = content .. v .. " "
			end
		end
		out:put(
			style_text(tss, "builtin.dig.name", rec[1]),
			" ",
			style_text(tss, "builtin.dig._in", "IN "),
			style_text(tss, "builtin.dig._type", rec[4]),
			" ",
			style_text(tss, "builtin.dig.content", content),
			" ",
			style_text(tss, "builtin.dig.ttl", rec[3]),
			"\n"
		)
	end
	return out:get()
end

local dig = function(cmd, args)
	local tss = style.new(theme)
	local parser = argparser
		.command(cmd)
		:summary("DNS lookup tool.")
		:option("cache", { type = "boolean" })
		:option("tcp", { type = "boolean" })
		:option("type", { type = "string", short = "t", default = "A", note = "Record type" })
		:option("nameserver", { type = "string", short = "n", note = "Nameserver to query" })
		:argument("domain", { type = "string" })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end
	local domain = parsed.domain
	local rtype = parsed.type
	local ns = parsed.nameserver
	if cmd == "dig" then
		local records, glue, ns = dig.simple(domain, rtype, ns, parsed)
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
		local out = style_text(tss, "builtin.dig.ns", "NS: " .. ns)
			.. style_text(tss, "builtin.dig.ns_type", " " .. ns_type)
			.. "\n"
			.. render_dns_record(records)
		term.write(out)
		return 0
	end
	if cmd == "digg" then
		local response, err = dig.fullchain(domain, rtype, parsed)
		if response == nil then
			errmsg(err)
			return 255
		end
		local out = "\n"
			.. style_text(tss, "builtin.dig.query", "Asking ")
			.. style_text(tss, "builtin.dig.root_ns", response.root_ns_name)
			.. style_text(tss, "builtin.dig.answer", " who is in charge of ")
			.. style_text(tss, "builtin.dig.tld", response.tld)
			.. "\n\n"
			.. style_text(tss, "builtin.dig.answer", "Got ")
			.. style_text(tss, "builtin.dig.tld_ns", #response.tld_ns)
			.. style_text(tss, "builtin.dig.answer", " servers, using ")
			.. style_text(tss, "builtin.dig.tld_ns", response.tld_ns_name)
			.. style_text(tss, "builtin.dig.answer", " to get NS for ")
			.. style_text(tss, "builtin.dig.domain", domain)
			.. "\n"
			.. style_text(tss, "builtin.dig.answer", "Got ")
			.. style_text(tss, "builtin.dig.domain_ns", #response.domain_ns)
			.. style_text(tss, "builtin.dig.answer", " servers, asking ")
			.. style_text(tss, "builtin.dig.domain_ns", response.domain_ns_name)
			.. style_text(tss, "builtin.dig.answer", " for ")
			.. style_text(tss, "builtin.dig.rtype", rtype)
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

local set_ssh_symlinks = function(profile)
	local home = os.getenv("HOME") or ""
	local cp = std.fs.readlink(home .. "/.ssh/config") or ""
	cp = cp:match("profiles/([^/]+)/config")

	local conf = {
		{
			source = "profiles/" .. profile .. "/config",
			dest = home .. "/.ssh/config",
		},
		{
			source = "profiles/" .. profile .. "/keys",
			dest = home .. "/.ssh/keys",
		},
	}
	for _, f in ipairs(conf) do
		local st = std.fs.stat(f.dest)
		if not st then
			local _, err = std.fs.symlink(f.source, f.dest)
			if err then
				return nil, err
			end
		elseif st.mode == "l" then
			local ret, err = std.fs.remove(f.dest)
			if not ret then
				return nil, err
			end
			ret, err = std.fs.symlink(f.source, f.dest)
			if err then
				return nil, err
			end
		end
	end
	std.fs.rename(home .. "/.ssh/known_hosts", home .. "/.ssh/profiles/" .. cp .. "/known_hosts")
	std.fs.rename(home .. "/.ssh/profiles/" .. profile .. "/known_hosts", home .. "/.ssh/known_hosts")
end

local ssh_profile = function(cmd, args)
	local home = os.getenv("HOME") or ""
	local args = args or {}
	local profile = args[1] or ""

	if not std.fs.file_exists(home .. "/.ssh/profiles/" .. profile .. "/config") then
		errmsg("no such profile")
		return 255
	end
	local _, err = set_ssh_symlinks(profile)
	if err then
		errmsg(err)
		return 255
	end
	return 0
end

--[[ 
    AWS tools
]]

local aws_profile = function(cmd, args)
	local aws_config = std.fs.read_file(os.getenv("HOME") .. "/.aws/config")
	if aws_config then
		local content = {}
		for p in aws_config:gmatch("%[profile ([^%]]+)%]") do
			table.insert(content, p)
		end
		local profile = widgets.chooser(content, { rss = theme.widget.aws, title = "Choose   profile" })
		if profile ~= "" then
			std.ps.setenv("AWS_PROFILE", profile)
		end
	end
	return 0
end

local aws_region = function(cmd, args)
	local content = {}
	local regions = os.getenv("AWS_REGIONS")
	if regions and regions ~= "" then
		for region in regions:gmatch("([%w-]+),?") do
			table.insert(content, region)
		end
		local region = widgets.chooser(content, { rss = theme.widget.aws, title = "Choose   region" })
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

local render_netstat = function(cmd, args)
	local tss = style.new(theme)
	local parser = argparser
		.command("netstat")
		:summary("Lookup network connections information.")
		:option("listening", { type = "boolean", short = "l" })
		:option("source", { type = "string", default = ".*" })
		:option("destination", { type = "string", default = ".*" })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end

	local conns, err = netstat()
	if not conns then
		errmsg(err)
		return 127
	end
	local s = "."
	if parsed.listening then
		s = "LISTEN"
	end
	local src = parsed.source
	local dst = parsed.destination

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
				.. style_text(
					tss,
					"builtin.netstat.src",
					conn.src .. string.rep(" ", 2 + longest.src - #conn.src) .. direction
				)
				.. style_text(tss, "builtin.netstat.dst", conn.dst .. string.rep(" ", 2 + longest.dst - #conn.dst))
				.. style_text(tss, "builtin.netstat.state", "ESTABLISHED" .. string.rep(" ", 2 + longest.state - 11))
				.. style_text(tss, "builtin.netstat.user", conn.user .. string.rep(" ", 2 + longest.user - #conn.user))
				.. style_text(tss, "builtin.netstat.user", process)
				.. "\n"
		end
	end
	for i, conn in ipairs(other) do
		local direction = " ⇢  "
		out = out
			.. style_text(
				tss,
				"builtin.netstat.src",
				conn.src .. string.rep(" ", 2 + longest.src - #conn.src) .. direction
			)
			.. style_text(tss, "builtin.netstat.dst", conn.dst .. string.rep(" ", 2 + longest.dst - #conn.dst))
			.. style_text(tss, "builtin.netstat.state", conn.state .. string.rep(" ", 2 + longest.state - #conn.state))
			.. style_text(tss, "builtin.netstat.user", conn.user .. string.rep(" ", 2 + longest.user - #conn.user))
			.. style_text(tss, "builtin.netstat.user", conn.process)
			.. "\n"
	end
	for src, conn in pairs(listen) do
		out = out
			.. style_text(tss, "builtin.netstat.src", src .. string.rep(" ", 2 + longest.src - #src + longest.dst + 6))
			.. style_text(tss, "builtin.netstat.state", "LISTEN" .. string.rep(" ", 2 + longest.state - 6))
			.. style_text(tss, "builtin.netstat.user", conn)
			.. "\n"
	end
	term.write(out)
	return 0
end

local history = function(cmd, args)
	local tss = style.new(theme)
	local parser = argparser
		.command("history")
		:summary("See commands history.")
		:option("compact", { type = "boolean" })
		:option("time-only", { type = "boolean" })
		:option("lines", { type = "number", short = "n", default = 15 })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end
	local store = storage.new()
	local entries, err = store:load_history("shell", parsed.lines)
	store:close()
	if err then
		errmsg(err)
		return 127
	end
	local buf = buffer.new()
	for _, entry in ipairs(entries) do
		local date = style_text(tss, "builtin.history.date", os.date("%Y-%m-%d", entry.ts))
		local time = style_text(tss, "builtin.history.time", os.date("%H:%M:%S", entry.ts))
		local duration = entry.d
		local status = entry.exit
		local cmd = style_text(tss, "builtin.history.cmd.ok", entry.cmd)
		if status > 0 then
			cmd = style_text(tss, "builtin.history.cmd.fail", entry.cmd)
		end
		if parsed.compact then
			buf:put(cmd, "\n")
		elseif parsed["time-only"] then
			buf:put(time, cmd, "\n")
		else
			buf:put(date, time, cmd, "\n")
		end
	end
	local indent = tss:get_property("builtin.history", "global_indent") or 0
	term.write(std.txt.indent(buf:get(), indent) .. "\n")
	return 0
end

local wgcli = function(cmd, args)
	local args = args or {}
	if args[1] then
		if args[1] == "up" or args[1] == "apply" then
			local conf_name = args[2] or ""
			local ok, err = utils.wg_apply(conf_name)
			if err then
				errmsg(err)
				return 127
			end
			return 0
		end
		if args[1] == "down" then
			local dev_name = args[2] or ""
			local ok, err = utils.wg_down(dev_name)
			if err then
				errmsg(err)
				return 127
			end
			return 0
		end
	end
	local tss = style.new(theme)
	local wg_info = utils.wg_info()
	for net, info in pairs(wg_info) do
		term.write(
			style_text(tss, "builtin.wg.net.name", net)
				.. style_text(tss, "builtin.wg.net.pub_key", info.pub_key)
				.. "\n\n"
		)
		for pub_key, peer in pairs(info.peers) do
			local endpoint = "dynamic"
			if peer.endpoint and peer.endpoint.ip and peer.endpoint.port then
				endpoint = peer.endpoint.ip .. ":" .. peer.endpoint.port
			end
			term.write(
				style_text(tss, "builtin.wg.endpoint.name", endpoint)
					.. style_text(tss, "builtin.wg.endpoint.pub_key", pub_key)
					.. "\n"
			)
			local last_handshake = "never"
			if peer.last_handshake > 0 then
				last_handshake = std.conv.time_diff_human(peer.last_handshake) .. " ago"
			end
			term.write(
				style_text(tss, "builtin.wg.endpoint.seen", "Last handshake: " .. last_handshake)
					.. "\n"
					.. style_text(
						tss,
						"builtin.wg.endpoint.bytes",
						"↓ " .. std.conv.bytes_human(peer.bytes.rx) .. " ↑ " .. std.conv.bytes_human(peer.bytes.tx)
					)
					.. "\n"
			)
			term.write(style_text(tss, "builtin.wg.endpoint.nets", "NETS: " .. table.concat(peer.nets, ", ")) .. "\n\n")
		end
		term.write("\n")
	end
	return 0
end

local ps_help = [[
_ps_ provides a snapshot of currently running processes

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
	local parser = argparser
		.command("ps")
		:summary("Process snapshot tool.")
		:description(ps_help)
		:option("all", { type = "boolean", short = "a", note = "Show processes of all users" })
		:option("json", { type = "boolean", note = "JSON output" })
		:option("text", { type = "boolean", note = "Plain text output" })
		:option("kernel", { type = "boolean", short = "k", note = "Show kernel threads" })
		:option("format", { type = "string", short = "o", default = "pid,cmd", note = "Fields to display" })
		:option("extended", { type = "boolean", short = "x", note = "Shortcut for `pid,uid,state,cmdline` format" })
		:option("detailed", { type = "boolean", note = "Shortcut for `pid,user,state,cpu,mem,cmd` format" })
		:option("parent", { type = "number", short = "p", default = 0, note = "Show only children of this process" })
		:option("sort", { type = "number", default = 1, note = "Index of the field to sort by" })
		:option("user", { type = "string", short = "u", default = cur_user, note = "Show only processes of this user" })
		:argument("pattern", { type = "string", nargs = "?", default = ".*" })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end
	if parsed.extended then
		parsed.format = "pid,uid,state,cmdline"
	end
	if parsed.detailed then
		parsed.format = "pid,user,state,cpu,mem,cmd"
	end
	if parsed.extended and parsed.detailed then
		parsed.format = "pid,uid,state,cpu,mem_mb,cmdline"
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
	for field_name in parsed.format:gmatch("([%w_]+),?") do
		table.insert(ps_tbl_fields, field_name)
	end
	if #ps_tbl_fields == 0 then
		ps_tbl_fields = { "pid" }
	end
	local ps_tbl = {}

	local sort_field_idx = parsed.sort
	if sort_field_idx > #ps_tbl_fields or sort_field_idx < 1 then
		sort_field_idx = 1
	end

	if parsed.json then
		for _, proc in ipairs(processes) do
			if proc.user == parsed.user or parsed.all then
				if proc.cmdline:match(parsed.pattern) then
					if proc.ppid ~= 2 or parsed.kernel then
						if proc.ppid == parsed.parent or parsed.parent == 0 then
							local row = {}
							for _, col_name in ipairs(ps_tbl_fields) do
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
		if proc.user == parsed.user or parsed.all then
			if proc.cmdline:match(parsed.pattern) then
				if proc.ppid ~= 2 or parsed.kernel then
					if proc.ppid == parsed.parent or parsed.parent == 0 then
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
	if parsed.text then
		term.write("\n")
		for _, entry in ipairs(ps_tbl) do
			term.write(table.concat(entry, " ") .. "\n")
		end
		term.write("\n")
		return 0
	end
	local ps_tbl_md = std.tbl.pipe_table(ps_tbl_fields, ps_tbl)
	term.write("\n" .. markdown.render(table.concat(ps_tbl_md, "\n")).rendered .. "\n")
	return 0
end

local _M

local files_matching_help = [[
By default the name of each matched file will be inserted as
the first argument of the provided command.

Sometimes this is not what you want, so you can specify the exact
placement by using `{}` in place of one of the command's arguments:

```lsh
files_matching .txt chmod 0640 {}
```
]]
local files_matching = function(cmd, args)
	local parser = argparser
		.command("files_matching")
		:summary("Execute a command over matching files.")
		:description(files_matching_help)
		:argument("pattern", { type = "string" })
		:argument("command", { type = "string", nargs = "+", default = { "echo" } })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end
	local path, pattern = parsed.pattern:match("^(.-)([^/]+)$")
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
		for i, arg in ipairs(parsed.command) do
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

local zx = function(cmd, args)
	local parser = argparser
		.command("zx")
		:summary("Snippet launcher.")
		:argument("patterns", { type = "string", nargs = "+" })
		:build()
	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end
	for _, arg in ipairs(parsed.patterns) do
		arg = std.escape_magic_chars(arg)
	end
	local store = storage.new()
	local snippets = store:list_snippets()
	for _, snippet_name in ipairs(snippets) do
		if snippet_name:match(table.concat(parsed.patterns, ".-")) then
			local snippet = store:get_snippet(snippet_name)
			store:close(true)
			if not snippet then
				errmsg("no such snippet")
				return 33
			end
			local snippet_meta_json = snippet:match("^(.+)```lsh")
			local snippet_meta = json.decode(snippet_meta_json) or {}
			local snippet_code = snippet:match("```lsh\n(.+)\n```")
			if not snippet_code then
				errmsg("failed to parse snippet")
				return 34
			end
			local snippet_args = {}
			if not snippet_meta.args then
				snippet_meta.args = {}
			end
			term.set_raw_mode()
			local l, c = term.cursor_position()
			for _, arg in ipairs(snippet_meta.args) do
				if arg.kind == "options" then
					local chosen_option = widgets.chooser(
						arg.values,
						{ rss = theme.widget.shell, title = "Choose " .. arg.name .. " value" }
					)
					snippet_args[arg.name] = chosen_option
				end
			end
			term.go(l, c)
			term.set_sane_mode()
			local code = snippet_code:gsub("{{([%w%d_]+)}}", snippet_args)
			local txt = "# Running snippet\n\n```" .. snippet_name .. "\n" .. code .. "\n```\n"
			term.write("\n" .. markdown.render(txt).rendered .. "\n")

			if snippet_meta.confirm then
				local confirmed = widgets.simple_confirm("Are you sure? y/n\n", theme.widget.shell)
				if not confirmed then
					errmsg("Aborted.")
					return 66
				end
			end

			local script_lines = std.txt.lines(code)

			for _, line in ipairs(script_lines) do
				if line ~= "" then
					local pipeline, err = utils.parse_pipeline(line, true)
					if err then
						errmsg(err)
						return 35, err
					end
					local status, err = utils.run_pipeline(pipeline, nil, _M, nil)
					if status ~= 0 then
						errmsg(err)
						return status, err
					end
				end
			end
			return 0
		end
	end
	store:close(true)
	return 127
end

local zxscr_help = [[
  The SCR format is a 6912-byte memory dump of the ZX Spectrum display memory,
  containing bitmap data (6144 bytes) and color attributes (768 bytes).
]]

local zxscr = function(cmd, args)
	local MAX_SCALE = 8 -- Let's hardcode a guardrail...
	local parser = argparser
		.command("zxscr")
		:summary("Display ZX Spectrum SCR images in terminal.")
		:description(zxscr_help)
		:option("scale", { type = "number", short = "s", default = 1, note = "Scale factor (1-" .. MAX_SCALE .. ")" })
		:argument("file", { type = "file", note = "Path to .scr file" })
		:build()

	local parsed, status_code = parse_or_report(parser, args)
	if status_code then
		return status_code
	end

	if not parsed.file then
		errmsg("No file specified")
		return 127
	end

	if parsed.scale < 1 or parsed.scale > MAX_SCALE then
		errmsg("Scale must be between 1 and " .. MAX_SCALE)
		return 127
	end

	local ok, err = zxscr_mod.display(parsed.file, { scale = parsed.scale })
	if not ok then
		errmsg(err)
		return 127
	end

	term.write("\n")
	return 0
end

local builtins = {
	["ls"] = list_dir,
	["cd"] = change_dir,
	["mkdir"] = mkdir,
	["%.%.+"] = upper_dir,
	["zx"] = zx,
	["rm"] = file_remove,
	["rmrf"] = file_remove,
	["kat"] = kat,
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
	["wgcli"] = wgcli,
	["job"] = job,
	["zxscr"] = zxscr,
}

local dont_fork = {
	zx = true,
	z = true,
	cd = true,
	setenv = true,
	export = true,
	unsetenv = true,
	ktl = true,
	kat = true,
	job = true,
	["aws.region"] = true,
	["aws.profile"] = true,
}

local needy = {
	job = true,
	kat = true,
}

local get = function(cmd)
	for k, f in pairs(builtins) do
		if cmd:match("^" .. k .. "$") then
			local fork = true
			if dont_fork[cmd] or cmd:match("^%.%.+") then
				fork = false
			end
			return { name = cmd, func = f, fork = fork, needy = needy[cmd] }
		end
	end
	return nil
end

_M = { get = get }
return _M
