-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local core = require("std.core")

local replace_envs_and_home = function(arg)
	local env = std.environ()
	if not env.HOME then
		env.HOME = "/tmp"
	end
	local arg = arg:gsub("%${([^}]+)}", env)
	arg = arg:gsub("^(~)", env.HOME)
	return arg
end

local parse_pipeline, run_pipeline

local parse_cmdline = function(input, with_inlines)
	local with_inlines = with_inlines or false
	local substitutes = {}
	if with_inlines then
		local ppls = std.txt.find_all_positions(input, "%$%b()")
		for i, ppl in ipairs(ppls) do
			local pipeline_raw = input:sub(ppl[1] + 2, ppl[2] - 1)
			local pipeline = parse_pipeline(pipeline_raw)
			local sub = ""
			if pipeline then
				local out_pipe = std.ps.pipe()
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

	local singles = std.txt.find_all_positions(input, "%b''")
	local doubles = std.txt.find_all_positions(input, '%b""')
	local curlies = std.txt.find_all_positions(input, "{{.-}}")

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
				w = replace_envs_and_home(w)
				-- Restore spaces from Unicode replacement character
				w = w:gsub("␣", " ")
				table.insert(args, w)
			end
			local width = 1
			if v.t == "curlies" then
				width = 2
			end
			local complex_arg = input:sub(v.p[1] + width, v.p[2] - width)
			if v.t ~= "singles" then
				complex_arg = replace_envs_and_home(complex_arg)
			end
			-- Restore spaces from Unicode replacement character
			complex_arg = complex_arg:gsub("␣", " ")
			table.insert(args, complex_arg)
		end
		local after = input:sub(sorted[#sorted].p[2] + 1)
		for w in after:gmatch("([^ ]+)") do
			w = replace_envs_and_home(w)
			-- Restore spaces from Unicode replacement character
			w = w:gsub("␣", " ")
			table.insert(args, w)
		end
	else
		for w in input:gmatch("([^ ]+)") do
			w = replace_envs_and_home(w)
			-- Restore spaces from Unicode replacement character
			w = w:gsub("␣", " ")
			table.insert(args, w)
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
	-- First we split the line by pipes (i.e. `|` symbol), but
	-- we must ignore pipes inside quoted strings
	local state = { last_idx = 1, count = 0, inside_quotes = false, quote_type = "", curlies = 0 }
	for char in input:gmatch(".") do
		state.count = state.count + 1
		if char == "{" then
			if not state.inside_quotes then
				if state.curlies == 0 then
					state.curlies = 1
				elseif state.curlies == 1 then
					state.inside_quotes = true
					state.curlies = 0
					state.quote_type = "curlies"
				end
			end
		elseif char == "}" and state.inside_quotes and state.quote_type == "curlies" then
			if state.curlies == 1 then
				state.inside_quotes = false
				state.curlies = 0
				state.quote_type = ""
			else
				state.curlies = 1
			end
		else
			state.curlies = 0
		end
		if char:match("['\"]") then
			if state.inside_quotes then
				if state.quote_type == char then
					state.inside_quotes = false
					state.quote_type = ""
				end
			else
				state.quote_type = char
				state.inside_quotes = true
			end
		end
		if char == "|" and not state.inside_quotes then
			local line = input:sub(state.last_idx, state.count - 1)
			line = line:gsub("^(%s+)", ""):gsub("(%s+)$", "") -- tream leading & trailing spaces
			table.insert(cmdlines, line)
			state.last_idx = state.count + 1
		end
	end
	if state.last_idx == 1 then -- there were no pipes in the pipeline
		cmdlines = { input }
	elseif state.last_idx > 1 and state.last_idx < #input then
		local line = input:sub(state.last_idx)
		line = line:gsub("^(%s+)", ""):gsub("(%s+)$", "")
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

		for _, line in ipairs(cmdlines) do
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
		pipes[i] = std.ps.pipe()
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
					if builtin.needy then
						return builtin.func(builtin.name, args, extra)
					end
					return builtin.func(builtin.name, args)
				end
				cmd = builtin
			end
		end
		pids[i] = std.ps.launch(cmd, stdin, stdout, nil, unpack(args))
		if stdin then
			core.close(stdin)
		end
		if stdout then
			core.close(stdout)
		end
	end
	for i, pid in ipairs(pids) do
		if pid ~= 0 then
			local ret, status = std.ps.wait(pids[i])
			if status ~= 0 then
				return status, "pipeline failed: `" .. pipeline[i].cmd .. "`"
			end
		end
	end
	return 0
end

return {
	parse = parse_pipeline,
	parse_cmdline = parse_cmdline,
	run = run_pipeline,
}
