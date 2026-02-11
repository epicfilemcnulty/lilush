-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local json = require("cjson.safe")

local widget_default = {
	aws = {
		title = { fg = 94, bg = 184 },
		option = { fg = 100 },
		borders = { fg = 65 },
	},
	llm = {
		fg = 103,
		borders = { fg = 109 },
		title = { fg = 220, bg = 99 },
		option = { fg = 103 },
		file = { directory = { fg = 105 } },
	},
	python = {
		title = { fg = 27, bg = 223 },
		option = { fg = 179, selected = { fg = 185, s = "bold" } },
		borders = { fg = 94 },
	},
	shell = {
		fg = 67,
		borders = { fg = 69 },
		option = { fg = 67, marked = { fg = 96 } },
		title = { fg = 137 },
	},
}

local errors_default = {
	-- builtin_markdown is used for markdown-formatted error messages in shell
	builtin_markdown = {
		fg = 238,
		code = { fg = 95, bg = 233, s = "bold" },
		strong = { s = "inverted,bold" },
	},
}

local builtin_default = {
	err = { fg = 245 },
	ls = {
		offset = { fg = 243 },
		user = { fg = 246 },
		group = { fg = 247 },
		atime = { fg = 65 },
		perms = { fg = 242 },
		size = { fg = 244, s = "bold" },
		dir = { fg = "blue", s = "bold", before = "ⓓ " },
		file = { fg = 251, before = "ⓕ " },
		target = { fg = 111 },
		link = { fg = "cyan", before = "ⓛ " },
		socket = { fg = "magenta", before = "ⓢ " },
		block = { fg = "yellow", before = "ⓑ " },
		pipe = { fg = "red", before = "ⓟ " },
		char = { fg = 101, before = "ⓒ " },
		unknown = { fg = 95, before = "ⓤ " },
		exec = { fg = "green", s = "bold", before = " " },
	},
	alias = {
		name = { fg = 247, s = "bold", align = "right" },
		value = { fg = 246, text_indent = 4 },
	},
	cat = {
		line_num = { fg = 246 },
	},
	envlist = {
		var = { fg = 248, s = "bold", align = "left" },
		value = { fg = 246, text_indent = 4 },
	},
	dig = {
		name = { fg = 144, s = "bold" },
		_in = { fg = 245 },
		_type = { fg = 137 },
		content = { fg = 109 },
		ttl = { fg = 143 },
		ns = { fg = 242, s = "bold" },
		ns_type = { fg = 245 },
		query = { fg = 242 },
		answer = { fg = 245 },
		domain = { fg = 249, s = "bold" },
		root_ns = { fg = 245, s = "inverted" },
		tld = { fg = 246, s = "inverted" },
		tld_ns = { fg = 247, s = "bold" },
		rtype = { s = "bold" },
		domain_ns = { fg = 248, s = "bold" },
	},
	netstat = {
		src = { fg = 244 },
		dst = { fg = 246 },
		state = { fg = 249 },
		user = { fg = 243 },
	},
	history = {
		date = { fg = 101, after = " " },
		time = { fg = 102, before = "[", after = "] " },
		duration = {},
		status = {},
		cmd = { ok = { fg = 249 }, fail = { fg = 95, s = "bold" } },
	},
	wg = {
		net = {
			name = { fg = 107, s = "bold", after = " " },
			pub_key = { fg = 102, s = "italic" },
		},
		endpoint = {
			text_indent = 4,
			name = { fg = 101, s = "bold", after = " " },
			pub_key = { text_indent = 0, fg = 102, s = "italic" },
			bytes = { fg = 104 },
			seen = { fg = 103 },
			nets = {
				s = "dim,bold",
				fg = 105,
			},
		},
	},
	pager = {
		line_num = { fg = 60, selected = { s = "bold,inverted" } },
		search_match = { fg = { 38, 62, 38 }, bg = 31, s = "italic,bold" },
		element = {
			focused = { fg = 220, s = "bold" },
		},
		status_line = {
			fg = "cyan",
			filename = { after = " ※ " },
			total_lines = { after = " ※ " },
			size = { after = " ※ " },
			position = { s = "bold,italic" },
			search = {
				input = { bg = 31, fg = { 38, 62, 38 }, s = "bold,inverted" },
				pattern = { before = "/", s = "bold" },
			},
			render_mode = { after = " ※ ", before = " ※ " },
			url = { fg = 67 },
			hint = { fg = 111, s = "italic", before = " ※ " },
			codeblock = { fg = 60, lang = { before = " [", fg = 62, after = "]" } },
			notification = { fg = 98, s = "italic" },
		},
	},
}

local prompt_default = {
	llm = {
		chat = { fg = 67 },
		backend = { fg = 37, s = "bold" },
		preset = { fg = 37, s = "bold", before = "", after = "" },
		model = { fg = 158, before = "", after = "" },
		embedding = { fg = 39, before = "Ⓔ " },
		endpoint = { fg = 159, chat = { content = " " }, complete = { content = " " } },
		prompt = { fg = 109, before = "⁜", after = "⁜" },
		temperature = { fg = 146, before = "" },
		ctx = { fg = 157, before = "" },
		tokens = { fg = 142, before = "" },
		rate = { fg = 143, before = "" },
		total_cost = { fg = 144, before = " " },
	},
	lua = {
		logo = { fg = "blue", s = "bold", content = "" },
	},
	shell = {
		sep = { fg = 102 },
		git = {
			logo = { fg = 60, s = "bold", content = " " },
			branch = {
				w = 15,
				clean = { fg = 34 },
				dirty = { fg = 179 },
			},
			modified = { fg = 214, before = "←" },
			staged = { fg = 35, before = "←" },
			untracked = { fg = 95, before = "…" },
			ahead = { fg = 71, before = "↑⬝" },
			behind = { fg = 184, before = "↓⬝" },
			remote = { fg = 33 },
			tag = { fg = 106, w = 20, clip = 5 },
			tag_sep = { fg = 58, content = "@" },
		},
		aws = {
			logo = { fg = 180, s = "bold", content = " " },
			profile = { fg = 100, before = "" },
			region = { fg = 106, before = "" },
		},
		user = {
			user = { fg = "green" },
			root = { fg = "red" },
			hostname = { fg = "yellow" },
		},
		kube = {
			logo = { fg = 182, s = "bold", content = " " },
			profile = { fg = 175, before = "" },
			ns = { fg = 176, before = "" },
		},
		vault = {
			unlocked = { fg = 210, s = "bold", content = " " },
			locked = { fg = 70, s = "bold", content = " " },
			unknown = { fg = 59, s = "bold", content = " " },
			error = { fg = 124, s = "bold", content = " " },
		},
		python = {
			logo = { fg = 222, content = " ", s = "bold" },
			env = { fg = 39, s = "bold,dim", bg = { 0, 65, 140 } },
		},
		ssh = {
			logo = { fg = 176, s = "dim", content = " " },
			profile = { fg = 99, s = "bold" },
		},
		dir = { fg = 251, w = 25, clip = 3 },
	},
}

local repl_default = {
	lua = {
		separator = { fg = 67, s = "bold", content = "-", fill = true, w = 0.4 },
	},
}

local completion_default = {
	fg = 247,
	builtin = { fg = 31 },
	fs_exe = { fg = { 180, 142, 173 } },
	bin = { fg = 247, s = "bold" },
	env = { s = "bold" },
	lua_keyword = { fg = 74, s = "bold" },
	lua_symbol = { fg = 111 },
	history = { text_indent = 4, fg = 65, s = "bold,italic" },
	dir_history = { text_indent = 4, fg = 246, s = "bold,italic" },
	snippet = { text_indent = 4, fg = 29, s = "bold" },
}

local agent_default = {
	agent = {
		error = { fg = 167 },
		info = { fg = 245 },
		thinking = { fg = 147 },

		tool = {
			bracket = { fg = 214 },
			name = { fg = 214 },
			args = { fg = 245 },
			result_prefix = { fg = 245, content = "  -> " },
			result = { fg = 245 },
		},

		debug = {
			bracket = { fg = 37 },
			label = { fg = 37 },
			text = { fg = 245 },
		},

		approval = {
			bracket = { fg = 214 },
			name = { fg = 214 },
			options = { fg = 245 },
		},

		code = {
			bar = { fg = 58, content = "│ " },
			lang = { fg = 109, s = "italic" },
			text = { fg = 247 },
		},
	},
	prompts = {
		agent = {
			sep = { fg = 243 },
			mode = {
				prefix = { fg = 99, content = "[" },
				suffix = { fg = 99, content = "]" },
				label = { fg = 147, s = "bold" },
				backend = { fg = 103 },
				model = { fg = 183 },
			},
			dir = { fg = 251, w = 30, clip = 3 },
			tokens = {
				prefix = { fg = 243, content = "(" },
				suffix = { fg = 243, content = ")" },
				count = { fg = 109 },
				unit = { fg = 243, content = " tok" },
				warning = { fg = 214 },
				critical = { fg = 196 },
			},
			cost = {
				prefix = { fg = 243, content = " " },
				amount = { fg = 113 },
			},
			status = {
				streaming = { fg = 220, content = "..." },
				thinking = { fg = 147, content = "..." },
				error = { fg = 196, content = "!" },
			},
			cursor = { fg = 147, content = "> " },
		},
	},
}

local defaults = {
	shell = {
		widget = widget_default,
		errors = errors_default,
		builtin = builtin_default,
		prompt = prompt_default,
		completion = completion_default,
		repl = repl_default,
	},
	markdown = {},
	agent = agent_default,
}

local load_json_file = function(path)
	local content, err = std.fs.read_file(path)
	if not content then
		return nil, err
	end
	local decoded, decode_err = json.decode(content)
	if not decoded then
		io.stderr:write("warning: failed to parse theme override `" .. path .. "`: " .. tostring(decode_err) .. "\n")
		return nil, decode_err
	end
	if type(decoded) ~= "table" then
		io.stderr:write("warning: invalid theme override `" .. path .. "`: root value must be an object\n")
		return nil, "invalid root"
	end
	return decoded
end

local load_user_overrides = function()
	local home = os.getenv("HOME") or "/tmp"
	local theme_dir = home .. "/.config/lilush/theme"
	local shell = load_json_file(theme_dir .. "/shell.json") or {}

	local markdown = load_json_file(theme_dir .. "/markdown.json") or {}
	local agent = load_json_file(theme_dir .. "/agent.json") or {}
	return {
		shell = shell,
		markdown = markdown,
		agent = agent,
	}
end

local user_overrides = load_user_overrides()

local get = function(section, extra_overrides)
	local key = section or ""
	local merged = std.tbl.copy(defaults[key] or {})
	merged = std.tbl.merge(merged, std.tbl.copy(user_overrides[key] or {}))
	if type(extra_overrides) == "table" then
		merged = std.tbl.merge(merged, extra_overrides)
	end
	return merged
end

return { get = get }
