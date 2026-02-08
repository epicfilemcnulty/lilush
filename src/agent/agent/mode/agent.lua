-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Agent mode for Lilush shell.

Provides an agentic coding assistant with:
- Streaming LLM responses with formatting
- Tool execution with configurable approval
- Conversation management
- Support for multiple LLM backends
]]

local std = require("std")
local term = require("term")
local json = require("cjson.safe")
local llm = require("llm")
local style = require("term.tss")
local theme = require("agent.theme")

local config_mod = require("agent.config")
local conversation_mod = require("agent.conversation")
local system_prompt_mod = require("agent.system_prompt")
local stream_mod = require("agent.stream")
local agent_tools = require("agent.tools")

-- Create TSS instance for styled output
local tss = style.new(theme)

-- Output helpers
-- Note: Mode runs in sane mode, so use \n (not \r\n which is for raw mode)
local function write_line(text)
	term.write(text .. "\n")
end

local function write_error(text)
	term.write(tss:apply("agent.error", text).text .. "\n")
end

local function write_info(text)
	term.write(tss:apply("agent.info", text).text .. "\n")
end

local function write_tool(name, args_summary)
	term.write(tss:apply("agent.tool.bracket", "[").text)
	term.write(tss:apply("agent.tool.name", name).text)
	term.write(tss:apply("agent.tool.bracket", "]").text)
	if args_summary then
		term.write(" " .. tss:apply("agent.tool.args", args_summary).text)
	end
	term.write("\n")
end

local function write_tool_result(result_summary)
	term.write(tss:apply("agent.tool.result_prefix").text)
	term.write(tss:apply("agent.tool.result", result_summary).text .. "\n")
end

-- Debug output helpers
local function write_debug(label, text)
	term.write(tss:apply("agent.debug.bracket", "[debug:").text)
	term.write(tss:apply("agent.debug.label", label).text)
	term.write(tss:apply("agent.debug.bracket", "]").text)
	term.write(" " .. tss:apply("agent.debug.text", text).text .. "\n")
end

-- Code block output for streaming
local function write_code_block(lang, code)
	if lang and lang ~= "" then
		term.write(tss:apply("agent.code.lang", lang).text .. "\n")
	end
	local bar = tss:apply("agent.code.bar").text
	-- Use std.txt.lines() to properly split without extra blank lines
	for _, line in ipairs(std.txt.lines(code)) do
		term.write(bar .. tss:apply("agent.code.text", line).text .. "\n")
	end
end

-- Truncate string for debug output (max ~200 chars, 2-3 lines worth)
local function truncate_for_debug(str, max_len)
	max_len = max_len or 200
	if not str then
		return "nil"
	end
	local len = std.utf.len(str)
	if len <= max_len then
		return str
	end
	return std.utf.sub(str, 1, max_len) .. "... (" .. #str .. " bytes total)"
end

-- Format table for debug output (truncated JSON)
local function format_debug_table(tbl)
	if not tbl then
		return "nil"
	end
	local encoded = json.encode(tbl)
	if not encoded then
		return "<encoding error>"
	end
	return truncate_for_debug(encoded, 300)
end

-- Format a tool call for display
local function format_tool_args(name, args)
	if type(args) == "string" then
		args = json.decode(args) or {}
	end
	args = args or {}

	-- Create a brief summary based on tool type
	if name == "read_file" then
		local summary = args.filepath or "?"
		if args.start_line then
			summary = summary .. ":" .. args.start_line
			if args.end_line then
				summary = summary .. "-" .. args.end_line
			end
		end
		return summary
	elseif name == "write_file" or name == "edit_file" then
		return args.filepath or "?"
	elseif name == "bash" then
		local cmd = args.command or "?"
		if std.utf.len(cmd) > 60 then
			cmd = std.utf.sub(cmd, 1, 57) .. "..."
		end
		return cmd
	elseif name == "web_search" then
		return args.query or "?"
	elseif name == "fetch_webpage" then
		local url = args.url or "?"
		if std.utf.len(url) > 50 then
			url = std.utf.sub(url, 1, 47) .. "..."
		end
		return url
	else
		-- Generic: show first string argument
		for k, v in pairs(args) do
			if type(v) == "string" then
				if std.utf.len(v) > 50 then
					v = std.utf.sub(v, 1, 47) .. "..."
				end
				return v
			end
		end
		return ""
	end
end

-- Ask for tool approval
-- Returns: "yes", "no", "edit", "always", "abort", or {abort_message = "..."}
local function ask_approval(tool_name, args)
	term.write(tss:apply("agent.approval.bracket", "[").text)
	term.write(tss:apply("agent.approval.name", tool_name).text)
	term.write(tss:apply("agent.approval.bracket", "]").text)
	term.write(tss:apply("agent.approval.options", " Execute? [Y/n/m/a] ").text)
	io.flush()

	-- Read full line in sane mode (consumes the newline from Enter)
	-- User types their choice and presses Enter
	local line = io.read("*l")
	local key = line and line:sub(1, 1) or ""

	key = key:lower()
	if key == "n" then
		-- Abort without message
		return "abort"
	elseif key == "m" then
		-- Abort with message - prompt for feedback
		term.write(tss:apply("agent.approval.options", "Message: ").text)
		io.flush()
		local msg = io.read("*l")
		if msg and msg ~= "" then
			return { abort_message = msg }
		end
		return "abort"
	elseif key == "a" then
		return "always"
	else
		return "yes"
	end
end

-- Slash command handlers
local slash_commands = {}

slash_commands["/help"] = function(self, args)
	write_line("Available commands:")
	write_line("  /help              - Show this help")
	write_line("  /clear             - Clear conversation history")
	write_line("  /model [name]      - Show or set current model")
	write_line("  /backend [name]    - Show or set current backend")
	write_line("  /models            - List available backends")
	write_line("  /tools             - List available tools")
	write_line("  /tokens            - Show token usage")
	write_line("  /cost              - Show session cost breakdown")
	write_line("  /save [name]       - Save conversation to file")
	write_line("  /load [name]       - Load conversation from file")
	write_line("  /list              - List saved conversations")
	write_line("  /system [prompt]   - Show or set system prompt")
	write_line("  /config            - Show current configuration")
	write_line("  /debug             - Toggle debug mode")
	write_line("")
	write_line("Tool approval options:")
	write_line("  Y/Enter - Execute the tool")
	write_line("  n       - Deny and stop (wait for next input)")
	write_line("  m       - Deny with message (provide feedback)")
	write_line("  a       - Allow all (auto-approve this tool for session)")
	return 0
end

slash_commands["/clear"] = function(self, args)
	local system_prompt = self.__state.config:get_system_prompt() or system_prompt_mod.get()
	self.__state.conversation = conversation_mod.new(system_prompt)
	self.__state.config:clear_session_approvals()
	self:update_prompt()
	write_info("Conversation cleared.")
	return 0
end

slash_commands["/model"] = function(self, args)
	if args and #args > 0 then
		local model_name = args[1]
		local backend_name = args[2] -- Optional
		local ok, err = self.__state.config:set_model(model_name, backend_name)
		if not ok then
			write_error("Error: " .. err)
			return 1
		end
		self:init_client()
		self:update_prompt()
		write_info("Model set to: " .. self.__state.config:get_model())
	else
		write_line("Current model: " .. (self.__state.config:get_model() or "not set"))
		write_line("Current backend: " .. (self.__state.config:get_backend() or "not set"))
	end
	return 0
end

slash_commands["/backend"] = function(self, args)
	if args and #args > 0 then
		local backend_name = args[1]
		local ok, err = self.__state.config:set_backend(backend_name)
		if not ok then
			write_error("Error: " .. err)
			return 1
		end
		self:init_client()
		self:update_prompt()
		write_info("Backend set to: " .. backend_name .. ", model: " .. self.__state.config:get_model())
	else
		write_line("Current backend: " .. (self.__state.config:get_backend() or "not set"))
		write_line("Available backends: " .. table.concat(self.__state.config:list_backends(), ", "))
	end
	return 0
end

slash_commands["/models"] = function(self, args)
	write_line("Available backends:")
	for _, name in ipairs(self.__state.config:list_backends()) do
		local bc = self.__state.config:get_backend_config(name)
		local marker = (name == self.__state.config:get_backend()) and " *" or ""
		write_line("  " .. name .. marker .. " (default model: " .. (bc.default_model or "?") .. ")")
	end
	return 0
end

slash_commands["/tools"] = function(self, args)
	write_line("Available tools:")
	for _, name in ipairs(self:list_tools()) do
		local tool_config = self.__state.config:get_tool_config(name)
		local approval = tool_config.approval or "auto"
		write_line("  " .. name .. " [" .. approval .. "]")
	end
	return 0
end

slash_commands["/tokens"] = function(self, args)
	local tokens = self.__state.conversation:tokens()
	local max_tokens = self.__state.config:get_max_tokens()
	local percentage = math.floor((tokens / max_tokens) * 100)
	write_line("Token usage: " .. tokens .. " / " .. max_tokens .. " (" .. percentage .. "%)")
	write_line("Messages: " .. self.__state.conversation:count())
	return 0
end

slash_commands["/save"] = function(self, args)
	local name = args and args[1]
	if not name then
		write_error("Usage: /save <name>")
		return 1
	end
	local filepath, err = self.__state.conversation:save(name)
	if not filepath then
		write_error("Error: " .. err)
		return 1
	end
	write_info("Conversation saved to: " .. filepath)
	return 0
end

slash_commands["/load"] = function(self, args)
	local name = args and args[1]
	if not name then
		-- List available conversations
		local convos = conversation_mod.list()
		if #convos == 0 then
			write_info("No saved conversations found.")
		else
			write_line("Saved conversations:")
			for _, c in ipairs(convos) do
				write_line("  " .. c.name .. " (" .. c.message_count .. " messages)")
			end
		end
		return 0
	end
	local ok, err = self.__state.conversation:load(name)
	if not ok then
		write_error("Error: " .. err)
		return 1
	end
	self:update_prompt()
	write_info("Loaded conversation: " .. name .. " (" .. self.__state.conversation:count() .. " messages)")
	return 0
end

slash_commands["/list"] = function(self, args)
	local convos = conversation_mod.list()
	if #convos == 0 then
		write_info("No saved conversations found.")
	else
		write_line("Saved conversations:")
		for _, c in ipairs(convos) do
			local updated = c.updated_at and os.date("%Y-%m-%d %H:%M", c.updated_at) or "?"
			write_line("  " .. c.name .. " (" .. c.message_count .. " msgs, " .. updated .. ")")
		end
	end
	return 0
end

slash_commands["/system"] = function(self, args)
	if args and #args > 0 then
		local new_prompt = table.concat(args, " ")
		self.__state.config:set_system_prompt(new_prompt)
		self.__state.conversation:set_system_prompt(new_prompt)
		write_info("System prompt updated.")
	else
		local prompt = self.__state.conversation:get_system_prompt()
		if prompt then
			write_line("Current system prompt:")
			write_line(prompt)
		else
			write_info("No system prompt set (using default).")
		end
	end
	return 0
end

slash_commands["/config"] = function(self, args)
	write_line("Current configuration:")
	write_line("  Backend: " .. self.__state.config:get_backend())
	write_line("  Model: " .. self.__state.config:get_model())
	local sampler = self.__state.config:get_sampler()
	write_line("  Temperature: " .. (sampler.temperature or "default"))
	write_line("  Max tokens: " .. (sampler.max_new_tokens or "default"))
	write_line("  Context limit: " .. self.__state.config:get_max_tokens())
	return 0
end

slash_commands["/cost"] = function(self, args)
	local pricing = require("llm.pricing")
	local cost_data = self.__state.conversation:get_cost()

	write_line("Session cost breakdown:")
	write_line("  Requests:      " .. cost_data.request_count)
	write_line("  Input tokens:  " .. cost_data.input_tokens)
	write_line("  Output tokens: " .. cost_data.output_tokens)
	if cost_data.cached_tokens > 0 then
		write_line("  Cached tokens: " .. cost_data.cached_tokens)
	end
	write_line("  Total cost:    " .. pricing.format_cost(cost_data.total_cost))

	-- Show if model has known pricing
	local model = self.__state.config:get_model()
	local model_price = pricing.get_price(model)
	if not model_price then
		write_info("  (Note: No pricing data for model '" .. model .. "')")
	elseif pricing.is_free(model) then
		write_info("  (Model '" .. model .. "' is free)")
	end

	return 0
end

slash_commands["/debug"] = function(self, args)
	self.__state.debug = not self.__state.debug
	if self.__state.debug then
		write_info("Debug mode enabled - tool args and results will be shown")
	else
		write_info("Debug mode disabled")
	end
	return 0
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

-- Initialize LLM client
-- Handles Zen routing to correct endpoint based on model's api_style
local function init_client(self)
	local backend = self.__state.config:get_backend()
	local backend_config = self.__state.config:get_backend_config()
	local model = self.__state.config:get_model()

	-- Get API key from environment variable specified in config
	local api_key_env = backend_config.api_key_env
	local api_key = api_key_env and os.getenv(api_key_env)

	-- For Zen, we need to route to correct endpoint based on model's api_style
	if backend == "zen" then
		local model_config = self.__state.config:get_model_config(model)
		local api_style = model_config and model_config.api_style or "oaic"
		local base_url = backend_config.url

		if api_style == "anthropic" then
			-- Use anthropic client with Zen URL (anthropic.lua adds /messages internally)
			self.__state.client = llm.new("anthropic", base_url, api_key)
		else
			-- Use oaic client with Zen URL (oaic.lua appends /chat/completions internally)
			-- NOTE: When /responses endpoint support is added, this will need to change
			self.__state.client = llm.new("oaic", base_url, api_key)
		end
		-- Store the effective api_style for tool loop
		self.__state.api_style = api_style
	else
		-- For non-Zen backends, use api_style to determine client type
		local api_style = backend_config.api_style or backend
		if api_style == "oaic" then
			self.__state.client = llm.new("oaic", backend_config.url, api_key)
		elseif api_style == "anthropic" then
			self.__state.client = llm.new("anthropic", backend_config.url, api_key)
		else
			-- Native backend (llamacpp native, etc)
			self.__state.client = llm.new(backend, backend_config.url, api_key)
		end
		self.__state.api_style = api_style
	end
end

-- Update prompt with current state
local function update_prompt(self)
	self.__state.input:prompt_set({
		model = self.__state.config:get_model(),
		backend = self.__state.config:get_backend(),
		tokens = self.__state.conversation:tokens(),
		max_tokens = self.__state.config:get_max_tokens(),
		cost = self.__state.conversation:get_total_cost(),
		status = nil,
	})
end

local list_tools = function(self)
	return self.__state.tools.list()
end

local get_tool_descriptions = function(self, tool_names)
	return self.__state.tools.get_descriptions(tool_names or self:list_tools())
end

local is_debug_enabled = function(self)
	return self.__state.debug
end

-- Tool call handler for approval flow
local function on_tool_call(self, call, index, response)
	local tool_name = call.name
	local args = call.arguments
	if type(args) == "string" then
		args = json.decode(args) or {}
	end

	-- Display tool being called
	write_tool(tool_name, format_tool_args(tool_name, args))

	-- Show full args in debug mode
	if self.__state.debug then
		write_debug("args", format_debug_table(args))
	end

	-- Check if approval is needed
	if not self.__state.config:tool_needs_approval(tool_name) then
		return { action = "allow" }
	end

	-- Ask for approval
	local decision = ask_approval(tool_name, args)

	if decision == "abort" then
		-- Abort without message
		return { action = "abort" }
	elseif type(decision) == "table" and decision.abort_message then
		-- Abort with user message
		return { action = "abort", message = decision.abort_message }
	elseif decision == "always" then
		self.__state.config:set_session_approval(tool_name, "auto")
		return { action = "allow" }
	else
		-- "yes" or any other input = allow
		return { action = "allow" }
	end
end

-- Tool result handler for debug output
local function on_tool_result(self, call, result, is_error)
	if not self:is_debug_enabled() then
		return
	end
	if is_error then
		write_debug("error", format_debug_table(result))
	else
		write_debug("result", format_debug_table(result))
	end
end

-- Process LLM response (streaming or not)
local function process_response(self, user_input)
	-- Add user message to conversation
	self.__state.conversation:add_user(user_input)

	-- Update prompt to show streaming status
	self.__state.input:prompt_set({ status = "streaming" })

	-- Get messages for LLM
	local messages = self.__state.conversation:get_messages()
	local sampler = self.__state.config:get_sampler()
	local model = self.__state.config:get_model()

	-- Use the api_style determined during init_client
	local style = self.__state.api_style or "oaic"

	-- Create stream buffer for markdown rendering
	write_line("") -- Blank line before response
	local stream = stream_mod.new({
		on_text = function(text)
			term.write(text)
		end,
		on_code = function(lang, code)
			write_code_block(lang, code)
		end,
	})

	-- Create tool call handler bound to self
	local tool_handler = function(call, index, response)
		-- Flush stream buffer before prompting for approval
		stream:flush()
		-- Add newline separator if there was text output before this tool call
		if stream:had_output() then
			write_line("")
		end
		local result = on_tool_call(self, call, index, response)
		-- Show tool result summary
		if result.action == "allow" then
			-- Result will be shown after execution by on_tool_result
		elseif result.action == "deny" then
			write_tool_result("denied: " .. (result.error or "user denied"))
		end
		return result
	end

	-- Create tool result handler bound to self
	local result_handler = function(call, result, is_error)
		on_tool_result(self, call, result, is_error)
	end

	local tools_list = self:list_tools()

	-- Run tool loop with streaming
	local resp, err = self.__state.tools.loop(self.__state.client, model, messages, sampler, {
		tools = tools_list,
		tool_objects = self:get_tool_descriptions(tools_list),
		execute_tools = true,
		max_steps = 100,
		stream = true,
		style = style,
		on_tool_call = tool_handler,
		on_tool_result = result_handler,
		callbacks = {
			chunk = function(chunk)
				if chunk.text then
					stream:push(chunk.text)
				end
			end,
			done = function()
				stream:flush()
			end,
		},
	})

	-- Clear status (use false as sentinel since pairs() skips nil)
	self.__state.input:prompt_set({ status = false })

	if not resp then
		write_error("Error: " .. tostring(err))
		return 1, err
	end

	-- Check for empty response (might indicate silent API error)
	if (not resp.text or resp.text == "") and (not resp.tool_calls or #resp.tool_calls == 0) then
		write_error("Error: Empty response from API (possible authentication or API issue)")
		return 1, "empty response"
	end

	-- Track usage and cost
	-- Input tokens = total context - output tokens (approximation)
	local input_tokens = (resp.ctx or 0) - (resp.tokens or 0)
	local output_tokens = resp.tokens or 0
	self.__state.conversation:add_usage(model, input_tokens, output_tokens, 0)

	-- Ensure stream is flushed
	stream:flush()

	-- Handle aborted response (user denied tool execution)
	if resp.aborted then
		-- Add assistant's partial response to conversation (if any text)
		if resp.text and #resp.text > 0 then
			self.__state.conversation:add_assistant(resp.text, nil)
			write_line("")
		end

		-- If user provided a message, continue conversation with their feedback
		if resp.abort_message then
			write_info("Feedback: " .. resp.abort_message)
			-- Recursively process the abort message as new user input
			-- This lets the LLM see the feedback and try a different approach
			return process_response(self, resp.abort_message)
		end

		-- No message = just stop and wait for next user input
		self:update_prompt()
		return 0
	end

	-- Add assistant response to conversation
	self.__state.conversation:add_assistant(resp.text, resp.tool_calls)

	-- Add trailing newline if there was content
	if resp.text and #resp.text > 0 then
		write_line("")
	end

	-- Update prompt with new token count and cost
	self:update_prompt()

	return 0
end

-- Main run function
local function run(self)
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
	local handler = self.__state.combos[combo]
	if type(handler) == "function" then
		return handler(self, combo)
	end
	return false
end

-- Constructor
local function new(input_obj, config)
	local mode = {
		cfg = config or {},
		__state = {
			input = input_obj,
			combos = {
				-- TODO: Add key combos
				-- ["ALT+c"] = clear_conversation_combo,
				-- ["ALT+m"] = switch_model_combo,
			},
			config = config_mod.new(),
			conversation = nil,
			client = nil,
			tools = agent_tools,
			debug = false,
			api_style = nil,
		},

		-- Methods
		init_client = init_client,
		update_prompt = update_prompt,
		list_tools = list_tools,
		get_tool_descriptions = get_tool_descriptions,
		is_debug_enabled = is_debug_enabled,
		run = run,
		get_input = get_input,
		can_handle_combo = can_handle_combo,
		handle_combo = handle_combo,
	}

	-- Initialize client
	mode:init_client()

	-- Initialize conversation with system prompt
	local system_prompt = mode.__state.config:get_system_prompt() or system_prompt_mod.get()
	mode.__state.conversation = conversation_mod.new(system_prompt)

	-- Update prompt with initial state
	mode:update_prompt()

	return mode
end

return { new = new }
