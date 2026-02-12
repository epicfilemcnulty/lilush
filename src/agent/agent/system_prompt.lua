-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Default system prompt for the coding agent.
Largely inspired by https://mariozechner.at/posts/2025-11-30-pi-coding-agent/
]]

local std = require("std")
local buffer = require("string.buffer")

local preamble = [[
You are Agent Smith, an expert coding assistant running in a terminal environment.
You help users with coding tasks by reading files, executing commands, 
editing code, and writing new files.

]]

local env = [[
## Environment

OS: Linux
Current time: %s
Current working dir: %s

]]

local tools = [[
## Available Tools

### read
Read the contents of a file. Defaults to first 1000 lines. 
Use offset/limit for large files. 
- `filepath` (required): Path to the file to read (relative or absolute)
- `offset`: Line number to start reading from (1-indexed, default: 1)
- `limit`: Maximum number of lines to read (default: 1000)

### write
Write content to file. Creates the file if it does not exist,
overwrites if it does. Automatically creates parent directories.
- `filepath` (required): Path to the file to write (relative or absolute)
- `content` (required): Content to write to the file

### edit
Edit a file by replacing exact text. The `old_text` must match exactly
(including whitespace). Use this for precise, surgical edits.
- `filepath` (required): Path to the file to edit (relative or absolute)
- `old_text` (required): Exact text to find and replace (must match exactly)
- `new_text` (required): Replacement text

### bash
Execute a bash command in the current working directory. 
Returns stdout and stderr. Output truncated at 10K chars.
- `command` (required): Shell command to run

]]

--[[ Tool descriptions for web_search and fetch_webpage.
Not included in the default system prompt; enable via custom system prompt if needed.

### fetch_webpage
Fetch webpage content as plain text.
- `url` (required): URL to fetch

### web_search
Search the web.
- `query` (required): Search query
]]

local guidelines = [[
## Guidelines

- Read files before editing to understand context
- Use `edit` for precise changes, `write` for new files or complete rewrites
- Use `bash` for everything else: 
  file operations (`ls`, `find`); git info (`git status`, `git diff`), etc.
- Always assume clean state, no backwards compatible shims
- Be concise in responses
- Show file paths clearly when working with files

]]

-- Build the environment block with current context
local function env_block()
	local cwd = std.fs.cwd() or "unknown"
	local time = os.date("%Y-%m-%d %H:%M:%S")
	return string.format(env, time, cwd)
end

-- Build the tools + guidelines block
local function tools_block()
	return tools .. guidelines
end

-- Generate the system prompt with current context
local function get()
	local prompt = buffer.new()
	prompt:put(preamble)
	prompt:put(env_block())
	prompt:put(tools, guidelines)
	return prompt:get()
end

-- Append user instructions and project context sections
local function append_extras(prompt, user_prompt_content, index_content)
	if user_prompt_content and user_prompt_content ~= "" then
		prompt:put("\n## User Instructions\n\n")
		prompt:put(user_prompt_content)
		prompt:put("\n\n")
	end
	if index_content and index_content ~= "" then
		prompt:put("\n## Project Context\n\n")
		prompt:put(index_content)
		prompt:put("\n\n")
	end
end

local function assemble(user_prompt_content, index_content)
	local prompt = buffer.new()
	prompt:put(get())
	append_extras(prompt, user_prompt_content, index_content)
	return prompt:get()
end

-- Escape replacement string for gsub (% is special in replacements)
local function gsub_literal(s, pattern, replacement)
	return s:gsub(pattern, replacement:gsub("%%", "%%%%"))
end

-- Expand {{ ENV }} and {{ TOOLS }} placeholders in a custom template
local function expand_template(template)
	local result = gsub_literal(template, "{{%s*ENV%s*}}", env_block())
	result = gsub_literal(result, "{{%s*TOOLS%s*}}", tools_block())
	return result
end

-- Assemble a custom system prompt from a user-provided template
local function assemble_custom(custom_template, user_prompt_content, index_content)
	local prompt = buffer.new()
	prompt:put(expand_template(custom_template))
	append_extras(prompt, user_prompt_content, index_content)
	return prompt:get()
end

return {
	get = get,
	assemble = assemble,
	expand_template = expand_template,
	assemble_custom = assemble_custom,
}
