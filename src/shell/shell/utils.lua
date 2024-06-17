-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local core = require("std.core")
local json = require("cjson.safe")
local storage = require("storage")
local text = require("text")
local term = require("term")
local theme = require("shell.theme")
local input = require("term.input")

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
	candidates = std.tbl.alphanumsort(candidates)
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
					return builtin.func(builtin.name, args)
				end
				if builtin.needy then
					builtin.extra = extra
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

local pager_next_render_mode = function(self)
	local modes = { "raw", "djot", "markdown" }
	local idx = 0
	for i, mode in ipairs(modes) do
		if mode == self.render_mode then
			idx = i + 1
			break
		end
	end
	if idx > #modes or idx == 0 then
		idx = 1
	end
	self:set_render_mode(modes[idx])
	self:display()
end

local pager_set_render_mode = function(self, mode)
	local mode = mode or self.__config.render_mode
	self.render_mode = mode
	local rss = theme.renderer.kat
	local conf = { global_indent = 0, wrap = self.__config.wrap, mode = mode, hide_links = self.__config.hide_links }
	if mode == "raw" then
		rss = {}
	end
	self.content.rendered = text.render(self.content.raw, rss, conf)
	self.content.lines = std.txt.lines(self.content.rendered)
end

local pager_display_line_nums = function(self)
	if not self.__config.line_nums then
		return
	end
	local total_lines = #self.content.lines
	local lines_to_display = total_lines - self.top_line + 1
	if lines_to_display > self.__window.capacity then
		lines_to_display = self.__window.capacity
	end
	for i = 1, lines_to_display do
		term.go(2 + i - 1, 1)
		term.write(term.color(246) .. self.top_line + i - 1 .. term.style("reset"))
	end
end

local pager_display = function(self)
	term.clear()
	local count = 0
	local indent = self.__config.indent + 1
	if self.__config.line_nums then
		indent = indent + 6
	end
	while count < self.__window.capacity do
		term.go(2 + count, indent)
		if self.content.lines[self.top_line + count] then
			term.write(self.content.lines[self.top_line + count])
		end
		count = count + 1
	end
	if self.__config.line_nums then
		self:display_line_nums()
	end
	if self.__config.status_line then
		self:display_status_line()
	end
end

local pager_display_status_line = function(self)
	local file = self.history[#self.history]
	local total_lines = #self.content.lines
	local kb_size = string.format("%.2f KB", #self.content.raw / 1024)
	local position_pct = ((self.top_line + self.__window.capacity) / total_lines) * 100
	if position_pct > 100 then
		position_pct = 100.00
	end
	local position = string.format("%.2f", position_pct) .. "%"
	local top_status = "File: "
		.. file
		.. ", Total lines: "
		.. total_lines
		.. ", Size: "
		.. kb_size
		.. ", at "
		.. position

	local bottom_status = self.mode
	local y, x = term.window_size()
	term.go(1, 1)
	term.clear_line()
	term.write(term.style("inverted") .. top_status .. term.style("reset"))
	term.go(y, 1)
	term.clear_line()
	term.write(term.style("inverted") .. bottom_status .. term.style("reset"))
end

local pager_load_content = function(self, filename)
	if filename then
		local content, err = std.fs.read_file(filename)
		if err then
			return nil, err
		end
		self.content = { raw = content }
		table.insert(self.history, filename)
		return true
	end
	return nil
end

local pager_exit = function(self)
	self.__config.status_line = false
	self:display()
	local position = #self.content.lines + 2
	if position > self.__window.y then
		position = self.__window.y
	end
	term.go(position, 1)
end

local pager_toggle_line_nums = function(self)
	self.__config.line_nums = not self.__config.line_nums
	self:display_line_nums()
end

local pager_toggle_status_line = function(self)
	self.__config.status_line = not self.__config.status_line
	self:display()
end

local pager_line_up = function(self)
	if self.top_line > 1 then
		self.top_line = self.top_line - 1
		self:display()
	end
end

local pager_line_down = function(self)
	if self.top_line + self.__window.capacity < #self.content.lines then
		self.top_line = self.top_line + 1
		self:display()
	end
end

local pager_page_up = function(self)
	self.top_line = self.top_line - self.__window.capacity
	if self.top_line < 1 then
		self.top_line = 1
	end
	self:display()
end

local pager_page_down = function(self)
	self.top_line = self.top_line + self.__window.capacity
	if self.top_line > #self.content.lines - self.__window.capacity then
		self.top_line = #self.content.lines - self.__window.capacity
	end
	self:display()
end

local pager_page = function(self)
	if #self.content.lines < self.__window.capacity and self.__config.exit_on_one_page then
		return self:exit()
	end
	repeat
		self:display()
		local cp = input.simple_get()
		if cp then
			if self.mode == "SCROLL" then
				if cp == "DOWN" or cp == " " or cp == "j" then
					self:line_down()
				end
				if cp == "UP" or cp == "k" then
					self:line_up()
				end
				if cp == "CTRL+r" then
					self:next_render_mode()
				end
				if cp == "q" then
					cp = "exit"
				end
				if cp == "l" then
					self:toggle_line_nums()
				end
				if cp == "s" then
					self:toggle_status_line()
				end
				if cp == "g" or cp == "HOME" then
					self.top_line = 1
					self:display()
				end
				if cp == "G" or cp == "END" then
					local position = 1
					if #self.content.lines > self.__window.capacity then
						position = #self.content.lines - self.__window.capacity
					end
					self.top_line = position
					self:display()
				end
				if cp == "CTRL+RIGHT" then
					self.__config.indent = self.__config.indent + 1
					self:display()
				end
				if cp == "ALT+RIGHT" then
					self.__config.wrap = self.__config.wrap + 5
					if self.__config.wrap > self.__window.x - 10 then
						self.__config.wrap = self.__window.x - 10
					end
					self:set_render_mode(self.render_mode)
					self:display()
				end
				if cp == "CTRL+LEFT" then
					if self.__config.indent > 0 then
						self.__config.indent = self.__config.indent - 1
						self:display()
					end
				end
				if cp == "ALT+LEFT" then
					self.__config.wrap = self.__config.wrap - 5
					if self.__config.wrap <= 40 then
						self.__config.wrap = 40
					end
					self:set_render_mode(self.render_mode)
					self:display()
				end
				if cp == "PAGE_UP" then
					self:page_up()
				end
				if cp == "PAGE_DOWN" then
					self:page_down()
				end
			end
		end
	until cp == "exit"
	self:exit()
end

local pager_new = function(config)
	local y, x = term.window_size()
	local wrap = 120
	if x < 130 then
		wrap = x - 10 -- reserved for line numbers
	end
	local default_config = {
		render_mode = "raw",
		exit_on_one_page = true,
		line_nums = false,
		status_line = false,
		indent = 0,
		wrap = wrap,
		hide_links = false,
	}
	std.tbl.merge(default_config, config)
	local pager = {
		__window = { x = x, y = y, capacity = y - 2 },
		__config = default_config,
		history = {},
		search_pattern = "",
		top_line = 1,
		cursor_line = 1,
		render_mode = render_mode,
		mode = "SCROLL",
		content = {},
		-- METHODS
		display = pager_display,
		display_line_nums = pager_display_line_nums,
		display_status_line = pager_display_status_line,
		load_content = pager_load_content,
		next_render_mode = pager_next_render_mode,
		set_render_mode = pager_set_render_mode,
		line_up = pager_line_up,
		line_down = pager_line_down,
		page_up = pager_page_up,
		page_down = pager_page_down,
		toggle_line_nums = pager_toggle_line_nums,
		toggle_status_line = pager_toggle_status_line,
		page = pager_page,
		exit = pager_exit,
	}
	return pager
end

return {
	zx_complete = zx_complete,
	parse_pipeline = parse_pipeline,
	parse_cmdline = parse_cmdline,
	run_pipeline = run_pipeline,
	pager = pager_new,
}
