-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local tinp = require("term.legacy_input")
local utils = require("shell.utils")
local history = require("shell.history")
local completions = require("shell.completions")
local theme = require("shell.theme")
local web = require("web")
local json = require("cjson.safe")
local tss_gen = require("term.tss")
local tss = tss_gen.new(theme)

local render = function(self, lf)
	if #self.lines > 0 then
		local lf = lf or "\n"
		return table.concat(self.lines, lf)
	else
		return self.buffer
	end
end

local display = function(self)
	local buf = self.buffer
	if #self.lines > 0 then
		buf = self.lines[1] .. "…"
	end
	if self.cursor == std.utf.len(buf) then
		return buf -- .. "\027[1E"
	end
	return buf .. "\027[" .. std.utf.len(buf) - self.cursor .. "D"
end

local flush = function(self)
	self.history:add(self:render())
	if self.completions then
		self.completions:flush()
	end
	self.buffer = ""
	self.lines = {}
	self.cursor = 0
	self.last_arg_len = 0
end

local up = function(self)
	if self.history:up() then
		if #self.buffer > 0 and self.history.position == #self.history.entries then
			self.history:stash(self.buffer)
		end
		self:clear_line()
		self.lines = {}
		local entry = self.history:get()
		if entry:match("\n") then
			self.lines = std.lines(entry)
			self.buffer = ""
		else
			self.buffer = entry
		end
		local out = self.buffer
		if #self.lines > 0 then
			out = self.lines[1] .. "…"
		end
		term.write(out)
		self.cursor = std.utf.len(out)
	end
	return false
end

local down = function(self)
	if self.history:down() then
		self:clear_line()
		self.lines = {}
		local entry = self.history:get()
		if entry:match("\n") then
			self.lines = std.lines(entry)
			self.buffer = ""
		else
			self.buffer = entry
		end
		local out = self.buffer
		if #self.lines > 0 then
			out = self.lines[1] .. "…"
		end
		term.write(out)
		self.cursor = std.utf.len(out)
	end
	return false
end

local last_arg = function(self)
	local arg = self.history:get_last_arg()
	if arg and #arg > 0 then
		local buf = self.buffer
		self:clear_line()
		self.buffer = buf .. arg
		term.write(self.buffer)
		self.cursor = std.utf.len(self.buffer)
		self.last_arg_len = std.utf.len(arg)
	end
	return false
end

local backspace = function(self)
	if #self.lines > 0 then
		return false
	end
	if self.cursor > 0 and std.utf.len(self.buffer) > 0 then
		if self.completions then
			self.completions:clear()
		end
		if self.cursor == std.utf.len(self.buffer) then
			self.buffer = std.utf.sub(self.buffer, 1, std.utf.len(self.buffer) - 1)
			term.write("\b \b")
			self.cursor = self.cursor - 1
		else
			self.buffer = std.utf.sub(self.buffer, 1, self.cursor - 1) .. std.utf.sub(self.buffer, self.cursor + 1)
			self.cursor = self.cursor - 1
			term.clear_line(0)
			term.write("\b \b")
			if self.cursor ~= 0 then
				term.write("\b \b")
			end
			term.write(std.utf.sub(self.buffer, self.cursor))
			term.move("left", std.utf.len(self.buffer) - self.cursor)
		end
	end
	return false
end

local delete = function(self)
	if #self.lines > 0 then
		return false
	end
	if #self.buffer > 0 and self.cursor < std.utf.len(self.buffer) then
		if self.completions then
			self.completions:clear()
		end
		if self.cursor > 0 then
			self.buffer = std.utf.sub(self.buffer, 1, self.cursor) .. std.utf.sub(self.buffer, self.cursor + 2)
			term.clear_line(0)
			term.write("\b \b")
			term.write(std.utf.sub(self.buffer, self.cursor))
			term.move("left", std.utf.len(self.buffer) - self.cursor)
		else -- cursor at 0 position, happens on empty buffer and Home event
			self.buffer = std.utf.sub(self.buffer, 2)
			term.clear_line(0)
			term.write(self.buffer)
			term.move("left", std.utf.len(self.buffer))
		end
	end
	return false
end

local scroll_completion_up = function(self)
	if self.completions then
		local index = self.completions:scroll_up()
		if index then
			self.completions:erase(index)
			term.write(tss:apply("modes.shell.completion", self.completions:get()))
		end
	else
		return "combo", "Alt+Up"
	end
end

local scroll_completion_down = function(self)
	if self.completions then
		local index = self.completions:scroll_down()
		if index then
			self.completions:erase(index)
			term.write(tss:apply("modes.shell.completion", self.completions:get()))
		end
	else
		return "combo", "Alt+Down"
	end
end

local add = function(self, key)
	if #self.lines > 0 then
		return nil
	end
	if #key == 1 or std.utf.valid_seq(key) then
		local length = std.utf.len(self.buffer)
		if length == self.cursor then
			self.buffer = self.buffer .. key
			self.cursor = self.cursor + 1
			if self.completions then
				self.completions:clear()
				local buf = self:render()
				if self.mode == "shell" then
					-- Our history and directory jumpers
					-- need history entries for completions,
					-- and completion object does not have access to them,
					-- so we explicitly provide them
					if buf:match("^[xz] ") then
						if buf:match("^x ") then
							self.completions.source:provide(self.history:completions(buf))
						else
							self.completions.source:provide(self.history:dir_completions(buf))
						end
					end
				end
				if key ~= " " and self.completions:complete(buf) then
					term.write(key .. tss:apply("modes.shell.completion", self.completions:get()))
				else
					term.write(key)
				end
			else
				term.write(key)
			end
		else
			if self.cursor == 0 then
				self.buffer = key .. self.buffer
				term.clear_line(0)
				self.cursor = 1
				term.write(self.buffer)
				term.move("left", std.utf.len(self.buffer) - self.cursor)
			else
				self.buffer = std.utf.sub(self.buffer, 1, self.cursor)
					.. key
					.. std.utf.sub(self.buffer, self.cursor + 1)
				self.cursor = self.cursor + 1
				term.clear_line(0)
				term.write(std.utf.sub(self.buffer, self.cursor))
				term.move("left", std.utf.len(self.buffer) - self.cursor)
			end
		end
		return nil
	end
	return "combo", key
end

local execute = function(self)
	if self.completions then
		self.completions:clear()
	end
	return "execute"
end

local move_back_till_space = function(self)
	if #self.lines > 0 then
		return nil
	end
	if self.cursor > 1 and self.buffer ~= "" then
		local cur_pos = self.cursor
		local cur_buf = self.buffer:sub(1, cur_pos)
		local space = cur_buf:find("%s%S+%s-$") or 0
		space = space - 1
		if space ~= cur_pos and space >= 1 then
			term.move("left", self.cursor - space)
			self.cursor = space
		end
	end
	return nil
end

local move_forward_till_space = function(self)
	if #self.lines > 0 then
		return nil
	end
	if self.cursor < #self.buffer and self.buffer ~= "" then
		local cur_pos = self.cursor
		local cur_buf = self.buffer:sub(cur_pos)
		local _, space = cur_buf:find("^%s-%S+%s")
		local space = space or 0
		space = space - 1
		if space > 0 and cur_pos + space <= #self.buffer then
			term.move("right", space)
			self.cursor = self.cursor + space
		end
	end
	return nil
end

local start_of_line = function(self)
	if #self.lines > 0 then
		return nil
	end
	if self.cursor > 1 then
		if self.completions then
			self.completions:clear()
		end
		term.move("left", self.cursor)
		self.cursor = 0
	end
	return nil
end

local end_of_line = function(self)
	if #self.lines > 0 then
		return nil
	end
	if self.cursor < std.utf.len(self.buffer) then
		if self.completions then
			self.completions:clear()
		end
		term.move("right", std.utf.len(self.buffer) - self.cursor)
		self.cursor = std.utf.len(self.buffer)
	end
	return nil
end

local left = function(self)
	if #self.lines > 0 then
		return nil
	end
	if self.cursor > 0 then
		if self.completions then
			self.completions:clear()
		end
		self.cursor = self.cursor - 1
		term.move("left")
	end
	return nil
end

local right = function(self)
	if #self.lines > 0 then
		return nil
	end
	if self.cursor < std.utf.len(self.buffer) then
		if self.completions then
			self.completions:clear()
		end
		self.cursor = self.cursor + 1
		term.move("right")
	else
		self["Alt+Down"](self)
	end
	return nil
end

local multiline_edit = function(self)
	term.write("…")
	local editor = os.getenv("EDITOR") or "vi"
	local stdin = std.pipe()
	local stdout = std.pipe()
	stdin:write(self:render())
	stdin:close_inn()
	local pid = std.launch(editor, stdin.out, stdout.inn, nil, "-")
	local _, status = std.wait(pid)
	stdin:close_out()
	stdout:close_inn()
	local result = stdout:read() or "can't get editor output"
	stdout:close_out()
	self.lines = std.lines(result)
	term.move("column")
	return "execute"
end

local transcribe_audio = function(self)
	local whisper_url = os.getenv("LILUSH_WHISPER_URL")
	local tmp_dir = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
	local timeout = os.getenv("WHISPER_API_TIMEOUT") or os.getenv("LLM_API_TIMEOUT") or 300 -- 5 minutes
	if not whisper_url then
		return nil
	end
	local stderr = std.pipe()
	local pid, err = std.launch(
		"arecord",
		nil,
		nil,
		stderr.inn,
		"-f",
		"S16_LE",
		"-d",
		"10",
		"-r",
		"16000",
		tmp_dir .. "/last_audio.wav"
	)
	if err then
		return nil
	end
	term.write("")
	while true do
		local key = tinp.get()
		if key then
			std.kill(pid, 2)
			std.wait(pid)
			break
		end
	end
	term.write("\b")
	local progress = std.progress_icon()
	local form_data = {
		{ name = "response-format", content = "json", mime = "text/plain" },
		{ name = "file", path = tmp_dir .. "/last_audio.wav", mime = "application/octet-stream" },
	}
	local content_header, data = web.make_form_data(form_data)
	local options = {
		method = "POST",
		headers = { ["Content-Type"] = content_header },
		body = data,
	}
	local res, err = web.request(whisper_url .. "/inference", options, timeout)
	progress.stop()
	if err or res.status ~= 200 then
		std.print(err)
		std.print(res)
		term.write("\b \b")
		return nil
	end
	local body = json.decode(res.body)
	local text = body.text:gsub("^[\n%s]+", "")
	text = text:gsub("[\n%s]+$", "")
	self.buffer = self.buffer .. text
	self.cursor = self.cursor + std.utf.len(text)
	term.write("\b \b" .. text)
	return nil
end

local clear_line = function(self)
	if #self.buffer > 0 or #self.lines > 0 then
		if self.completions then
			self.completions:clear()
		end
		-- term.clear_line(0) -- clear till the EOL
		for i = 1, self.cursor do -- clear till the prompt
			term.write("\b \b")
		end
		self.buffer = ""
		self.cursor = 0
	end
	return nil
end

local promote_completion = function(self)
	if self.completions then
		if self.completions:available() then
			local promoted
			local exec_on_promotion = self.completions.source.variants.exec_on_promotion

			local _, args = utils.parse_cmdline(self.buffer)
			local last_arg = args[#args] or ""
			local full_completion = last_arg .. self.completions:get()
			local last_char = ""
			if full_completion:match(" $") then
				last_char = " "
				full_completion = full_completion:sub(1, -2)
			end
			if full_completion:match("%s") then
				full_completion = '"' .. full_completion .. '"' .. last_char
			end
			-- probably better wrap it into a function on a higher level
			if self.completions.source.variants.replace_args ~= nil then
				promoted = self.completions.source.variants.replace_args .. self.completions:get()
			else
				if full_completion:match('^"') then
					local remove_till = std.utf.len(self.buffer) - std.utf.len(last_arg)
					promoted = std.utf.sub(self.buffer, 1, remove_till) .. full_completion
				else
					promoted = self.buffer .. self.completions:get()
				end
			end
			self:clear_line()
			self.buffer = promoted:gsub("^(%s+)", "") -- trim leading spaces
			self.cursor = std.utf.len(self.buffer)
			term.write(self.buffer)
			if exec_on_promotion then
				return "execute"
			end
		end
	end
	return nil
end

local event = function(self)
	local key = tinp.get()
	if key then
		if self[key] then
			return self[key](self)
		end
		return self:add(key)
	end
	return nil
end

local new = function(mode, source, store)
	local input = {
		lines = {},
		buffer = "",
		cursor = 0,
		last_arg_len = 0,
		mode = mode,
		["Alt+Enter"] = multiline_edit,
		["Ctrl+C"] = clear_line,
		["Home"] = start_of_line,
		["Ctrl+A"] = start_of_line,
		["End"] = end_of_line,
		["Ctrl+E"] = end_of_line,
		["Left"] = left,
		["Ctrl+Left"] = move_back_till_space,
		["Ctrl+Right"] = move_forward_till_space,
		["Right"] = right,
		["Up"] = up,
		["Down"] = down,
		["Alt+."] = last_arg,
		["Alt+Shift+A"] = transcribe_audio,
		["Alt+Down"] = scroll_completion_down,
		["Alt+S"] = scroll_completion_down,
		["Alt+Up"] = scroll_completion_up,
		["Alt+W"] = scroll_completion_up,
		["Tab"] = promote_completion,
		["Backspace"] = backspace,
		["Del"] = delete,
		["Enter"] = execute,
		add = add,
		render = render,
		display = display,
		flush = flush,
		clear_line = clear_line,
		event = event,
	}
	if mode ~= "mini" then
		input.history = history.new(mode, store)
	end
	if source then
		input.completions = completions.new(source)
	end
	return input
end

return { new = new }
