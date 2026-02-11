# Agent Smith

Agent Smith is the built-in TUI coding agent mode in Lilush Shell. It provides
an interactive LLM-powered coding assistant with streaming markdown output,
tool use with configurable approval workflows, multi-provider support,
conversation management, and cost tracking.

Activate with `F3` from the shell. The agent runs in the terminal alongside
the normal shell — switch back with `F1`.

## Configuration

Config file: `~/.config/lilush/agent.json`

All fields are optional. Unset fields fall back to built-in defaults.

### Top-Level Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `provider` | string | `"openrouter"` | Active provider name (must exist in `providers`) |
| `model` | string | `"openai/gpt-5.2-codex"` | Active model (must be available on the active provider) |
| `providers` | object | _(see below)_ | Provider registry |
| `sampler` | object | _(see below)_ | Sampler settings |
| `tools` | object | _(see below)_ | Per-tool approval settings |
| `active_prompt` | string\|null | `null` | Active user prompt filename |
| `index_file` | string | `"INDEX.md"` | Project context file loaded from cwd |
| `max_tool_steps` | number | `100` | Max tool call iterations per request |

### Provider Entry

Each key in `providers` is a provider name. Required fields:

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | Provider kind: `"openrouter"` or `"llamacpp"` |
| `url` | string | API base URL (e.g. `"https://openrouter.ai/api/v1"`) |
| `api_key_env` | string | Environment variable holding the API key |
| `default_model` | string | Model to use when switching to this provider |

### Sampler

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_new_tokens` | number | `32768` | Maximum tokens for model output |

### Tool Approval

Each key in `tools` is a tool name with an object containing `approval`:

| Value | Behavior |
|-------|----------|
| `"ask"` | Prompt before execution |
| `"auto"` | Execute without prompting |

Defaults: `bash`, `write`, `edit` → `"ask"`; `read`, `web_search`, `fetch_webpage` → `"auto"`.

### Default Config

```json
{
  "provider": "openrouter",
  "model": "openai/gpt-5.2-codex",
  "providers": {
    "openrouter": {
      "kind": "openrouter",
      "url": "https://openrouter.ai/api/v1",
      "api_key_env": "OPENROUTER_API_KEY",
      "default_model": "openai/gpt-5.2-codex"
    }
  },
  "sampler": {
    "max_new_tokens": 32768
  },
  "tools": {
    "bash":          { "approval": "ask" },
    "write":         { "approval": "ask" },
    "edit":          { "approval": "ask" },
    "read":          { "approval": "auto" },
    "web_search":    { "approval": "auto" },
    "fetch_webpage": { "approval": "auto" }
  },
  "index_file": "INDEX.md",
  "max_tool_steps": 100
}
```

### Environment Variables

| Variable | Usage |
|----------|-------|
| `OPENROUTER_API_KEY` | API key for OpenRouter providers |
| `OPENROUTER_API_URL` | Override OpenRouter base URL (fallback when `url` is empty) |
| `LLM_API_KEY` | API key for llama.cpp providers |
| `LLM_API_TIMEOUT` | HTTP timeout in seconds for provider requests (default: 600) |
| `LINKUP_API_TOKEN` | API key for web search (LinkUp.so) |
| `EDITOR` | External editor for tool argument editing (default: `vi`) |

## Providers

Agent Smith uses an OpenAI-compatible chat completions API (`/chat/completions`).
Two provider kinds are supported.

### `openrouter`

Connects to [OpenRouter](https://openrouter.ai) or any OpenAI-compatible API.

- Model discovery via `/models` endpoint
- Filters models to text-in/text-out only (images, audio models are excluded)
- Reads pricing (prompt/completion per token) and context window from the API
- Auth: `Authorization: Bearer $OPENROUTER_API_KEY`

### `llamacpp`

Connects to a local [llama.cpp](https://github.com/ggerganov/llama.cpp) server.

- Model discovery via `/models` (note: not `/v1/models`)
- Reads context window from `--ctx-size` in the model's status args
- Reports model loaded/unloaded state
- No pricing (local inference)
- Auth: `Authorization: Bearer $LLM_API_KEY` (if set)

### Adding Providers

Add entries to `providers` in `agent.json`. Example with a local llama.cpp server:

```json
{
  "providers": {
    "openrouter": {
      "kind": "openrouter",
      "url": "https://openrouter.ai/api/v1",
      "api_key_env": "OPENROUTER_API_KEY",
      "default_model": "openai/gpt-5.2-codex"
    },
    "local": {
      "kind": "llamacpp",
      "url": "http://localhost:8080/v1",
      "api_key_env": "LLM_API_KEY",
      "default_model": "my-model"
    }
  }
}
```

Switch at runtime with `/provider local`.

## Tools

### Available Tools

| Tool | Parameters | Description |
|------|-----------|-------------|
| `read` | `filepath` (required), `offset`, `limit` | Read file contents. Default limit 1000 lines. |
| `write` | `filepath` (required), `content` (required) | Write content to file. Creates parent dirs. Overwrites existing. |
| `edit` | `filepath` (required), `old_text` (required), `new_text` (required) | Replace exact text in file. Must match uniquely. |
| `bash` | `command` (required) | Execute shell command. Output truncated at 10K chars per stream. |
| `fetch_webpage` | `url` (required) | Fetch webpage as plain text (via `elinks -dump`). |
| `web_search` | `query` (required) | Search the web via LinkUp.so API. Returns sources and answer. |

### Approval Flow

When a tool has `approval: "ask"`, the agent displays:

```
[tool_name] detail
[tool_name] Execute? [Y/n/e/m/a]
```

Actions:

| Key | Action |
|-----|--------|
| `Y` / Enter | Execute the tool call |
| `n` | Deny — stop the tool loop, wait for next input |
| `e` | Edit arguments in `$EDITOR`, then execute with modified args |
| `m` | Deny with message — provide feedback that continues the conversation |
| `a` | Auto-approve this tool for the rest of the session |

Session overrides from `a` are cleared on `/clear`.

## Slash Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands and keybinds |
| `/clear` | Clear conversation history and reset session approvals |
| `/model [name] [provider]` | Show or set current model (optionally on a different provider) |
| `/provider [name]` | Show or set current provider |
| `/provider refresh [name]` | Refresh discovered model catalog for a provider |
| `/models` | List all providers and their discovered models with pricing/context info |
| `/tools` | List available tools with their approval settings |
| `/tokens` | Show token usage (session total, last/peak context) |
| `/cost` | Show session cost breakdown (requests, tokens, total cost) |
| `/save <name>` | Save conversation to file |
| `/load [name]` | Load conversation from file (no arg lists saved conversations) |
| `/list` | List saved conversations with message counts and timestamps |
| `/conversation` | Show current conversation in a markdown pager |
| `/prompt` | Show active user prompt and index file status |
| `/prompt list` | List available user prompts |
| `/prompt set <name>` | Activate a user prompt |
| `/prompt clear` | Deactivate user prompt |
| `/prompt show` | Show the full assembled system prompt in a pager |
| `/config` | Show current configuration (provider, model, pricing, sampler, prompt) |

All slash commands support tab completion.

### Keybinds

| Key | Action |
|-----|--------|
| `ALT+h` | Show current conversation in markdown pager |

## System Prompt & Project Context

The system prompt is assembled fresh on every turn from these components:

1. **Preamble** — fixed introduction identifying the agent and its capabilities
2. **Environment block** — dynamically generated: current time, working directory
3. **Tools section** — descriptions of all available tools
4. **Guidelines** — behavioral guidelines for the agent
5. **User prompt** (optional) — loaded from `~/.config/lilush/agent/prompts/<name>` when `active_prompt` is set
6. **Project context** (optional) — contents of `INDEX.md` (or the file specified by `index_file`) in the current working directory

### User Prompts

Store prompt files in `~/.config/lilush/agent/prompts/`. Manage with:

- `/prompt list` — list available prompts
- `/prompt set <name>` — activate a prompt
- `/prompt clear` — deactivate
- `/prompt show` — view the full assembled prompt

The active prompt persists across `/clear` but is not saved to config until
the next config save.

### Project Context

Place an `INDEX.md` (or custom filename via `index_file` config) in your project
root. Its contents are appended to the system prompt under a `## Project Context`
heading. Use this to give the agent project-specific instructions, file layout,
conventions, etc.

## Conversation Management

### Message Types

Conversations consist of four message types following the OpenAI chat format:

| Role | Description |
|------|-------------|
| `system` | System prompt (not stored in message list, set separately) |
| `user` | User input |
| `assistant` | Model response (may include tool calls) |
| `tool` | Tool execution result (linked to a tool call by ID) |

### Context Window Tracking

The agent tracks context usage from API responses:

- **Last context** — tokens used in the most recent request
- **Peak context** — highest context usage in the session
- **Usage percentage** — `last_ctx_tokens / context_window * 100`

### Auto-Trimming

When context usage reaches **90%**, the agent automatically trims the oldest
turns (up to 3 per response cycle). If only 2 or fewer messages remain after
trimming, a warning suggests using `/clear`.

Before sending a request, if context is at **95%** and the conversation has
2 or fewer messages, the request is refused.

### Old Tool Result Truncation

When sending messages to the API, tool results from older turns are replaced
with compact stubs containing only `name`, `ok`, and `error` (if any).
The last **4 user turns** are kept fully intact.

### Save / Load

Conversations are saved to `~/.local/share/lilush/agent/conversations/` as JSON
files. The filename is derived from the conversation name (non-alphanumeric
characters replaced with `_`).

- `/save <name>` — save current conversation
- `/load <name>` — load a saved conversation
- `/list` — list saved conversations sorted by last update time

## Streaming & Display

### Markdown Pipeline

LLM output is streamed through a real-time markdown rendering pipeline:

1. Text chunks arrive from the API via streaming SSE
2. Chunks are fed into the markdown parser incrementally
3. Parser events drive the streaming renderer
4. Rendered output is written to the terminal as it arrives

The pipeline handles tool call interruptions gracefully — when a tool call
arrives mid-stream, the renderer checkpoints its state, the tool approval
and execution is displayed, and streaming resumes on the next model turn.

A "thinking" indicator (animated spinner) is shown while the model sends
reasoning tokens before visible output begins.

### Prompt Format

The agent prompt displays:

```
[Smith:model] ~/path 1.2k 45% $0.03 ▸
```

Components:
- `Smith` (or active prompt name) — mode label
- `model` — short model name
- `~/path` — current working directory
- `1.2k 45%` — context tokens and usage percentage
- `$0.03` — session cost
- `▸` — cursor

### Token Usage Coloring

| Usage | Style |
|-------|-------|
| Below 70% | Normal |
| 70%–90% | Warning |
| Above 90% | Critical |

## Cancellation

Press `Ctrl+C` during streaming to cancel the current request. The partial
response is preserved in conversation history. The agent returns to the
input prompt.

## Source Files

| File | Description |
|------|-------------|
| `src/agent/agent/mode/agent.lua` | Main agent mode |
| `src/agent/agent/config.lua` | Configuration management |
| `src/agent/agent/conversation.lua` | Conversation history and cost tracking |
| `src/agent/agent/conversation_markdown.lua` | Markdown formatter for pager |
| `src/agent/agent/stream.lua` | Streaming markdown bridge |
| `src/agent/agent/system_prompt.lua` | System prompt assembly |
| `src/agent/agent/mode/agent.prompt.lua` | Prompt display |
| `src/agent/agent/completion/slash.lua` | Slash command tab completion |
| `src/llm/llm/tools.lua` | Tool registry and execution |
| `src/llm/llm/tools/*.lua` | Individual tool implementations |
