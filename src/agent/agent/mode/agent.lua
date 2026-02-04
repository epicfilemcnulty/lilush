-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

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
local llm_tools = require("llm.tools")
local style = require("term.tss")
local theme = require("agent.theme")

local config_mod = require("agent.config")
local conversation_mod = require("agent.conversation")
local system_prompt_mod = require("agent.system_prompt")
local stream_mod = require("agent.stream")

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
	local system_prompt = self.config:get_system_prompt() or system_prompt_mod.get()
	self.conversation = conversation_mod.new(system_prompt)
	self.config:clear_session_approvals()
	self:update_prompt()
	write_info("Conversation cleared.")
	return 0
end

slash_commands["/model"] = function(self, args)
	if args and #args > 0 then
		local model_name = args[1]
		local backend_name = args[2] -- Optional
		local ok, err = self.config:set_model(model_name, backend_name)
		if not ok then
			write_error("Error: " .. err)
			return 1
		end
		self:init_client()
		self:update_prompt()
		write_info("Model set to: " .. self.config:get_model())
	else
		write_line("Current model: " .. (self.config:get_model() or "not set"))
		write_line("Current backend: " .. (self.config:get_backend() or "not set"))
	end
	return 0
end

slash_commands["/backend"] = function(self, args)
	if args and #args > 0 then
		local backend_name = args[1]
		local ok, err = self.config:set_backend(backend_name)
		if not ok then
			write_error("Error: " .. err)
			return 1
		end
		self:init_client()
		self:update_prompt()
		write_info("Backend set to: " .. backend_name .. ", model: " .. self.config:get_model())
	else
		write_line("Current backend: " .. (self.config:get_backend() or "not set"))
		write_line("Available backends: " .. table.concat(self.config:list_backends(), ", "))
	end
	return 0
end

slash_commands["/models"] = function(self, args)
	write_line("Available backends:")
	for _, name in ipairs(self.config:list_backends()) do
		local bc = self.config:get_backend_config(name)
		local marker = (name == self.config:get_backend()) and " *" or ""
		write_line("  " .. name .. marker .. " (default model: " .. (bc.default_model or "?") .. ")")
	end
	return 0
end

slash_commands["/tools"] = function(self, args)
	write_line("Available tools:")
	for _, name in ipairs(self.tools_list) do
		local tool_config = self.config:get_tool_config(name)
		local approval = tool_config.approval or "auto"
		write_line("  " .. name .. " [" .. approval .. "]")
	end
	return 0
end

slash_commands["/tokens"] = function(self, args)
	local tokens = self.conversation:tokens()
	local max_tokens = self.config:get_max_tokens()
	local percentage = math.floor((tokens / max_tokens) * 100)
	write_line("Token usage: " .. tokens .. " / " .. max_tokens .. " (" .. percentage .. "%)")
	write_line("Messages: " .. self.conversation:count())
	return 0
end

slash_commands["/save"] = function(self, args)
	local name = args and args[1]
	if not name then
		write_error("Usage: /save <name>")
		return 1
	end
	local filepath, err = self.conversation:save(name)
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
	local ok, err = self.conversation:load(name)
	if not ok then
		write_error("Error: " .. err)
		return 1
	end
	self:update_prompt()
	write_info("Loaded conversation: " .. name .. " (" .. self.conversation:count() .. " messages)")
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
		self.config:set_system_prompt(new_prompt)
		self.conversation:set_system_prompt(new_prompt)
		write_info("System prompt updated.")
	else
		local prompt = self.conversation:get_system_prompt()
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
	write_line("  Backend: " .. self.config:get_backend())
	write_line("  Model: " .. self.config:get_model())
	local sampler = self.config:get_sampler()
	write_line("  Temperature: " .. (sampler.temperature or "default"))
	write_line("  Max tokens: " .. (sampler.max_new_tokens or "default"))
	write_line("  Context limit: " .. self.config:get_max_tokens())
	return 0
end

slash_commands["/cost"] = function(self, args)
	local pricing = require("llm.pricing")
	local cost_data = self.conversation:get_cost()

	write_line("Session cost breakdown:")
	write_line("  Requests:      " .. cost_data.request_count)
	write_line("  Input tokens:  " .. cost_data.input_tokens)
	write_line("  Output tokens: " .. cost_data.output_tokens)
	if cost_data.cached_tokens > 0 then
		write_line("  Cached tokens: " .. cost_data.cached_tokens)
	end
	write_line("  Total cost:    " .. pricing.format_cost(cost_data.total_cost))

	-- Show if model has known pricing
	local model = self.config:get_model()
	local model_price = pricing.get_price(model)
	if not model_price then
		write_info("  (Note: No pricing data for model '" .. model .. "')")
	elseif pricing.is_free(model) then
		write_info("  (Model '" .. model .. "' is free)")
	end

	return 0
end

slash_commands["/debug"] = function(self, args)
	self._debug = not self._debug
	if self._debug then
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
	local backend = self.config:get_backend()
	local backend_config = self.config:get_backend_config()
	local model = self.config:get_model()

	-- Get API key from environment variable specified in config
	local api_key_env = backend_config.api_key_env
	local api_key = api_key_env and os.getenv(api_key_env)

	-- For Zen, we need to route to correct endpoint based on model's api_style
	if backend == "zen" then
		local model_config = self.config:get_model_config(model)
		local api_style = model_config and model_config.api_style or "oaic"
		local base_url = backend_config.url

		if api_style == "anthropic" then
			-- Use anthropic client with Zen URL (anthropic.lua adds /messages internally)
			self.client = llm.new("anthropic", base_url, api_key)
		else
			-- Use oaic client with Zen URL (oaic.lua appends /chat/completions internally)
			-- NOTE: When /responses endpoint support is added, this will need to change
			self.client = llm.new("oaic", base_url, api_key)
		end
		-- Store the effective api_style for tool loop
		self._api_style = api_style
	else
		-- For non-Zen backends, use api_style to determine client type
		local api_style = backend_config.api_style or backend
		if api_style == "oaic" then
			self.client = llm.new("oaic", backend_config.url, api_key)
		elseif api_style == "anthropic" then
			self.client = llm.new("anthropic", backend_config.url, api_key)
		else
			-- Native backend (llamacpp native, etc)
			self.client = llm.new(backend, backend_config.url, api_key)
		end
		self._api_style = api_style
	end
end

-- Update prompt with current state
local function update_prompt(self)
	if self.input.prompt then
		self.input:prompt_set({
			model = self.config:get_model(),
			backend = self.config:get_backend(),
			tokens = self.conversation:tokens(),
			max_tokens = self.config:get_max_tokens(),
			cost = self.conversation:get_total_cost(),
			status = nil,
		})
	end
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
	if self._debug then
		write_debug("args", format_debug_table(args))
	end

	-- Check if approval is needed
	if not self.config:tool_needs_approval(tool_name) then
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
		self.config:set_session_approval(tool_name, "auto")
		return { action = "allow" }
	else
		-- "yes" or any other input = allow
		return { action = "allow" }
	end
end

-- Tool result handler for debug output
local function on_tool_result(self, call, result, is_error)
	if not self._debug then
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
	self.conversation:add_user(user_input)

	-- Update prompt to show streaming status
	if self.input.prompt then
		self.input:prompt_set({ status = "streaming" })
	end

	-- Get messages for LLM
	local messages = self.conversation:get_messages()
	local sampler = self.config:get_sampler()
	local model = self.config:get_model()

	-- Use the api_style determined during init_client
	local style = self._api_style or "oaic"

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

	-- Run tool loop with streaming
	local resp, err = llm_tools.loop(self.client, model, messages, sampler, {
		tools = self.tools_list,
		tool_objects = llm_tools.get_descriptions(self.tools_list),
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
	if self.input.prompt then
		self.input:prompt_set({ status = false })
	end

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
	self.conversation:add_usage(model, input_tokens, output_tokens, 0)

	-- Ensure stream is flushed
	stream:flush()

	-- Handle aborted response (user denied tool execution)
	if resp.aborted then
		-- Add assistant's partial response to conversation (if any text)
		if resp.text and #resp.text > 0 then
			self.conversation:add_assistant(resp.text, nil)
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
	self.conversation:add_assistant(resp.text, resp.tool_calls)

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
	local input = self.input:get_content()

	-- Handle empty input
	if not input or input:match("^%s*$") then
		return 0
	end

	-- Handle slash commands
	local cmd, args = parse_slash_command(input)
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
	return process_response(self, input)
end

-- Constructor
local function new(input)
	local mode = {
		input = input,
		combos = {
			-- TODO: Add key combos
			-- ["ALT+c"] = clear_conversation_combo,
			-- ["ALT+m"] = switch_model_combo,
		},
		config = config_mod.new(),
		conversation = nil,
		client = nil,
		tools_list = {},
		_debug = false, -- Debug mode toggle

		-- Methods
		init_client = init_client,
		update_prompt = update_prompt,
		run = run,
	}

	-- Initialize client
	mode:init_client()

	-- Get list of available tools
	mode.tools_list = {
		"read_file",
		"write_file",
		"edit_file",
		"bash",
		"web_search",
		"fetch_webpage",
	}

	-- Initialize conversation with system prompt
	local system_prompt = mode.config:get_system_prompt() or system_prompt_mod.get()
	mode.conversation = conversation_mod.new(system_prompt)

	-- Update prompt with initial state
	mode:update_prompt()

	return mode
end

return { new = new }
