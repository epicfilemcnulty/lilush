-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local storage = require("shell.store")

local widgets_default = {
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

local renderer_default = {
	builtin_error = {
		global_indent = -1,
		wrap = -1,
		fg = 245,
		verbatim = { fg = 95, bg = 233, s = "bold" },
		class = {
			flag = { s = "inverted,bold" },
		},
	},
	kat = {
		hide_links = true,
		verbatim = { fg = { 130, 160, 130 }, s = "bold" },
		header = { fg = { 177, 140, 169 }, s = "bold", level = { fg = 181, content = "⁜" } },
		codeblock = {
			indent = 1,
			fg = { 150, 180, 150 },
			lang = { bg = { 38, 64, 38 }, fg = { 105, 137, 105 } },
		},
		emph = { fg = 180 },
		strong = { fg = 180 },
		link = {
			title = { fg = { 177, 140, 169 } },
			url = { fg = { 129, 161, 193 }, w = 0.2 },
		},
		list = {
			definition = { suffix = { fg = 185 }, term = { fg = 81 }, def = {} },
			fg = 110,
		},
		tbl = {
			border = { fg = 59, s = "dim" },
		},
		thematic_break = { fg = 137 },
		class = {
			tbl = { fg = 136 },
			str = { fg = 144 },
			num = { fg = 145 },
			bool = { fg = 146 },
			fn = { fg = 175 },
			file = { fg = 152 },
			dir = { fg = 153 },
		},
	},
}

local builtins_default = {
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
		value = { fg = 246, indent = 4 },
	},
	cat = {
		line_num = { fg = 246 },
	},
	envlist = {
		var = { fg = 248, s = "bold", align = "left" },
		value = { fg = 246, indent = 4 },
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
			indent = 4,
			name = { fg = 101, s = "bold", after = " " },
			pub_key = { indent = 0, fg = 102, s = "italic" },
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
		status_line = {
			bg = 31,
			fg = { 38, 62, 38 },
			filename = { after = " ※ " },
			total_lines = { after = " ※ " },
			size = { after = " ※ " },
			position = { fg = { 30, 54, 30 } },
			search = {
				input = { bg = 31, fg = { 38, 62, 38 }, s = "bold,inverted" },
				pattern = { before = "/", s = "bold" },
			},
			render_mode = { after = " ※ ", before = " ※ " },
		},
	},
}

local prompts_default = {
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
			logo = { fg = 176, s = "dim", content = "🔒" },
			profile = { fg = 99, s = "bold" },
		},
		dir = { fg = 251, w = 25, clip = 3 },
	},
}

local modes_default = {
	shell = {
		completion = { fg = 247 },
	},
	llm = {},
	lua = {
		sep = { fg = 67, s = "bold", content = "-", fill = true, w = 0.4 },
	},
}

local completion_default = {
	fg = 247,
	builtin = { fg = 31 },
	fs_exe = { fg = { 180, 142, 173 } },
	bin = { fg = 247, s = "bold" },
	env = { s = "bold" },
	history = { indent = 4, fg = 65, s = "bold,italic" },
	dir_history = { indent = 4, fg = 246, s = "bold,italic" },
	snippet = { indent = 4, fg = 29, s = "bold" },
}

local load_user_theme = function()
	local store = storage.new()
	local widgets = store:get_json_file("theme/widgets.json")
	if widgets then
		std.tbl.merge(widgets_default, widgets)
	end
	local renderer = store:get_json_file("theme/renderer.json")
	if renderer then
		std.tbl.merge(renderer_default, renderer)
	end
	local builtins = store:get_json_file("theme/builtins.json")
	if builtins then
		std.tbl.merge(builtins_default, builtins)
	end
	local prompts = store:get_json_file("theme/prompts.json")
	if prompts then
		std.tbl.merge(prompts_default, prompts)
	end
	local modes = store:get_json_file("theme/modes.json")
	if modes then
		std.tbl.merge(modes_default, modes)
	end
	local completion = store:get_json_file("theme/completion.json")
	if completion then
		std.tbl.merge(completion_default, completion)
	end
	store:close(true)
	local theme = {
		widgets = widgets_default,
		renderer = renderer_default,
		builtins = builtins_default,
		prompts = prompts_default,
		modes = modes_default,
		completion = completion_default,
	}
	return theme
end

return load_user_theme()
