-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local core = require("std.core")
local json = require("cjson.safe")
local storage = require("storage")

local dir_history_complete = function(args)
	local candidates = {}
	local pattern = ".-"
	for _, arg in ipairs(args) do
		pattern = pattern .. arg .. ".-"
	end
	local store = storage.new()
	local res, err = store:get_set_range("history/shell", 0, -1)
	store:close(true)
	if err then
		return nil, "can't get history: " .. tostring(err)
	end
	local cwd = std.cwd()
	local home = os.getenv("HOME") or ""
	cwd = cwd:gsub("^" .. home, "~")

	local scores = {}
	for i, v in ipairs(res) do
		local entry = json.decode(v)
		if entry and entry.cwd:match(pattern) then
			local score = scores[entry.cwd] or 0
			score = score + 1
			scores[entry.cwd] = score
		end
	end
	local candidates = {}
	for k, v in pairs(scores) do
		table.insert(candidates, k)
	end
	table.sort(candidates, function(a, b)
		if scores[a] == scores[b] then
			return a > b
		else
			return scores[a] > scores[b]
		end
	end)
	for i, c in ipairs(candidates) do
		candidates[i] = " " .. c
	end
	return candidates
end

local zx_complete = function(args)
	local candidates = {}
	local pattern = ".-"
	for _, arg in ipairs(args) do
		pattern = pattern .. arg .. ".-"
	end
	local store = storage.new()
	local snippets = store:list_hash_keys("snippets") or {}
	store:close(true)
	for _, snippet in ipairs(snippets) do
		if snippet:match(pattern) then
			table.insert(candidates, snippet)
		end
	end
	candidates = std.alphanumsort(candidates)
	for i, c in ipairs(candidates) do
		candidates[i] = " " .. c
	end
	return candidates
end

local replace_envs_and_home = function(arg)
	local env = std.environ()
	local arg = arg:gsub("%${([^}]+)}", env)
	arg = arg:gsub("^(~)", env.HOME)
	return arg
end

local parse_pipeline, run_pipeline

local parse_cmdline = function(input, with_inlines)
	local with_inlines = with_inlines or false
	local substitutes = {}
	if with_inlines then
		local ppls = std.find_all_positions(input, "%$%b()")
		for i, ppl in ipairs(ppls) do
			local pipeline_raw = input:sub(ppl[1] + 2, ppl[2] - 1)
			local pipeline = parse_pipeline(pipeline_raw)
			local sub = ""
			if pipeline then
				local out_pipe = std.pipe()
				local status, err = run_pipeline(pipeline, out_pipe.inn)
				local out = out_pipe:read()
				out_pipe:close_out()
				if out then
					sub = out:gsub("\n$", "")
				end
			end
			table.insert(substitutes, sub)
		end
	end
	local sub_idx = 1
	local sub_func = function(cap)
		local sub = substitutes[sub_idx] or ""
		sub_idx = sub_idx + 1
		return sub
	end
	local input = input:gsub("(%$%b())", sub_func)

	local singles = std.find_all_positions(input, "%b''")
	local doubles = std.find_all_positions(input, '%b""')
	local curlies = std.find_all_positions(input, "{{.-}}")

	local all = {}
	for _, v in ipairs(singles) do
		table.insert(all, { t = "singles", p = v })
	end
	for _, v in ipairs(doubles) do
		table.insert(all, { t = "doubles", p = v })
	end
	for _, v in ipairs(curlies) do
		table.insert(all, { t = "curlies", p = v })
	end

	table.sort(all, function(a, b)
		return a.p[1] < b.p[1]
	end)

	local sorted = {}
	local last_end = 0
	for i, v in ipairs(all) do
		if v.p[1] > last_end then
			last_end = v.p[2]
			table.insert(sorted, v)
		end
	end

	local args = {}

	if #sorted > 0 then
		local start = 1
		for i, v in ipairs(sorted) do
			if i > 1 then
				start = sorted[i - 1].p[2] + 1
			end
			local before = input:sub(start, v.p[1] - 1)
			for w in before:gmatch("([^ ]+)") do
				table.insert(args, replace_envs_and_home(w))
			end
			local width = 1
			if v.t == "curlies" then
				width = 2
			end
			local complex_arg = input:sub(v.p[1] + width, v.p[2] - width)
			if v.t ~= "singles" then
				complex_arg = replace_envs_and_home(complex_arg)
			end
			table.insert(args, complex_arg)
		end
		local after = input:sub(sorted[#sorted].p[2] + 1)
		for w in after:gmatch("([^ ]+)") do
			table.insert(args, replace_envs_and_home(w))
		end
	else
		for w in input:gmatch("([^ ]+)") do
			table.insert(args, replace_envs_and_home(w))
		end
	end
	local cmd = table.remove(args, 1)
	return cmd, args
end

parse_pipeline = function(input, with_inlines)
	local with_inlines = with_inlines or false
	local input = input or ""
	-- `cat file1 | cmd1 | cmd2 | cmd3 > outfile.txt`
	local cmdlines = {}
	for cmdline in input:gmatch("([^|]+)|?") do
		local line = cmdline:gsub("^(%s+)", ""):gsub("(%s+)$", "") -- tream leading & trailing spaces
		table.insert(cmdlines, line)
	end
	if #cmdlines > 1 then
		for i = 2, #cmdlines - 1 do
			if cmdlines[i]:match("<") or cmdlines[i]:match(">") then
				return nil, "only first/last elements of the pipeline can redirect i/o to file"
			end
		end
	end

	local parsed_cmdlines = {}

	if #cmdlines > 0 then
		local first_command = cmdlines[1]
		local input_file = first_command:match("^[^<]+<([^>]+)")
		local c1 = first_command:match("^(.-)[<>]")

		local last_command = cmdlines[#cmdlines]
		local output_file = last_command:match("^[^>]+>(.*)$")
		local c2 = last_command:match("^(.-)[<>]")

		for i, line in ipairs(cmdlines) do
			local l = {}
			if line == first_command then
				if input_file then
					l.cmd, l.args = parse_cmdline(c1, with_inlines)
					l.input_file = input_file:gsub("^(%s+)", ""):gsub("(%s+)$", "")
				end
			end
			if line == last_command then
				if output_file then
					l.output_file = output_file:gsub("^(%s+)", "")
					if not l.cmd then
						l.cmd, l.args = parse_cmdline(c2, with_inlines)
					end
				end
			end
			if not l.cmd then
				l.cmd, l.args = parse_cmdline(line, with_inlines)
			end
			table.insert(parsed_cmdlines, l)
		end
	end
	return parsed_cmdlines
end

run_pipeline = function(pipeline, stdout, builtins, extra)
	local builtins = builtins
	local pipes = {}
	local pids = {}
	for i, cmdline in ipairs(pipeline) do
		pipes[i] = std.pipe()
		local stdout = stdout
		local stdin
		if pipeline[i].input_file then
			stdin = core.open(pipeline[i].input_file)
		end
		if i > 1 then
			stdin = pipes[i - 1].out
		end
		if pipeline[i].output_file then
			stdout = core.open(pipeline[i].output_file, 2)
		end
		if i < #pipeline then
			stdout = pipes[i].inn
		end
		local cmd = pipeline[i].cmd
		local args = pipeline[i].args
		if builtins and builtins.get then
			local builtin = builtins.get(cmd)
			if builtin then
				if builtin.fork == false then
					return builtin.func(builtin.name, args)
				end
				if builtin.needy then
					builtin.extra = extra
				end
				cmd = builtin
			end
		end
		pids[i] = std.launch(cmd, stdin, stdout, nil, unpack(args))
		if stdin then
			core.close(stdin)
		end
		if stdout then
			core.close(stdout)
		end
	end
	for i, pid in ipairs(pids) do
		if pid ~= 0 then
			local ret, status = std.wait(pids[i])
			if status ~= 0 then
				return status, "pipeline failed: `" .. pipeline[i].cmd .. "`"
			end
		end
	end
	return 0
end

local sort_by_smaller_size = function(tbl)
	if tbl then
		table.sort(tbl, function(a, b)
			if std.utf.len(a) < std.utf.len(b) then
				return true
			elseif std.utf.len(a) == std.utf.len(b) then
				return tostring(a) < tostring(b)
			end
			return false
		end)
	end
	return tbl
end

return {
	dir_history_complete = dir_history_complete,
	zx_complete = zx_complete,
	parse_pipeline = parse_pipeline,
	parse_cmdline = parse_cmdline,
	run_pipeline = run_pipeline,
	sort_by_smaller_size = sort_by_smaller_size,
}
