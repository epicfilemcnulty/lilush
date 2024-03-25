-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local buffer = require("string.buffer")
local term = require("term")
local theme = require("shell.theme")
local tss_gen = require("term.tss")
local tss = tss_gen.new(theme)

local git_prompt = function(self)
	local resp = std.exec_simple("git status --porcelain --branch")
	local status_lines = resp.stdout

	if not status_lines or #status_lines == 0 or status_lines[1] == "" then
		return nil
	end

	local tag = std.exec_one_line("git describe --tags")
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
		local branch_info = std.exec_one_line("git branch")
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
	local profile = os.getenv("KUBECONFIG") or "default"
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
	local current_dir = std.cwd():gsub(self.home, "~")
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

local available_blocks = {
	aws = aws_prompt,
	git = git_prompt,
	user = user_prompt,
	dir = dir_prompt,
	kube = kube_prompt,
	python = python_prompt,
}

local set = function(self, options, export)
	local export = export or false
	for k, v in pairs(options) do
		self[k] = v
	end
	self.prompts = self.prompts or "user,dir"
	if export then
		std.setenv("LILUSH_PROMPT", self.prompts)
	end
end

local get = function(self)
	local enabled = {}
	local enabled_blocks = os.getenv("LILUSH_PROMPT") or self.prompts
	for b in enabled_blocks:gmatch("(%w+),?") do
		table.insert(enabled, b)
	end
	local prompt = ""
	for _, b in ipairs(enabled) do
		if available_blocks[b] then
			local out = available_blocks[b](self)
			if out then
				prompt = prompt .. out
			end
		end
	end
	return prompt .. "$ "
end

return {
	set = set,
	get = get,
}
