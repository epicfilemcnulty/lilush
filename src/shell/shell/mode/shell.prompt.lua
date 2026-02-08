-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local buffer = require("string.buffer")
local theme = require("theme").get("shell")
local style = require("term.tss")
local tss = style.new(theme)
local style_text = function(ctx, ...)
	return ctx:apply(...).text
end

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
	buf:put(style_text(tss, "prompt.shell.sep", "("), style_text(tss, "prompt.shell.git.logo"))
	if status.clean then
		buf:put(style_text(tss, "prompt.shell.git.branch.clean", status.branch))
	else
		buf:put(style_text(tss, "prompt.shell.git.branch.dirty", status.branch))
	end

	if status.modified > 0 then
		buf:put(style_text(tss, "prompt.shell.git.modified", status.modified))
	end
	if status.staged > 0 then
		buf:put(style_text(tss, "prompt.shell.git.staged", status.staged))
	end
	if status.untracked > 0 then
		buf:put(style_text(tss, "prompt.shell.git.untracked", status.untracked))
	end

	if status.ahead > 0 or status.behind > 0 then
		buf:put(
			style_text(tss, "prompt.shell.sep", ""),
			style_text(tss, "prompt.shell.git.remote", status.remote_branch)
		)
	end
	if status.ahead > 0 then
		buf:put(style_text(tss, "prompt.shell.git.ahead", status.ahead))
	end
	if status.behind > 0 then
		buf:put(style_text(tss, "prompt.shell.git.behind", status.behind))
	end
	if status.tag ~= "" then
		buf:put(style_text(tss, "prompt.shell.git.tag_sep"), style_text(tss, "prompt.shell.git.tag", status.tag))
	end
	buf:put(style_text(tss, "prompt.shell.sep", ")"))
	return buf:get()
end

local aws_prompt = function(self)
	local aws_profile = os.getenv("AWS_PROFILE")
	local aws_region = os.getenv("AWS_REGION")

	if aws_profile and aws_region then
		local buf = buffer.new()
		buf:put(
			style_text(tss, "prompt.shell.sep", "("),
			style_text(tss, "prompt.shell.aws.logo"),
			style_text(tss, "prompt.shell.aws.profile", aws_profile),
			style_text(tss, "prompt.shell.aws.region", aws_region),
			style_text(tss, "prompt.shell.sep", ")")
		)
		return buf:get()
	end
	return nil
end

local vault_prompt = function(self)
	if self.__state.vault_status then
		return style_text(tss, "prompt.shell.vault." .. self.__state.vault_status)
	end
	return nil
end

local user_prompt = function(self)
	local buf = buffer.new()
	if self.__state.user ~= "root" then
		buf:put(style_text(tss, "prompt.shell.user.user", self.__state.user))
	else
		buf:put(style_text(tss, "prompt.shell.user.root", self.__state.user))
	end
	buf:put("@", style_text(tss, "prompt.shell.user.hostname", self.__state.hostname))
	return buf:get()
end

local kube_prompt = function(self)
	local profile = os.getenv("KUBECONFIG")
	if not profile then
		profile = std.fs.readlink(self.__state.home .. "/.kube/config") or ""
	end
	profile = profile:match("/?([^/]+)$")
	local ns = os.getenv("KTL_NAMESPACE") or "kube-system"
	local buf = buffer.new()
	buf:put(
		style_text(tss, "prompt.shell.sep", "("),
		style_text(tss, "prompt.shell.kube.logo"),
		style_text(tss, "prompt.shell.kube.profile", profile),
		style_text(tss, "prompt.shell.kube.ns", ns),
		style_text(tss, "prompt.shell.sep", ")")
	)
	return buf:get()
end

local dir_prompt = function(self)
	local current_dir = std.fs.cwd():gsub(self.__state.home, "~")
	return style_text(tss, "prompt.shell.sep", "(")
		.. style_text(tss, "prompt.shell.dir", current_dir)
		.. style_text(tss, "prompt.shell.sep", ")")
end

local python_prompt = function(self)
	local virtual_env = os.getenv("VIRTUAL_ENV") or "NONE"
	virtual_env = virtual_env:gsub("/$", "")
	virtual_env = virtual_env:match("[^/]+$")
	return style_text(tss, "prompt.shell.sep", "(")
		.. style_text(tss, "prompt.shell.python.logo")
		.. style_text(tss, "prompt.shell.python.env", virtual_env)
		.. style_text(tss, "prompt.shell.sep", ")")
end

local ssh_prompt = function(self)
	local config_file = self.__state.home .. "/.ssh/config"
	local target = std.fs.readlink(config_file)
	if target then
		local profile = target:match("profiles/([^/]+)/config")
		if profile then
			return style_text(tss, "prompt.shell.sep", "(")
				.. style_text(tss, "prompt.shell.ssh.logo")
				.. style_text(tss, "prompt.shell.ssh.profile", profile)
				.. style_text(tss, "prompt.shell.sep", ")")
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
	local updates = options or {}
	for key, value in pairs(updates) do
		self.__state[key] = value
	end

	local filtered = {}
	for _, block in ipairs(self.__state.blocks) do
		if blocks_map[block] then
			table.insert(filtered, block)
		end
	end
	self.__state.blocks = filtered
end

local blocks_order = { "aws", "kube", "ssh", "user", "dir", "git", "python", "vault" }

local get = function(self)
	local prompt = buffer.new()
	for _, block in ipairs(blocks_order) do
		if std.tbl.contains(self.__state.blocks, block) then
			local out = blocks_map[block](self)
			if out then
				prompt:put(out)
			end
		end
	end
	if self.__state.lines and self.__state.lines > 1 then
		prompt:put(style_text(tss, "prompt.shell.sep", "["))
		prompt:put(style_text(tss, "prompt.shell.sep", tostring(self.__state.line)))
		prompt:put(style_text(tss, "prompt.shell.sep", "]"))
	end
	prompt:put("$ ")
	return prompt:get()
end

local toggle_block = function(self, block)
	if blocks_map[block] then
		local idx = std.tbl.contains(self.__state.blocks, block)
		if idx then
			table.remove(self.__state.blocks, idx)
		else
			table.insert(self.__state.blocks, block)
		end
	end
end

local get_blocks = function(self)
	return self.__state.blocks
end

local set_blocks = function(self, blocks)
	self.__state.blocks = blocks or {}
end

local new = function(config)
	local prompt = {
		cfg = config or {},
		__state = {
			home = os.getenv("HOME") or "/tmp",
			user = os.getenv("USER") or "nobody",
			hostname = tostring(std.fs.read_file("/etc/hostname")):gsub("\n", ""),
			pwd = std.fs.cwd() or "",
			blocks = {},
			vault_status = "unknown",
		},
		get = get,
		set = set,
		get_blocks = get_blocks,
		set_blocks = set_blocks,
		toggle_block = toggle_block,
	}
	prompt:set(prompt.cfg)
	if #prompt.__state.blocks == 0 then
		local user_blocks_str = os.getenv("LILUSH_PROMPT") or "user,dir"
		for block in user_blocks_str:gmatch("(%w+),?") do
			table.insert(prompt.__state.blocks, block)
		end
	end
	return prompt
end

return { new = new }
