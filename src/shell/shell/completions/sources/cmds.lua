-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local utils = require("shell.utils")

local git_subcommands = {
	["status"] = true,
	["checkout"] = true,
	["commit"] = true,
	["diff"] = true,
	["merge"] = true,
	["log"] = true,
	["pull"] = true,
	["push"] = true,
}

local docker_subcommands = {
	["start"] = true,
	["stop"] = true,
	["images"] = true,
	["inspect"] = true,
	["run"] = true,
	["tag"] = true,
	["pull"] = true,
	["push"] = true,
	["exec"] = true,
	["ps"] = true,
	["rm"] = true,
	["rmi"] = true,
	["volume"] = true,
}

local ktl_subcommands = {
	["profile"] = true,
	["get"] = true,
	["delete"] = true,
	["apply"] = true,
	["logs"] = true,
}

local kubectl_completions = function(self, args)
	local candidates = {}
	if #args > 0 then
		if #args == 1 then
			for cmd, _ in pairs(ktl_subcommands) do
				if cmd:match("^" .. std.escape_magic_chars(args[1])) then
					table.insert(candidates, cmd:sub(#args[1] + 1))
				end
			end
			return candidates
		end
		if args[2] and args[1] == "profile" then
			local home = os.getenv("HOME") or ""
			local profiles = std.list_files(home .. "/.kube/cfgs")
			local p = args[2] or ""
			for profile, _ in pairs(profiles) do
				if profile:match("^" .. std.escape_magic_chars(p)) then
					table.insert(candidates, profile:sub(#p + 1))
				end
			end
		end
	end
	utils.sort_by_smaller_size(candidates)
	return candidates
end

local ssh_profile_completions = function(self, args)
	local args = args or {}
	local candidates = {}
	if args[1] then
		local home = os.getenv("HOME") or ""
		local files = std.list_files(home .. "/.ssh/profiles/")
		local profiles = {}
		if files then
			for file, st in pairs(files) do
				if st.mode == "f" then
					table.insert(profiles, file)
				end
			end
		end
		for _, profile in ipairs(profiles) do
			if profile:match("^" .. std.escape_magic_chars(args[1])) then
				table.insert(candidates, profile:sub(#args[1] + 1))
			end
		end
	end
	utils.sort_by_smaller_size(candidates)
	return candidates
end

local ssh_completions = function(self, args)
	local args = args or {}
	local candidates = {}
	if #args > 0 then
		local arg = args[#args]
		local home = os.getenv("HOME") or ""
		local ssh_config = std.read_file(home .. "/.ssh/config") or ""
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
	utils.sort_by_smaller_size(candidates)
	return candidates
end

local git_completions = function(self, args)
	local candidates = {}
	local arg = args[#args]
	for cmd, _ in pairs(git_subcommands) do
		if cmd:match("^" .. std.escape_magic_chars(arg)) then
			table.insert(candidates, cmd:sub(#arg + 1))
		end
	end
	utils.sort_by_smaller_size(candidates)
	return candidates
end

local docker_completions = function(self, args)
	local candidates = {}
	local arg = args[#args]
	for cmd, _ in pairs(docker_subcommands) do
		if cmd:match("^" .. std.escape_magic_chars(arg)) then
			table.insert(candidates, cmd:sub(#arg + 1))
		end
	end
	utils.sort_by_smaller_size(candidates)
	return candidates
end

local list = {
	["git"] = function(self, args)
		return git_completions(self, args)
	end,
	["ktl"] = function(self, args)
		return kubectl_completions(self, args)
	end,
	["docker"] = function(self, args)
		return docker_completions(self, args)
	end,
	["ssh.profile"] = function(self, args)
		return ssh_profile_completions(self, args)
	end,
	["ssh"] = function(self, args)
		return ssh_completions(self, args)
	end,
}

local commands = function(self, cmd, args)
	if #args > 0 then
		if list[cmd] then
			return list[cmd](self, args)
		end
	end
	return {}
end

local new = function()
	local source = { complete = commands, list = list }
	return source
end

return { new = new }
