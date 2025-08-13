-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local buffer = require("string.buffer")
local theme = require("shell.theme")
local style = require("term.tss")
local tss = style.new(theme)

local git_prompt = function(self)
	local resp = std.ps.exec_simple("git status --porcelain --branch")
	local status_lines = resp.stdout

	if not status_lines or #status_lines == 0 or status_lines[1] == "" then
		return nil
	end

	local tag = std.ps.exec_one_line("git describe --tags")
	local status = {
		branch = "",
		remote_branch = "",
		tag = tag or "",
		clean = false,
		modified = 0,
		staged = 0,
		untracked = 0,
		ahead = 0,
		behind = 0,
	}
	if #status_lines == 1 then
		status.clean = true
	end

	local branch_line = table.remove(status_lines, 1)
	if branch_line:match("HEAD") then
		local branch_info = std.ps.exec_one_line("git branch")
		status.branch = "HEAD" .. "@" .. branch_info:match("detached %w+ ([^)]+)")
	else
		status.branch = branch_line:match("## ([^.]+)")
		status.remote_branch = branch_line:match("^## [^.]+%.%.%.([^ ]+)")
	end

	for _, line in ipairs(status_lines) do
		if line:match("^%?") then
			status.untracked = status.untracked + 1
		elseif line:match("^ [DM]") or line:match("^MM") then
			status.modified = status.modified + 1
		elseif line:match("^[DAM]") then
			status.staged = status.staged + 1
		end
	end

	status.ahead = tonumber(branch_line:match("%[ahead ([%d%w]+)%]")) or 0
	status.behind = tonumber(branch_line:match("%[behind ([%d%w]+)%]")) or 0

	local buf = buffer.new()
	buf:put(tss:apply("prompts.shell.sep", "("), tss:apply("prompts.shell.git.logo"))
	if status.clean then
		buf:put(tss:apply("prompts.shell.git.branch.clean", status.branch))
	else
		buf:put(tss:apply("prompts.shell.git.branch.dirty", status.branch))
	end

	if status.modified > 0 then
		buf:put(tss:apply("prompts.shell.git.modified", status.modified))
	end
	if status.staged > 0 then
		buf:put(tss:apply("prompts.shell.git.staged", status.staged))
	end
	if status.untracked > 0 then
		buf:put(tss:apply("prompts.shell.git.untracked", status.untracked))
	end

	if status.ahead > 0 or status.behind > 0 then
		buf:put(
			tss:apply("prompts.shell.sep", ""),
			tss:apply("prompts.shell.git.remote", status.remote_branch)
		)
	end
	if status.ahead > 0 then
		buf:put(tss:apply("prompts.shell.git.ahead", status.ahead))
	end
	if status.behind > 0 then
		buf:put(tss:apply("prompts.shell.git.behind", status.behind))
	end
	if status.tag ~= "" then
		buf:put(tss:apply("prompts.shell.git.tag_sep"), tss:apply("prompts.shell.git.tag", status.tag))
	end
	buf:put(tss:apply("prompts.shell.sep", ")"))
	return buf:get()
end

local aws_prompt = function(self)
	local aws_profile = os.getenv("AWS_PROFILE")
	local aws_region = os.getenv("AWS_REGION")

	if aws_profile and aws_region then
		local buf = buffer.new()
		buf:put(
			tss:apply("prompts.shell.sep", "("),
			tss:apply("prompts.shell.aws.logo"),
			tss:apply("prompts.shell.aws.profile", aws_profile),
			tss:apply("prompts.shell.aws.region", aws_region),
			tss:apply("prompts.shell.sep", ")")
		)
		return buf:get()
	end
	return nil
end

local vault_prompt = function(self)
	if self.vault_status then
		return tss:apply("prompts.shell.vault." .. self.vault_status)
	end
	return nil
end

local user_prompt = function(self)
	local buf = buffer.new()
	if self.user ~= "root" then
		buf:put(tss:apply("prompts.shell.user.user", self.user))
	else
		buf:put(tss:apply("prompts.shell.user.root", self.user))
	end
	buf:put("@", tss:apply("prompts.shell.user.hostname", self.hostname))
	return buf:get()
end

local kube_prompt = function(self)
	local profile = os.getenv("KUBECONFIG")
	local home = os.getenv("HOME") or ""
	if not profile then
		profile = std.fs.readlink(home .. "/.kube/config") or ""
	end
	profile = profile:match("/?([^/]+)$")
	local ns = os.getenv("KTL_NAMESPACE") or "kube-system"
	local buf = buffer.new()
	buf:put(
		tss:apply("prompts.shell.sep", "("),
		tss:apply("prompts.shell.kube.logo"),
		tss:apply("prompts.shell.kube.profile", profile),
		tss:apply("prompts.shell.kube.ns", ns),
		tss:apply("prompts.shell.sep", ")")
	)
	return buf:get()
end

local dir_prompt = function(self)
	local current_dir = std.fs.cwd():gsub(self.home, "~")
	return tss:apply("prompts.shell.sep", "(")
		.. tss:apply("prompts.shell.dir", current_dir)
		.. tss:apply("prompts.shell.sep", ")")
end

local python_prompt = function(self)
	local virtual_env = os.getenv("VIRTUAL_ENV") or "NONE"
	virtual_env = virtual_env:gsub("/$", "")
	virtual_env = virtual_env:match("[^/]+$")
	return tss:apply("prompts.shell.sep", "(")
		.. tss:apply("prompts.shell.python.logo")
		.. tss:apply("prompts.shell.python.env", virtual_env)
		.. tss:apply("prompts.shell.sep", ")")
end

local ssh_prompt = function(self)
	local config_file = self.home .. "/.ssh/config"
	local target = std.fs.readlink(config_file)
	if target then
		local profile = target:match("profiles/([^/]+)/config")
		if profile then
			return tss:apply("prompts.shell.sep", "(")
				.. tss:apply("prompts.shell.ssh.logo")
				.. tss:apply("prompts.shell.ssh.profile", profile)
				.. tss:apply("prompts.shell.sep", ")")
		end
	end
end

local blocks_map = {
	aws = aws_prompt,
	kube = kube_prompt,
	python = python_prompt,
	user = user_prompt,
	dir = dir_prompt,
	git = git_prompt,
	ssh = ssh_prompt,
	vault = vault_prompt,
}

local set = function(self, options)
	local options = options or {}
	for k, v in pairs(options) do
		self[k] = v
	end
	-- Sanity check for valid blocks
	for i, b in ipairs(self.blocks) do
		if not blocks_map[b] then
			table.remove(self.blocks, i)
		end
	end
end

local blocks_order = { "aws", "kube", "ssh", "user", "dir", "git", "python", "vault" }

local get = function(self)
	local prompt = buffer.new()
	for _, b in ipairs(blocks_order) do
		if std.tbl.contains(self.blocks, b) then
			local out = blocks_map[b](self)
			if out then
				prompt:put(out)
			end
		end
	end
	if self.lines and self.lines > 1 then
		prompt:put(tss:apply("prompts.shell.sep", "["))
		prompt:put(tss:apply("prompts.shell.sep", tostring(self.line)))
		prompt:put(tss:apply("prompts.shell.sep", "]"))
	end
	prompt:put("$ ")
	return prompt:get()
end

local toggle_block = function(self, block)
	if blocks_map[block] then
		local idx = std.tbl.contains(self.blocks, block)
		if idx then
			table.remove(self.blocks, idx)
		else
			table.insert(self.blocks, block)
		end
	end
end

local new = function(options)
	local prompt = {
		home = os.getenv("HOME") or "/tmp",
		user = os.getenv("USER") or "nobody",
		hostname = tostring(std.fs.read_file("/etc/hostname")):gsub("\n", ""),
		pwd = std.fs.cwd() or "",
		blocks = {},
		vault_status = "unknown",
		get = get,
		set = set,
		toggle_block = toggle_block,
	}
	prompt:set(options)
	if #prompt.blocks == 0 then
		local user_blocks_str = os.getenv("LILUSH_PROMPT") or "user,dir"
		for b in user_blocks_str:gmatch("(%w+),?") do
			table.insert(prompt.blocks, b)
		end
	end
	return prompt
end

return { new = new }
