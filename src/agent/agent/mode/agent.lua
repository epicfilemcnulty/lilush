-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Agent mode for Lilush shell.

Provides an agentic coding assistant with:
- Streaming LLM responses with formatting
- Tool execution with configurable approval
- Conversation management
- Support for multiple LLM providers
]]

local std = require("std")
local term = require("term")
local json = require("cjson.safe")
local llm = require("llm")
local style = require("term.tss")
local theme = require("theme").get("agent")
local pager_mod = require("shell.utils.pager")

local config_mod = require("agent.config")
local conversation_mod = require("agent.conversation")
local conversation_md_mod = require("agent.conversation_markdown")
local edit_diff_preview_mod = require("agent.edit_diff_preview")
local index_context_mod = require("agent.index_context")
local system_prompt_mod = require("agent.system_prompt")
local stream_mod = require("agent.stream")
local llm_tools = require("llm.tools")

-- Create TSS instance for styled output
local tss = style.new(theme)

-- Output helpers
local function write_line(text)
	term.write(text .. "\n")
end

local function write_error(text)
	term.write(tss:apply("agent.error", text).text .. "\n")
end

local function write_info(text)
	term.write(tss:apply("agent.info", text).text .. "\n")
end

local function format_model_price_per_million(price_per_token)
	local n = tonumber(price_per_token)
	if not n then
		return "?"
	end
	return conversation_mod.format_cost(n * 1000000)
end

local function model_price_label(model_info)
	if not model_info then
		return "unpriced"
	end

	local input_price = tonumber(model_info.prompt_price)
	local output_price = tonumber(model_info.completion_price)
	if input_price == nil and output_price == nil then
		return "unpriced"
	end

	return "in="
		.. format_model_price_per_million(input_price)
		.. "/1M out="
		.. format_model_price_per_million(output_price)
		.. "/1M"
end

local function show_pager(lines, render_mode)
	lines = lines or {}
	render_mode = render_mode or "raw"
	local content = table.concat(lines, "\n")

	term.set_raw_mode()
	term.hide_cursor()

	local ok, err = pcall(function()
		local pager = pager_mod.new({
			exit_on_one_page = false,
			render_mode = render_mode,
			status_line = true,
			line_nums = false,
			write_back = false,
		})
		pager:set_content(content)
		pager:set_render_mode(render_mode)
		pager:page()
	end)

	term.show_cursor()
	term.set_sane_mode()

	if not ok then
		return nil, err
	end

	return true
end

local function show_pager_or_error(lines, render_mode)
	local ok, err = show_pager(lines, render_mode)
	if not ok then
		write_error("Error: failed to open pager: " .. tostring(err))
		return 1
	end
	return 0
end

local function count_output_lines(text)
	if type(text) ~= "string" or text == "" then
		return 1
	end
	local lines = 1
	for _ in text:gmatch("\n") do
		lines = lines + 1
	end
	return lines
end

local function clear_previous_tool_output(lines)
	lines = tonumber(lines) or 0
	if lines <= 0 then
		return
	end

	term.move("up", lines)
	term.move("column", 1)
	for i = 1, lines do
		term.clear_line(2)
		if i < lines then
			term.move("down", 1)
			term.move("column", 1)
		end
	end

	if lines > 1 then
		term.move("up", lines - 1)
	end
	term.move("column", 1)
end

local function show_thinking_indicator()
	term.write(tss:apply("agent.thinking", "thinking ").text)
	local spinner = std.progress_icon()
	return { active = true, spinner = spinner }
end

local function clear_thinking_indicator(indicator)
	indicator.spinner.stop()
	term.move("column", 1)
	term.clear_line(2)
	indicator.active = false
end

local function write_tool(name, detail)
	local tool_name = tostring(name or "unknown")
	local detail_text = nil
	if detail ~= nil and detail ~= "" then
		detail_text = tostring(detail)
	end

	term.write(tss:apply("agent.tool.bracket", "[").text)
	term.write(tss:apply("agent.tool.name", tool_name).text)
	term.write(tss:apply("agent.tool.bracket", "]").text)
	if detail_text then
		term.write(" " .. tss:apply("agent.tool.args", detail_text).text)
	end
	term.write("\n")

	local line_text = "[" .. tool_name .. "]"
	if detail_text then
		line_text = line_text .. " " .. detail_text
	end
	return count_output_lines(line_text)
end

local function tool_call_detail(name, args)
	if type(args) ~= "table" then
		return nil
	end
	if name == "bash" then
		return args.command
	elseif name == "read" then
		return args.filepath
	elseif name == "write" then
		return args.filepath
	elseif name == "edit" then
		return args.filepath
	elseif name == "fetch_webpage" then
		return args.url
	elseif name == "web_search" then
		return args.query
	end
	return nil
end

local function write_tool_result(result_summary)
	local summary = tostring(result_summary or "")
	term.write(tss:apply("agent.tool.result_prefix").text)
	term.write(tss:apply("agent.tool.result", summary).text .. "\n")
	return count_output_lines(summary)
end

local function write_tool_warning(message)
	term.write(tss:apply("agent.tool.warning", message).text .. "\n")
	return count_output_lines(message)
end

local function write_tool_diff_line(style_path, text)
	term.write(tss:apply(style_path, text).text .. "\n")
	return count_output_lines(text)
end

local function write_edit_diff_preview(preview)
	if type(preview) ~= "table" then
		return 0
	end

	local lines_written = 0
	local stats = preview.stats or {}
	if preview.truncated then
		local limits = edit_diff_preview_mod.defaults or {}
		local summary = "Diff too large for inline preview ("
			.. tostring(stats.changed_lines or 0)
			.. " changed lines, "
			.. tostring(stats.full_bytes or 0)
			.. " bytes; limits: "
			.. tostring(limits.max_inline_lines or "?")
			.. " lines, "
			.. tostring(limits.max_inline_bytes or "?")
			.. " bytes)."
		lines_written = lines_written + write_tool_diff_line("agent.tool.diff.meta", summary)
		lines_written = lines_written
			+ write_tool_diff_line("agent.tool.diff.hint", "Press 'p' to open full diff in pager.")
		return lines_written
	end

	for _, line in ipairs(preview.inline_lines or {}) do
		local style_path = "agent.tool.diff.meta"
		if line:sub(1, 2) == "@@" then
			style_path = "agent.tool.diff.header"
		elseif line:sub(1, 1) == "+" then
			style_path = "agent.tool.diff.add"
		elseif line:sub(1, 1) == "-" then
			style_path = "agent.tool.diff.remove"
		end
		lines_written = lines_written + write_tool_diff_line(style_path, line)
	end

	return lines_written
end

local REQUIRED_TOOL_ARGUMENTS = {
	bash = { "command" },
	read = { "filepath" },
	write = { "filepath", "content" },
	edit = { "filepath", "old_text", "new_text" },
	fetch_webpage = { "url" },
	web_search = { "query" },
}

local function is_json_object(value)
	if type(value) ~= "table" then
		return false
	end
	for key, _ in pairs(value) do
		if type(key) == "number" then
			return false
		end
	end
	return true
end

local function validate_tool_arguments(tool_name, arguments)
	if not is_json_object(arguments) then
		return "arguments must be a JSON object"
	end
	for _, required_key in ipairs(REQUIRED_TOOL_ARGUMENTS[tool_name] or {}) do
		if arguments[required_key] == nil then
			return "missing required field: " .. tostring(required_key)
		end
	end
	return nil
end

local function edit_tool_arguments_external(tool_name, arguments)
	local encoded = json.encode(arguments or {})
	if not encoded then
		return nil, "failed to encode arguments as JSON"
	end

	local tmpfile = "/tmp/agent_tool_args_" .. std.nanoid() .. ".json"
	local ok, err = std.fs.write_file(tmpfile, encoded .. "\n")
	if not ok then
		return nil, "failed to write temp file: " .. tostring(err)
	end

	local cleanup_tmpfile = function()
		std.fs.remove(tmpfile)
	end

	local editor = os.getenv("EDITOR") or "vi"
	local pid, launch_err = std.ps.launch(editor, nil, nil, nil, tmpfile)
	if not pid then
		cleanup_tmpfile()
		return nil, "failed to launch editor: " .. tostring(launch_err)
	end

	local _, status = std.ps.wait(pid)
	if status ~= 0 then
		cleanup_tmpfile()
		return nil, "editor exited with status " .. tostring(status)
	end

	local edited_content, read_err = std.fs.read_file(tmpfile)
	cleanup_tmpfile()
	if not edited_content then
		return nil, "failed to read edited content: " .. tostring(read_err)
	end

	local edited_arguments, decode_err = json.decode(edited_content)
	if edited_arguments == nil then
		return nil, "invalid JSON: " .. tostring(decode_err or "decode failed")
	end

	local validation_err = validate_tool_arguments(tool_name, edited_arguments)
	if validation_err then
		return nil, validation_err
	end

	return edited_arguments
end

-- Ask for tool approval
-- Returns: decision, lines_written
-- Decision is one of: "yes", "always", "abort", { abort_message = "..." }, or { edit_args = {...} }
local function ask_approval(tool_name, args, preview_ctx)
	local lines_written = 0

	while true do
		term.write(tss:apply("agent.approval.bracket", "[").text)
		term.write(tss:apply("agent.approval.name", tool_name).text)
		term.write(tss:apply("agent.approval.bracket", "]").text)
		term.write(tss:apply("agent.approval.options", " Execute? [Y/n/p/e/m/a] ").text)
		io.flush()

		-- Read full line in sane mode (consumes the newline from Enter)
		-- User types their choice and presses Enter
		local line = io.read("*l")
		local key = line and line:sub(1, 1) or ""
		lines_written = lines_written + 1
		key = key:lower()

		if key == "n" then
			return "abort", lines_written
		elseif key == "p" then
			local full_lines = type(preview_ctx) == "table" and preview_ctx.full_lines or nil
			if type(full_lines) == "table" and #full_lines > 0 then
				local ok, err = show_pager(full_lines, "raw")
				if not ok then
					write_error("Error: failed to open pager: " .. tostring(err))
					lines_written = lines_written + 1
				end
			else
				write_info("No diff preview available for this tool call.")
				lines_written = lines_written + 1
			end
		elseif key == "e" then
			local edited_args, edit_err = edit_tool_arguments_external(tool_name, args)
			if not edited_args then
				return { abort_message = "Tool call edit failed: " .. tostring(edit_err) }, lines_written
			end
			return { edit_args = edited_args }, lines_written
		elseif key == "m" then
			-- Abort with message - prompt for feedback
			term.write(tss:apply("agent.approval.options", "Message: ").text)
			io.flush()
			local msg = io.read("*l")
			lines_written = lines_written + 1
			if msg and msg ~= "" then
				return { abort_message = msg }, lines_written
			end
			return "abort", lines_written
		elseif key == "a" then
			return "always", lines_written
		else
			return "yes", lines_written
		end
	end
end

-- Slash command handlers
local slash_commands = {}

local list_slash_command_names = function()
	local names = {}
	for name, _ in pairs(slash_commands) do
		names[#names + 1] = name
	end
	table.sort(names, function(a, b)
		if #a == #b then
			return a < b
		end
		return #a < #b
	end)
	return names
end

local show_conversation_pager = function(self)
	local messages = self.__state.conversation:get_raw_messages()
	local markdown = conversation_md_mod.build(messages, {
		tool_summary_max = 240,
	})
	return show_pager_or_error({ markdown }, "markdown")
end

local show_conversation_combo = function(self)
	local status = show_conversation_pager(self)
	return status == 0
end

local function resolve_index_context(self, index_file)
	if type(index_file) ~= "string" or index_file == "" then
		return nil
	end
	local resolved = index_context_mod.resolve({
		index_file = index_file,
		cache = self.__state.index_ctx_cache or {},
	})
	self.__state.index_ctx_cache = resolved.cache or self.__state.index_ctx_cache
	return resolved
end

local function format_index_check_line(check)
	local source = check.source == "repo_root" and "repo root" or "cwd"
	if check.status == "loaded" then
		return "  - " .. check.path .. " [" .. source .. "]: loaded"
	end
	if check.status == "duplicate_skipped" then
		return "  - " .. check.path .. " [" .. source .. "]: duplicate (already included)"
	end
	if check.status == "empty" then
		return "  - " .. check.path .. " [" .. source .. "]: empty (ignored)"
	end
	return "  - " .. check.path .. " [" .. source .. "]: not found"
end

local trim = std.txt.trim

local parse_conversation_name_arg = function(args)
	if type(args) ~= "table" or #args == 0 then
		return nil
	end

	local name = trim(table.concat(args, " "))
	if not name then
		return nil
	end

	local first_char = name:sub(1, 1)
	local last_char = name:sub(-1)
	if #name >= 2 and ((first_char == '"' and last_char == '"') or (first_char == "'" and last_char == "'")) then
		name = trim(name:sub(2, -2))
	end

	return name
end

local reset_context_usage_tracking = function(usage)
	if type(usage) ~= "table" then
		return
	end
	usage.last_ctx_tokens = 0
	usage.last_ctx_pct = 0
	usage.peak_ctx_tokens = 0
	usage.peak_ctx_pct = 0
	usage.context_window = 0
end

-- Shared handler for /prompt and /sysprompt subcommands (list, set, clear, show).
-- opts fields: label, dir_hint, usage, get_active, set_active, list_fn, load_fn, clear_msg, set_msg
local function slash_prompt_handler(self, sub, args, opts)
	if sub == "list" then
		local prompts = opts.list_fn()
		if #prompts == 0 then
			write_info("No " .. opts.label .. "s found in " .. opts.dir_hint)
		else
			local lines = { opts.label:sub(1, 1):upper() .. opts.label:sub(2) .. "s:" }
			local active = opts.get_active()
			for _, name in ipairs(prompts) do
				local marker = (name == active) and " *" or ""
				lines[#lines + 1] = "  " .. name .. marker
			end
			return show_pager_or_error(lines)
		end
		return 0
	end

	if sub == "set" then
		local name = args[2]
		if not name then
			write_error(opts.usage)
			return 1
		end
		local content = opts.load_fn(name)
		if not content then
			write_error(opts.label:sub(1, 1):upper() .. opts.label:sub(2) .. " file not found: " .. name)
			write_info("Use " .. opts.usage:match("^Usage: (%S+)") .. " list to see available " .. opts.label .. "s.")
			return 1
		end
		opts.set_active(name)
		self:update_prompt()
		write_info(opts.set_msg .. name)
		return 0
	end

	if sub == "clear" then
		opts.set_active(nil)
		self:update_prompt()
		write_info(opts.clear_msg)
		return 0
	end

	if sub == "show" then
		local full_prompt = self:build_system_prompt()
		local lines = {}
		for line in full_prompt:gmatch("([^\n]*)\n?") do
			lines[#lines + 1] = line
		end
		return show_pager_or_error(lines)
	end

	write_error("Unknown subcommand: " .. sub)
	write_info(opts.usage)
	return 1
end

slash_commands["/help"] = function(self, args)
	return show_pager_or_error({
		"Available commands:",
		"  /help              - Show this help",
		"  /clear             - Clear conversation history",
		"  /model [name]      - Show or set current model",
		"  /provider [name]   - Show or set current provider",
		"  /provider refresh [name] - Refresh discovered model catalog",
		"  /models            - List current provider models",
		"  /tools             - List available tools",
		"  /tokens            - Show token usage",
		"  /cost              - Show session cost breakdown",
		"  /save [name]       - Save conversation to file",
		"  /load [name]       - Load conversation from file",
		"  /list              - List saved conversations",
		"  /conversation      - Show current conversation in markdown pager",
		"  /prompt             - Show active user prompt + index context status",
		"  /prompt list        - List available user prompts",
		"  /prompt set <name>  - Activate a user prompt",
		"  /prompt clear       - Deactivate user prompt",
		"  /prompt show        - Show full assembled system prompt",
		"  /sysprompt          - Show active system prompt info",
		"  /sysprompt list     - List available custom system prompts",
		"  /sysprompt set <n>  - Activate a custom system prompt",
		"  /sysprompt clear    - Revert to default system prompt",
		"  /sysprompt show     - Show full assembled system prompt",
		"  /config            - Show current configuration",
		"",
		"Keybinds:",
		"  ALT+h   - Show current conversation in markdown pager",
		"",
		"Tool approval options:",
		"  Y/Enter - Execute the tool",
		"  n       - Deny and stop (wait for next input)",
		"  p       - Show edit diff preview in pager",
		"  e       - Edit arguments in $EDITOR and execute",
		"  m       - Deny with message (provide feedback)",
		"  a       - Allow all (auto-approve this tool for session)",
	})
end

slash_commands["/conversation"] = function(self, args)
	return show_conversation_pager(self)
end

slash_commands["/clear"] = function(self, args)
	local system_prompt = self:build_system_prompt()
	self.__state.conversation = conversation_mod.new(system_prompt)
	self.__state.config:clear_session_approvals()
	-- Reset only per-conversation context tracking; preserve cumulative cost
	reset_context_usage_tracking(self.__state.session_usage)
	self:update_prompt()
	write_info("Conversation cleared.")
	return 0
end

slash_commands["/model"] = function(self, args)
	if args and #args > 0 then
		local model_name = args[1]
		local provider_name = args[2] -- Optional
		local ok, err = self.__state.config:set_model(model_name, provider_name)
		if not ok then
			write_error("Error: " .. err)
			return 1
		end
		local init_ok, init_err = self:init_client()
		if not init_ok then
			write_error("Error: " .. tostring(init_err))
			return 1
		end
		self:update_prompt()
		write_info("Model set to: " .. self.__state.config:get_model())
	else
		write_line("Current model: " .. (self.__state.config:get_model() or "not set"))
		write_line("Current provider: " .. (self.__state.config:get_provider() or "not set"))
	end
	return 0
end

slash_commands["/provider"] = function(self, args)
	if args and #args > 0 and args[1] == "refresh" then
		local provider_name = args[2] or self.__state.config:get_provider()
		local discovered, err = self.__state.config:refresh_provider_models(provider_name)
		if not discovered then
			write_error("Error: " .. err)
			return 1
		end
		if provider_name == self.__state.config:get_provider() then
			local _, resolve_err =
				self.__state.config:resolve_model(self.__state.config:get_model(), self.__state.config:get_provider())
			if resolve_err then
				write_error("Error: " .. tostring(resolve_err))
				return 1
			end
			local init_ok, init_err = self:init_client()
			if not init_ok then
				write_error("Error: " .. tostring(init_err))
				return 1
			end
			self:update_prompt()
		end
		write_info("Provider catalog refreshed: " .. tostring(provider_name))
		return 0
	end

	if args and #args > 0 then
		local provider_name = args[1]
		local ok, err = self.__state.config:set_provider(provider_name)
		if not ok then
			write_error("Error: " .. err)
			return 1
		end
		local init_ok, init_err = self:init_client()
		if not init_ok then
			write_error("Error: " .. tostring(init_err))
			return 1
		end
		self:update_prompt()
		write_info("Provider set to: " .. provider_name .. ", model: " .. self.__state.config:get_model())
	else
		write_line("Current provider: " .. (self.__state.config:get_provider() or "not set"))
		write_line("Available providers: " .. table.concat(self.__state.config:list_providers(), ", "))
	end
	return 0
end

slash_commands["/models"] = function(self, args)
	local provider_name = self.__state.config:get_provider()
	local pc = self.__state.config:get_provider_config(provider_name)
	local lines = {
		"Current provider:",
		"  "
			.. tostring(provider_name or "not set")
			.. " (kind: "
			.. tostring(pc and pc.kind or "?")
			.. ", default model: "
			.. tostring(pc and pc.default_model or "?")
			.. ")",
	}

	local models, models_err = self.__state.config:list_models_detailed(provider_name)
	if models_err then
		lines[#lines + 1] = "    unavailable: " .. tostring(models_err)
	elseif #models == 0 then
		lines[#lines + 1] = "    (no discovered models)"
	else
		for _, model in ipairs(models) do
			local loaded = model.loaded and " [loaded]" or ""
			lines[#lines + 1] = "    "
				.. model.name
				.. loaded
				.. " (ctx: "
				.. tostring(model.context_window or "?")
				.. ", "
				.. model_price_label(model)
				.. ")"
		end
	end
	return show_pager_or_error(lines)
end

slash_commands["/tools"] = function(self, args)
	local lines = { "Available tools:" }
	local tool_names = self:list_tools()
	local desc_by_name = {}

	for _, desc in ipairs(self:get_tool_descriptions(tool_names) or {}) do
		local fn = desc and desc["function"]
		local name = fn and fn.name
		if type(name) == "string" and name ~= "" then
			desc_by_name[name] = fn.description
		end
	end

	for _, name in ipairs(tool_names) do
		local tool_config = self.__state.config:get_tool_config(name)
		local approval = tool_config.approval or "auto"
		lines[#lines + 1] = "  " .. name .. " [" .. approval .. "]"
		local description = desc_by_name[name]
		if type(description) == "string" and description ~= "" then
			lines[#lines + 1] = "    " .. description
		end
	end
	return show_pager_or_error(lines)
end

slash_commands["/tokens"] = function(self, args)
	local usage = self.__state.session_usage or {}
	local session_tokens = (usage.input_tokens or 0) + (usage.output_tokens or 0)
	local context_window = (self.__state.model_info and self.__state.model_info.context_window)
		or usage.context_window
		or 0
	local last_ctx = usage.last_ctx_tokens or 0
	local pct = usage.last_ctx_pct or 0
	if context_window == 0 and last_ctx > 0 then
		context_window = last_ctx
	end

	local lines = {
		"Token usage:",
		"  Session total: " .. tostring(session_tokens),
		"  Last context:  " .. tostring(last_ctx) .. " / " .. tostring(context_window) .. " (" .. tostring(pct) .. "%)",
		"  Peak context:  "
			.. tostring(usage.peak_ctx_tokens or 0)
			.. " ("
			.. tostring(usage.peak_ctx_pct or 0)
			.. "%)",
		"  Messages:      " .. tostring(self.__state.conversation:count()),
	}

	return show_pager_or_error(lines)
end

slash_commands["/save"] = function(self, args)
	local name = parse_conversation_name_arg(args)
	local filepath, err = self.__state.conversation:save(name)
	if not filepath then
		if not name and tostring(err) == "conversation name required" then
			write_error("Usage: /save <name>")
			return 1
		end
		write_error("Error: " .. err)
		return 1
	end
	write_info("Conversation saved to: " .. filepath)
	return 0
end

slash_commands["/load"] = function(self, args)
	local name = parse_conversation_name_arg(args)
	if not name then
		return slash_commands["/list"](self, nil)
	end
	local ok, err = self.__state.conversation:load(name)
	if not ok then
		write_error("Error: " .. err)
		return 1
	end
	reset_context_usage_tracking(self.__state.session_usage)
	self:update_prompt()
	local loaded_name = self.__state.conversation:get_name() or name
	write_info("Loaded conversation: " .. loaded_name .. " (" .. self.__state.conversation:count() .. " messages)")
	return 0
end

slash_commands["/list"] = function(self, args)
	local convos = conversation_mod.list()
	local lines = {}
	if #convos == 0 then
		lines[#lines + 1] = "No saved conversations found."
	else
		lines[#lines + 1] = "Saved conversations:"
		for _, c in ipairs(convos) do
			local updated = c.updated_at and os.date("%Y-%m-%d %H:%M", c.updated_at) or "?"
			lines[#lines + 1] = "  " .. c.name .. " (" .. c.message_count .. " msgs, " .. updated .. ")"
		end
	end
	return show_pager_or_error(lines)
end

slash_commands["/prompt"] = function(self, args)
	local sub = args and args[1]

	if not sub then
		-- /prompt (no args) — show active prompt info
		local active = self.__state.config:get_active_prompt()
		if active then
			local content = config_mod.load_user_prompt(active)
			if content then
				write_info("Active prompt: " .. active)
			else
				write_error("Active prompt: " .. active .. " (file not found)")
			end
		else
			write_info("No user prompt active (using default system prompt only).")
		end
		local index_file = self.__state.config:get_index_file()
		if index_file and index_file ~= "" then
			local resolved = resolve_index_context(self, index_file)
			write_info("Index file: " .. index_file)
			if resolved.git_lookup_performed then
				write_info("  Git root lookup: refreshed")
			else
				write_info("  Git root lookup: cache reused")
			end
			if resolved.in_git_repo and resolved.repo_root then
				write_info("  Repo root: " .. resolved.repo_root)
			else
				write_info("  Repo root: (not in git repo)")
			end
			for _, check in ipairs(resolved.checks or {}) do
				write_info(format_index_check_line(check))
			end
		end
		return 0
	end

	return slash_prompt_handler(self, sub, args, {
		label = "user prompt",
		dir_hint = "~/.config/lilush/agent/prompts/",
		usage = "Usage: /prompt [list|set <name>|clear|show]",
		get_active = function()
			return self.__state.config:get_active_prompt()
		end,
		set_active = function(name)
			self.__state.config:set_active_prompt(name)
		end,
		list_fn = config_mod.list_user_prompts,
		load_fn = config_mod.load_user_prompt,
		clear_msg = "User prompt deactivated.",
		set_msg = "Active prompt set to: ",
	})
end

slash_commands["/sysprompt"] = function(self, args)
	local sub = args and args[1]

	if not sub then
		local active = self.__state.config:get_system_prompt()
		if active then
			local content = config_mod.load_system_prompt(active)
			if content then
				local has_env = content:match("{{%s*ENV%s*}}") and true or false
				local has_tools = content:match("{{%s*TOOLS%s*}}") and true or false
				write_info("Active system prompt: " .. active)
				write_info("  {{ ENV }}:   " .. (has_env and "detected" or "not found"))
				write_info("  {{ TOOLS }}: " .. (has_tools and "detected" or "not found"))
			else
				write_error("Active system prompt: " .. active .. " (file not found)")
			end
		else
			write_info("Using default system prompt.")
		end
		return 0
	end

	return slash_prompt_handler(self, sub, args, {
		label = "system prompt",
		dir_hint = "~/.config/lilush/agent/system_prompts/",
		usage = "Usage: /sysprompt [list|set <name>|clear|show]",
		get_active = function()
			return self.__state.config:get_system_prompt()
		end,
		set_active = function(name)
			self.__state.config:set_system_prompt(name)
		end,
		list_fn = config_mod.list_system_prompts,
		load_fn = config_mod.load_system_prompt,
		clear_msg = "System prompt reverted to default.",
		set_msg = "System prompt set to: ",
	})
end

slash_commands["/config"] = function(self, args)
	local resolved, resolve_err =
		self.__state.config:resolve_model(self.__state.config:get_model(), self.__state.config:get_provider())
	if not resolved then
		write_error("Error: " .. tostring(resolve_err))
		return 1
	end

	local provider_name = self.__state.config:get_provider()
	local provider_cfg = self.__state.config:get_provider_config(provider_name)
	local sampler = self.__state.config:get_sampler()
	local system_prompt_name = self.__state.config:get_system_prompt() or "(default)"
	local active_prompt = self.__state.config:get_active_prompt() or "(none)"
	local index_file = self.__state.config:get_index_file() or "(none)"
	local lines = {
		"Current configuration:",
		"  Provider:        " .. provider_name,
		"  Provider kind:   " .. tostring(provider_cfg and provider_cfg.kind or "?"),
		"  Model:           " .. self.__state.config:get_model(),
		"  Endpoint:        " .. tostring(resolved.endpoint or "(n/a)"),
		"  Context window:  " .. tostring(resolved.context_window or "?"),
		"  Model pricing:   " .. model_price_label(resolved),
		"  Temperature:     " .. tostring(sampler.temperature or "default"),
		"  Max new tokens:  " .. tostring(sampler.max_new_tokens or "default"),
		"  System prompt:   " .. system_prompt_name,
		"  Active prompt:   " .. active_prompt,
		"  Index file:      " .. index_file,
	}
	return show_pager_or_error(lines)
end

slash_commands["/cost"] = function(self, args)
	local cost_data = self.__state.session_usage or {}
	local lines = {
		"Session cost breakdown:",
		"  Requests:      " .. tostring(cost_data.request_count or 0),
		"  Input tokens:  " .. tostring(cost_data.input_tokens or 0),
		"  Output tokens: " .. tostring(cost_data.output_tokens or 0),
	}
	if (cost_data.cached_tokens or 0) > 0 then
		lines[#lines + 1] = "  Cached tokens: " .. tostring(cost_data.cached_tokens)
	end
	lines[#lines + 1] = "  Total cost:    " .. conversation_mod.format_cost(cost_data.total_cost or 0)

	local model = self.__state.config:get_model()
	local model_info = self.__state.model_info
	local input_price = model_info and tonumber(model_info.prompt_price) or nil
	local output_price = model_info and tonumber(model_info.completion_price) or nil
	if input_price == nil and output_price == nil then
		lines[#lines + 1] = "  (Unpriced model: '" .. model .. "')"
	elseif (input_price or 0) == 0 and (output_price or 0) == 0 then
		lines[#lines + 1] = "  (Model '" .. model .. "' is free)"
	else
		lines[#lines + 1] = "  (Model pricing: " .. model_price_label(model_info) .. ")"
	end

	return show_pager_or_error(lines)
end

-- Parse slash command from input
local function parse_slash_command(input)
	local cmd, rest = input:match("^(/[%w_]+)%s*(.*)")
	if not cmd then
		return nil
	end
	local args = {}
	for arg in rest:gmatch("%S+") do
		table.insert(args, arg)
	end
	return cmd, args
end

-- Initialize LLM client from current provider/model config.
local function init_client(self)
	local provider = self.__state.config:get_provider()
	local provider_config = self.__state.config:get_provider_config()
	local model = self.__state.config:get_model()
	if not provider_config then
		return nil, "unknown provider: " .. tostring(provider)
	end

	local discovered, discover_err = self.__state.config:discover_provider_models(provider)
	if not discovered then
		return nil, discover_err
	end

	local model_info, resolve_err = self.__state.config:resolve_model(model, provider)
	if not model_info then
		return nil, resolve_err
	end

	local api_key_env = provider_config.api_key_env
	local api_key = api_key_env and os.getenv(api_key_env)

	local client, client_err = llm.new("oaic", discovered.api_url or provider_config.url, api_key)
	if not client then
		return nil, client_err
	end

	self.__state.client = client
	self.__state.endpoint = model_info.endpoint
	self.__state.model_info = model_info
	return true
end

local reset_uninitialized_state = function(self, err)
	self.__state.initialized = false
	self.__state.init_error = err
	self.__state.config = nil
	self.__state.conversation = nil
	self.__state.client = nil
	self.__state.endpoint = nil
	self.__state.model_info = nil
end

local ensure_initialized = function(self)
	if self.__state.initialized then
		return true
	end

	local ok, cfg_or_err = pcall(config_mod.new)
	if not ok then
		reset_uninitialized_state(self, cfg_or_err)
		return nil, tostring(cfg_or_err)
	end

	self.__state.config = cfg_or_err

	local init_ok, init_err = self:init_client()
	if not init_ok then
		reset_uninitialized_state(self, init_err)
		return nil, tostring(init_err)
	end

	local system_prompt = self:build_system_prompt()
	self.__state.conversation = conversation_mod.new(system_prompt)
	self.__state.initialized = true
	self.__state.init_error = nil
	self:update_prompt()
	self:update_completion_context()

	return true
end

-- Update prompt with current state
local function update_prompt(self)
	local context_usage = self.__state.session_usage or {}
	local max_tokens = (self.__state.model_info and self.__state.model_info.context_window)
		or context_usage.context_window
		or 0

	local active_prompt = self.__state.config:get_active_prompt()
	local prompt_name = nil
	if active_prompt then
		prompt_name = active_prompt:match("^(.+)%..+$") or active_prompt
	end

	self.__state.input:prompt_set({
		model = self.__state.config:get_model(),
		provider = self.__state.config:get_provider(),
		tokens = context_usage.last_ctx_tokens or 0,
		max_tokens = max_tokens,
		cost = context_usage.total_cost or 0,
		prompt_name = prompt_name or false,
		status = nil,
	})
end

local update_completion_context = function(self)
	local input_obj = self.__state.input
	if not input_obj or type(input_obj.completion_update_source) ~= "function" then
		return
	end

	input_obj:completion_update_source("slash", {
		list_commands = function()
			return list_slash_command_names()
		end,
		get_provider = function()
			return self.__state.config:get_provider()
		end,
		list_providers = function()
			return self.__state.config:list_providers()
		end,
		list_models = function(provider_name)
			return self.__state.config:list_models(provider_name)
		end,
		list_prompts = function()
			return config_mod.list_user_prompts()
		end,
		list_system_prompts = function()
			return config_mod.list_system_prompts()
		end,
		list_saved_conversations = function()
			local entries = conversation_mod.list()
			local names = {}
			for _, entry in ipairs(entries or {}) do
				if type(entry.name) == "string" and entry.name ~= "" then
					names[#names + 1] = entry.name
				end
			end
			return names
		end,
	})
end

local list_tools = function(self)
	return self.__state.tools.list()
end

local get_tool_descriptions = function(self, tool_names)
	return self.__state.tools.get_descriptions(tool_names or self:list_tools())
end

-- Tool call handler for approval flow
local function on_tool_call(self, call, index, response)
	local tool_name = call.name
	local args = call.arguments
	if type(args) == "string" then
		args = json.decode(args) or {}
	end
	local needs_approval = self.__state.config:tool_needs_approval(tool_name)
	local sticky = (tool_name == "edit")

	-- Display tool being called
	local detail = tool_call_detail(tool_name, args)
	local lines_written = write_tool(tool_name, detail)
	local edit_preview = nil

	if tool_name == "edit" then
		local preview, preview_err = edit_diff_preview_mod.build(args)
		if preview then
			edit_preview = preview
			lines_written = lines_written + write_edit_diff_preview(preview)
		elseif preview_err then
			lines_written = lines_written + write_tool_warning("diff preview unavailable: " .. tostring(preview_err))
		end
	end

	-- Force approval for potentially destructive bash commands regardless of auto-approve
	if not needs_approval and tool_name == "bash" then
		local bash_tool = self.__state.tools.get("bash")
		if bash_tool and bash_tool.check_command then
			local danger = bash_tool.check_command(args.command)
			if danger then
				needs_approval = true
				lines_written = lines_written + write_tool_warning("potentially destructive: " .. danger)
			end
		end
	end

	-- Check if approval is needed
	if not needs_approval then
		return {
			action = "allow",
			display_lines = lines_written,
			sticky = sticky,
		}
	end

	-- Ask for approval
	local decision, approval_lines = ask_approval(tool_name, args, edit_preview)
	lines_written = lines_written + (tonumber(approval_lines) or 0)

	if decision == "abort" then
		return {
			action = "abort",
			error = "user aborted the tool call",
			display_lines = lines_written,
			sticky = sticky,
		}
	elseif type(decision) == "table" and decision.edit_args then
		local modified_call = {
			id = llm_tools.ensure_call_id(call),
			name = tool_name,
			arguments = decision.edit_args,
		}

		local modified_detail = tool_call_detail(tool_name, decision.edit_args)
		if modified_detail and modified_detail ~= "" then
			lines_written = lines_written + write_tool(tool_name, "modified: " .. tostring(modified_detail))
		else
			lines_written = lines_written + write_tool(tool_name, "modified")
		end
		return {
			action = "modify",
			call = modified_call,
			display_lines = lines_written,
			sticky = sticky,
		}
	elseif type(decision) == "table" and decision.abort_message then
		return {
			action = "abort",
			message = decision.abort_message,
			error = decision.abort_message,
			display_lines = lines_written,
			sticky = sticky,
		}
	elseif decision == "always" then
		self.__state.config:set_session_approval(tool_name, "auto")
		return {
			action = "allow",
			display_lines = lines_written,
			sticky = sticky,
		}
	else
		-- "yes" or any other input = allow
		return {
			action = "allow",
			display_lines = lines_written,
			sticky = sticky,
		}
	end
end

-- Format a compact one-line summary for a tool result
local function format_tool_summary(call, result, is_error)
	local name = llm_tools.normalize_tool_name(call)
	if is_error then
		local msg = type(result) == "table" and result.error or nil
		if msg then
			return "error: " .. tostring(msg)
		end
		return "error"
	end
	if type(result) ~= "table" then
		return "ok"
	end
	if name == "bash" then
		local code = result.exit_code or "?"
		local out_len = result.stdout and #result.stdout or 0
		return "exit " .. tostring(code) .. " (" .. out_len .. " bytes)"
	elseif name == "read" then
		local path = result.filepath or "?"
		local lines = result.lines
		if type(lines) == "table" and lines.start and lines["end"] then
			return path .. " (lines " .. lines.start .. "-" .. lines["end"] .. ")"
		end
		local total = result.total_lines
		if total then
			return path .. " (" .. total .. " lines)"
		end
		local content = result.content or ""
		return path .. " (" .. #content .. " bytes)"
	elseif name == "edit" then
		local path = result.filepath or "?"
		local line = tonumber(result.line)
		if line then
			return path .. " line " .. tostring(line) .. " ok"
		end
		return path .. " ok"
	elseif name == "write" then
		local path = result.filepath or "?"
		local bytes = result.bytes_written
		if bytes then
			return path .. " (" .. bytes .. " bytes)"
		end
		return path .. " ok"
	elseif name == "web_search" then
		local payload = result.results
		if type(payload) == "table" then
			local sources = payload.sources
			if type(sources) == "table" then
				return tostring(#sources) .. " sources"
			end
		end
		return "ok"
	elseif name == "fetch_webpage" then
		local page = result.page or ""
		return #page .. " bytes"
	end
	return "ok"
end

-- Tool result handler - display compact summary
local function on_tool_result(self, call, result, is_error)
	local summary = format_tool_summary(call, result, is_error)
	return write_tool_result(summary)
end

-- Process LLM response (streaming or not)
local function process_response(self, user_input)
	while true do
		-- Add user message to conversation
		self.__state.conversation:add_user(user_input)

		-- Pre-send guard: refuse to send if context is nearly exhausted and we can't trim more
		local pre_ctx_pct = (self.__state.session_usage or {}).last_ctx_pct or 0
		if pre_ctx_pct >= 95 and self.__state.conversation:count() <= 2 then
			write_error(
				"Context window nearly exhausted (" .. tostring(pre_ctx_pct) .. "%). Use /clear to start fresh."
			)
			return 1, "context window exhausted"
		end

		-- Update system prompt (it has dynamic block, needs to be refreshed each turn)
		local fresh_prompt = self:build_system_prompt()
		self.__state.conversation:set_system_prompt(fresh_prompt)

		-- Get messages for LLM (old tool results are truncated)
		local messages = self.__state.conversation:get_messages_for_api()
		local sampler = self.__state.config:get_sampler()
		local model = self.__state.config:get_model()

		local model_info = self.__state.model_info or {}
		local endpoint = self.__state.endpoint

		-- Create stream buffer for markdown rendering
		write_line("") -- Blank line before response
		local stream = stream_mod.new({
			output_fn = function(text)
				term.write(text)
			end,
		})

		local tool_trace = {}
		local seen_tool_responses = {}
		local modified_calls_by_id = {}
		local tool_render_state = {
			transient_lines = 0,
			sticky_lines = 0,
			chain_active = false,
		}

		local add_tool_render_lines = function(lines, sticky)
			lines = tonumber(lines) or 0
			if lines <= 0 then
				return
			end
			if sticky then
				tool_render_state.sticky_lines = (tool_render_state.sticky_lines or 0) + lines
			else
				tool_render_state.transient_lines = (tool_render_state.transient_lines or 0) + lines
			end
			tool_render_state.chain_active = true
		end

		local thinking_indicator = nil

		local append_tool_assistant_trace = function(response)
			if type(response) ~= "table" then
				return
			end
			if seen_tool_responses[response] then
				return
			end
			seen_tool_responses[response] = true

			local calls = {}
			for i, call in ipairs(response.tool_calls or {}) do
				calls[#calls + 1] = {
					id = llm_tools.ensure_call_id(call),
					name = llm_tools.normalize_tool_name(call),
					arguments = llm_tools.normalize_tool_args(call),
				}
			end
			if #calls == 0 then
				return
			end

			tool_trace[#tool_trace + 1] = {
				role = "assistant",
				content = response.text or "",
				tool_calls = calls,
			}
		end

		-- Create tool call handler bound to self
		local tool_handler = function(call, index, response)
			append_tool_assistant_trace(response)

			if thinking_indicator then
				clear_thinking_indicator(thinking_indicator)
				thinking_indicator = nil
			end

			-- Flush terminal output before prompting for approval, but keep parser state.
			stream:checkpoint()
			local had_stream_output = stream:had_output()
			if had_stream_output then
				-- Keep visual separation when assistant text was emitted before the call.
				write_line("")
				tool_render_state.transient_lines = 0
				tool_render_state.sticky_lines = 0
				tool_render_state.chain_active = false
			elseif tool_render_state.chain_active and tool_render_state.transient_lines > 0 then
				clear_previous_tool_output(tool_render_state.transient_lines)
				tool_render_state.transient_lines = 0
			end

			local result = on_tool_call(self, call, index, response)
			result = result or { action = "allow", display_lines = 0 }
			add_tool_render_lines(result.display_lines, result.sticky == true)

			-- Show tool result summary
			if result.action == "allow" then
				-- Result will be shown after execution by on_tool_result
			elseif result.action == "modify" and type(result.call) == "table" then
				local call_id = llm_tools.ensure_call_id(result.call)
				modified_calls_by_id[call_id] = {
					id = call_id,
					name = llm_tools.normalize_tool_name(result.call),
					arguments = llm_tools.normalize_tool_args(result.call),
				}
			elseif result.action == "deny" or result.action == "abort" then
				add_tool_render_lines(
					write_tool_result("denied: " .. (result.error or "user denied")),
					result.sticky == true
				)
			end
			return result
		end

		-- Create tool result handler bound to self
		local result_handler = function(call, result, is_error)
			local call_id = llm_tools.ensure_call_id(call)
			local encoded_result = json.encode(result)
			if not encoded_result then
				encoded_result = tostring(result)
			end
			tool_trace[#tool_trace + 1] = {
				role = "tool",
				tool_call_id = call_id,
				content = encoded_result,
			}
			local lines_written = on_tool_result(self, call, result, is_error)
			add_tool_render_lines(lines_written, llm_tools.normalize_tool_name(call) == "edit")
		end

		local persist_tool_trace = function()
			for _, msg in ipairs(tool_trace) do
				if msg.role == "assistant" and type(msg.tool_calls) == "table" then
					for i, call in ipairs(msg.tool_calls) do
						local replacement = call and call.id and modified_calls_by_id[call.id]
						if replacement then
							msg.tool_calls[i] = replacement
						end
					end
				end
			end

			for _, msg in ipairs(tool_trace) do
				if msg.role == "assistant" then
					self.__state.conversation:add_assistant(msg.content, msg.tool_calls)
				elseif msg.role == "tool" then
					self.__state.conversation:add_tool_result(msg.tool_call_id, msg.content)
				end
			end
		end

		local tools_list = self:list_tools()

		-- Install SIGINT cancel handler for streaming interruption
		term.install_cancel_handler()

		-- Run tool loop with streaming
		local resp, err = self.__state.tools.loop(self.__state.client, model, messages, sampler, {
			tools = tools_list,
			tool_objects = self:get_tool_descriptions(tools_list),
			execute_tools = true,
			max_steps = self.__state.config:get_max_tool_steps(),
			stream = true,
			style = "oaic",
			endpoint = endpoint,
			is_cancelled = function()
				return term.check_cancel()
			end,
			on_tool_call = tool_handler,
			on_tool_result = result_handler,
			on_tool_warning = function(message, _call)
				if thinking_indicator then
					clear_thinking_indicator(thinking_indicator)
					thinking_indicator = nil
				end
				stream:checkpoint()
				local had_stream_output = stream:had_output()
				if had_stream_output then
					write_line("")
				end
				tool_render_state.transient_lines = 0
				tool_render_state.sticky_lines = 0
				tool_render_state.chain_active = false
				write_info("Warning: " .. tostring(message))
			end,
			callbacks = {
				chunk = function(chunk)
					if chunk.kind == "reasoning" and chunk.text then
						if not thinking_indicator then
							thinking_indicator = show_thinking_indicator()
						end
					elseif chunk.text then
						if thinking_indicator then
							clear_thinking_indicator(thinking_indicator)
							thinking_indicator = nil
						end
						if (tool_render_state.sticky_lines or 0) > 0 then
							local lines_to_clear = (tool_render_state.sticky_lines or 0)
								+ (tool_render_state.transient_lines or 0)
							clear_previous_tool_output(lines_to_clear)
							tool_render_state.sticky_lines = 0
							tool_render_state.transient_lines = 0
							tool_render_state.chain_active = false
						end
						stream:push(chunk.text)
					end
				end,
				done = function()
					if thinking_indicator then
						clear_thinking_indicator(thinking_indicator)
						thinking_indicator = nil
					end
					-- Keep markdown state open across streamed tool steps.
					stream:checkpoint()
				end,
				retry = function(attempt, status)
					write_info(
						"Retrying (attempt " .. tostring(attempt) .. ") after HTTP " .. tostring(status or "?") .. "..."
					)
				end,
			},
		})

		-- Remove SIGINT cancel handler
		term.remove_cancel_handler()

		if thinking_indicator then
			clear_thinking_indicator(thinking_indicator)
			thinking_indicator = nil
		end

		if not resp then
			stream:finalize()
			persist_tool_trace()
			write_error("Error: " .. tostring(err))
			return 1, err
		end

		-- Handle cancelled response (Ctrl+C during streaming)
		if resp.cancelled then
			stream:finalize()
			persist_tool_trace()
			-- Add partial assistant message to conversation history
			if resp.text and #resp.text > 0 then
				self.__state.conversation:add_assistant(resp.text, nil)
				write_line("")
			end
			write_info("Cancelled.")
			self:update_prompt()
			return 0
		end

		-- Check for empty response (might indicate silent API error)
		if (not resp.text or resp.text == "") and (not resp.tool_calls or #resp.tool_calls == 0) then
			stream:finalize()
			write_error("Error: Empty response from API (possible authentication or API issue)")
			return 1, "empty response"
		end

		-- Track usage and cost
		-- Use cumulative usage from tool loop for session accounting (captures all
		-- intermediate API calls), but keep resp.ctx for context window display.
		local cu = resp.cumulative_usage
		local input_tokens, output_tokens
		if cu then
			input_tokens = cu.input_tokens
			output_tokens = cu.output_tokens
		else
			input_tokens = (resp.ctx or 0) - (resp.tokens or 0)
			if input_tokens < 0 then
				input_tokens = 0
			end
			output_tokens = resp.tokens or 0
		end
		local ctx_tokens = resp.ctx or 0
		local usage_args = {
			input_tokens,
			output_tokens,
			0,
			ctx_tokens,
			model_info.context_window,
			model_info.prompt_price,
			model_info.completion_price,
		}
		self.__state.conversation:add_usage(unpack(usage_args))
		conversation_mod.add_cost_usage(self.__state.session_usage, unpack(usage_args))

		-- Context window enforcement: auto-trim old turns when approaching the limit.
		-- Trim at most 3 turns; the next API response reports real context usage.
		local ctx_pct = (self.__state.session_usage or {}).last_ctx_pct or 0
		if ctx_pct >= 90 then
			write_info("Context usage at " .. tostring(ctx_pct) .. "% — oldest turns will be trimmed automatically")
			local trimmed = 0
			while trimmed < 3 and self.__state.conversation:count() > 2 do
				if not self.__state.conversation:trim_oldest_turn() then
					break
				end
				trimmed = trimmed + 1
			end
			if self.__state.conversation:count() <= 2 then
				write_info("Context nearly full — consider using /clear to start fresh.")
			end
		end

		-- Finalize markdown stream at end of turn.
		stream:finalize()

		-- Persist executed tool traces so pager transcript matches live execution output.
		persist_tool_trace()

		-- Handle aborted response (user denied tool execution)
		if resp.aborted then
			local has_tool_trace = #tool_trace > 0
			-- Add assistant's partial response to conversation (if any text and not already captured in tool trace)
			if (not has_tool_trace) and resp.text and #resp.text > 0 then
				self.__state.conversation:add_assistant(resp.text, nil)
				write_line("")
			end

			-- If user provided a message, continue conversation with their feedback
			if resp.abort_message then
				write_info("Feedback: " .. resp.abort_message)
				user_input = resp.abort_message
				-- Continue loop to re-process with feedback as new user input
			else
				-- No message = just stop and wait for next user input
				self:update_prompt()
				return 0
			end
		else
			-- Normal completion: add final assistant response (tool trace already persisted above)
			if #tool_trace == 0 then
				self.__state.conversation:add_assistant(resp.text, resp.tool_calls)
			end

			-- Add trailing newline if there was content
			if resp.text and #resp.text > 0 then
				write_line("")
			end

			-- Update prompt with new token count and cost
			self:update_prompt()

			return 0
		end
	end
end

-- Build the full system prompt from default + user prompt + project context
local function build_system_prompt(self)
	local active_prompt = self.__state.config:get_active_prompt()
	local user_prompt_content = config_mod.load_user_prompt(active_prompt)
	local index_file = self.__state.config:get_index_file()
	local index_content = nil
	if index_file and index_file ~= "" then
		local resolved = resolve_index_context(self, index_file)
		index_content = resolved and resolved.index_content or nil
	end

	local custom_name = self.__state.config:get_system_prompt()
	if custom_name then
		local custom_template = config_mod.load_system_prompt(custom_name)
		if custom_template then
			return system_prompt_mod.assemble_custom(custom_template, user_prompt_content, index_content)
		end
	end

	return system_prompt_mod.assemble(user_prompt_content, index_content)
end

-- Main run function
local function run(self)
	local initialized, init_err = self:ensure_initialized()
	if not initialized then
		return 1, init_err
	end

	local input_text = self.__state.input:get_content()

	-- Handle empty input
	if not input_text or input_text:match("^%s*$") then
		return 0
	end

	-- Handle slash commands
	local cmd, args = parse_slash_command(input_text)
	if cmd then
		local handler = slash_commands[cmd]
		if handler then
			return handler(self, args)
		else
			write_error("Unknown command: " .. cmd)
			write_info("Type /help for available commands.")
			return 1
		end
	end

	-- Process as LLM input
	return process_response(self, input_text)
end

local get_input = function(self)
	return self.__state.input
end

local can_handle_combo = function(self, combo)
	return type(self.__state.combos[combo]) == "function"
end

local handle_combo = function(self, combo)
	local initialized, init_err = self:ensure_initialized()
	if not initialized then
		write_error("Error: " .. tostring(init_err))
		return true
	end

	local handler = self.__state.combos[combo]
	if type(handler) == "function" then
		return handler(self, combo)
	end
	return false
end

local on_activate = function(self)
	return self:ensure_initialized()
end

-- Constructor
local function new(input_obj, config)
	local mode = {
		cfg = config or {},
		__state = {
			input = input_obj,
			combos = {
				["ALT+h"] = show_conversation_combo,
			},
			initialized = false,
			init_error = nil,
			config = nil,
			conversation = nil,
			session_usage = conversation_mod.new_cost(),
			client = nil,
			tools = llm_tools,
			endpoint = nil,
			model_info = nil,
			index_ctx_cache = {
				repo_root = nil,
				in_git_repo = false,
				last_cwd = nil,
			},
		},

		-- Methods
		init_client = init_client,
		ensure_initialized = ensure_initialized,
		on_activate = on_activate,
		update_prompt = update_prompt,
		update_completion_context = update_completion_context,
		build_system_prompt = build_system_prompt,
		list_tools = list_tools,
		get_tool_descriptions = get_tool_descriptions,
		run = run,
		get_input = get_input,
		can_handle_combo = can_handle_combo,
		handle_combo = handle_combo,
	}

	return mode
end

return { new = new }
