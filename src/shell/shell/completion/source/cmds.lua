-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local kubectl_profile_completions = function(self, args)
	local candidates = {}
	if args[1] then
		local home = os.getenv("HOME") or ""
		local profiles = std.fs.list_files(home .. "/.kube/cfgs")
		local p = args[1] or ""
		for profile, _ in pairs(profiles) do
			if profile:match("^" .. std.escape_magic_chars(p)) then
				table.insert(candidates, profile:sub(#p + 1))
			end
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local kubectl_completions = function(self, args)
	local candidates = {}
	if #args == 1 then
		for cmd, _ in pairs(self.cfg.ktl_subcommands) do
			if cmd:match("^" .. std.escape_magic_chars(args[1])) then
				table.insert(candidates, cmd:sub(#args[1] + 1))
			end
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local ssh_profile_completions = function(self, args)
	local cmd_args = args or {}
	local candidates = {}
	if cmd_args[1] then
		local home = os.getenv("HOME") or ""
		local dirs = std.fs.list_dir(home .. "/.ssh/profiles/")
		local profiles = {}
		if dirs then
			for _, d in ipairs(dirs) do
				table.insert(profiles, d)
			end
		end
		for _, profile in ipairs(profiles) do
			if profile:match("^" .. std.escape_magic_chars(cmd_args[1])) then
				table.insert(candidates, profile:sub(#cmd_args[1] + 1))
			end
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local ssh_completions = function(self, args)
	local cmd_args = args or {}
	local candidates = {}
	if #cmd_args > 0 then
		local arg = cmd_args[#cmd_args]
		local home = os.getenv("HOME") or ""
		local ssh_config = std.fs.read_file(home .. "/.ssh/config") or ""
		local hosts = {}
		for host in ssh_config:gmatch("Host (%S+)") do
			table.insert(hosts, host)
		end
		for _, host in ipairs(hosts) do
			if host:match("^" .. std.escape_magic_chars(arg)) then
				table.insert(candidates, host:sub(#arg + 1))
			end
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local git_completions = function(self, args)
	local candidates = {}
	local arg = args[#args]
	for cmd, _ in pairs(self.cfg.git_subcommands) do
		if cmd:match("^" .. std.escape_magic_chars(arg)) then
			table.insert(candidates, cmd:sub(#arg + 1))
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local docker_completions = function(self, args)
	local candidates = {}
	local arg = args[#args]
	for cmd, _ in pairs(self.cfg.docker_subcommands) do
		if cmd:match("^" .. std.escape_magic_chars(arg)) then
			table.insert(candidates, cmd:sub(#arg + 1))
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local job_completions = function(self, args)
	local candidates = {}
	local arg = args[#args]
	for cmd, _ in pairs(self.cfg.job_subcommands) do
		if cmd:match("^" .. std.escape_magic_chars(arg)) then
			table.insert(candidates, cmd:sub(#arg + 1))
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local commands = function(self, cmd, args)
	if #args > 0 then
		local list = self.cfg.list
		if list[cmd] then
			return list[cmd](self, args)
		end
	end
	return {}
end

local new = function(config)
	local cfg = {
		git_subcommands = {
			status = true,
			checkout = true,
			commit = true,
			diff = true,
			merge = true,
			log = true,
			pull = true,
			push = true,
			branch = true,
		},
		docker_subcommands = {
			start = true,
			stop = true,
			images = true,
			inspect = true,
			run = true,
			tag = true,
			pull = true,
			push = true,
			exec = true,
			ps = true,
			rm = true,
			rmi = true,
			volume = true,
		},
		ktl_subcommands = {
			describe = true,
			["port-forward"] = true,
			get = true,
			delete = true,
			apply = true,
			logs = true,
		},
		job_subcommands = {
			list = true,
			start = true,
			kill = true,
			attach = true,
			reap = true,
		},
		list = {},
	}
	if config then
		std.tbl.merge(cfg, config)
	end

	cfg.list = {
		job = function(self, args)
			return job_completions(self, args)
		end,
		git = function(self, args)
			return git_completions(self, args)
		end,
		ktl = function(self, args)
			return kubectl_completions(self, args)
		end,
		["ktl.profile"] = function(self, args)
			return kubectl_profile_completions(self, args)
		end,
		docker = function(self, args)
			return docker_completions(self, args)
		end,
		["ssh.profile"] = function(self, args)
			return ssh_profile_completions(self, args)
		end,
		ssh = function(self, args)
			return ssh_completions(self, args)
		end,
	}

	local source = {
		cfg = cfg,
		search = commands,
	}
	return source
end

return { new = new }
