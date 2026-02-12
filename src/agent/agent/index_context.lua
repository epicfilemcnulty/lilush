-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local buffer = require("string.buffer")

local function join_path(base, filename)
	if type(filename) == "string" and filename:match("^/") then
		return filename
	end
	if base == "/" then
		return "/" .. filename
	end
	if base == "" then
		return filename
	end
	return base .. "/" .. filename
end

local function is_within_dir(path, root)
	if type(path) ~= "string" or path == "" then
		return false
	end
	if type(root) ~= "string" or root == "" then
		return false
	end
	if path == root then
		return true
	end
	return path:match("^" .. std.escape_magic_chars(root) .. "/") ~= nil
end

local function detect_repo_root()
	local result = std.ps.exec_simple("git rev-parse --show-toplevel")
	if type(result) ~= "table" then
		return nil
	end
	if tonumber(result.status) ~= 0 then
		return nil
	end
	local root = result.stdout and result.stdout[1] or nil
	if type(root) ~= "string" or root == "" then
		return nil
	end
	return root
end

local function cwd_header(path, in_git_repo)
	if in_git_repo then
		return "## Project instructions from " .. path
	end
	return "## Instructions from " .. path
end

local function compose_index_content(entries, in_git_repo, repo_root)
	local out = buffer.new()
	if #entries > 0 and in_git_repo and type(repo_root) == "string" and repo_root ~= "" then
		out:put("Repo root is at ", repo_root, "\n\n")
	end
	for _, entry in ipairs(entries) do
		out:put(entry.header, "\n\n", entry.content, "\n\n")
	end
	return out:get()
end

local function resolve(opts)
	opts = opts or {}

	local cache = opts.cache or {}
	local index_file = opts.index_file
	local cwd = std.fs.cwd() or ""
	local git_lookup_performed = false
	local git_lookup_reason = nil

	if cache.repo_root and is_within_dir(cwd, cache.repo_root) then
		git_lookup_reason = "cache_hit_repo"
	elseif cache.in_git_repo == false and cache.last_cwd == cwd then
		git_lookup_reason = "cache_hit_non_repo"
	else
		git_lookup_performed = true
		git_lookup_reason = "refreshed"
		local repo_root = detect_repo_root()
		if repo_root then
			cache.repo_root = repo_root
			cache.in_git_repo = true
		else
			cache.repo_root = nil
			cache.in_git_repo = false
		end
	end
	cache.last_cwd = cwd

	local in_git_repo = cache.in_git_repo == true and type(cache.repo_root) == "string" and cache.repo_root ~= ""
	local repo_root = in_git_repo and cache.repo_root or nil
	local checks = {}
	local entries = {}
	local seen_paths = {}

	if type(index_file) == "string" and index_file ~= "" then
		if repo_root then
			local root_path = join_path(repo_root, index_file)
			seen_paths[root_path] = true
			if std.fs.file_exists(root_path, "f") then
				local content = std.fs.read_file(root_path)
				if content and content ~= "" then
					entries[#entries + 1] = {
						path = root_path,
						source = "repo_root",
						header = "## Project instructions from " .. root_path,
						content = content,
					}
					checks[#checks + 1] = { path = root_path, source = "repo_root", status = "loaded" }
				elseif content ~= nil then
					checks[#checks + 1] = { path = root_path, source = "repo_root", status = "empty" }
				else
					checks[#checks + 1] = { path = root_path, source = "repo_root", status = "missing" }
				end
			else
				checks[#checks + 1] = { path = root_path, source = "repo_root", status = "missing" }
			end
		end

		local cwd_path = join_path(cwd, index_file)
		if seen_paths[cwd_path] then
			checks[#checks + 1] = { path = cwd_path, source = "cwd", status = "duplicate_skipped" }
		elseif std.fs.file_exists(cwd_path, "f") then
			local content = std.fs.read_file(cwd_path)
			if content and content ~= "" then
				entries[#entries + 1] = {
					path = cwd_path,
					source = "cwd",
					header = cwd_header(cwd_path, in_git_repo),
					content = content,
				}
				checks[#checks + 1] = { path = cwd_path, source = "cwd", status = "loaded" }
			elseif content ~= nil then
				checks[#checks + 1] = { path = cwd_path, source = "cwd", status = "empty" }
			else
				checks[#checks + 1] = { path = cwd_path, source = "cwd", status = "missing" }
			end
		else
			checks[#checks + 1] = { path = cwd_path, source = "cwd", status = "missing" }
		end
	end

	return {
		index_file = index_file,
		cwd = cwd,
		repo_root = repo_root,
		in_git_repo = in_git_repo,
		git_lookup_performed = git_lookup_performed,
		git_lookup_reason = git_lookup_reason,
		checks = checks,
		entries = entries,
		index_content = compose_index_content(entries, in_git_repo, repo_root),
		cache = cache,
	}
end

return {
	resolve = resolve,
}
