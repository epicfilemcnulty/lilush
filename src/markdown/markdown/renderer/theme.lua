-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Default theme for markdown renderers.

Provides shared styling constants used by both static and streaming renderers.
These can be overridden by passing a custom `tss` option to renderer.new().
]]

-- Default border configuration for code blocks and divs
local DEFAULT_BORDERS = {
	align = "none",
	indent = 0,
	fg = 59,
	clip = -1,
	top_line = { before = "╭", content = "─", after = "╮", fill = true, clip = -1 },
	bottom_line = { before = "╰", content = "─", after = "╯", fill = true, clip = -1 },
	subtitle_line = { before = "├", content = "─", after = "┤", fill = true, clip = -1 },
	v = { content = "│", w = 1, clip = -1 },
}

-- Helper to create colored border variant
local make_colored_borders = function(fg)
	return {
		align = "none",
		indent = 0,
		fg = fg,
		clip = -1,
		top_line = { before = "╭", content = "─", after = "╮", fill = true, clip = -1 },
		bottom_line = { before = "╰", content = "─", after = "╯", fill = true, clip = -1 },
		subtitle_line = { before = "├", content = "─", after = "┤", fill = true, clip = -1 },
		v = { content = "│", w = 1, clip = -1 },
	}
end

-- Default table borders
local DEFAULT_TABLE_BORDERS = {
	top_left = "┌",
	top = "─",
	top_mid = "┬",
	top_right = "┐",
	left = "│",
	mid = "│",
	right = "│",
	mid_left = "├",
	mid_mid = "┼",
	mid_right = "┤",
	bottom_left = "└",
	bottom = "─",
	bottom_mid = "┴",
	bottom_right = "┘",
	fg = 59,
	clip = -1,
}

-- Default raw style sheet for markdown rendering
local DEFAULT_RSS = {
	wrap = 80,
	global_indent = 0,
	fg = 250,

	heading = {
		s = "bold",
		fg = { 177, 140, 169 },
		h1 = { ts = "double", before = "⁜ " },
		h2 = { ts = { s = 2, n = 6, d = 9, w = 2, v = 2, h = 0 }, before = "⁜⁜ " },
		h3 = { ts = { s = 2, n = 9, d = 14, w = 2, v = 2, h = 0 }, before = "⁜⁜⁜ " },
		h4 = { before = "⁜⁜⁜⁜ " },
		h5 = { before = "⁜⁜⁜⁜⁜ " },
		h6 = { before = "⁜⁜⁜⁜⁜⁜ " },
	},

	code_block = {
		pad = 1,
		border = DEFAULT_BORDERS,
		fg = { 150, 180, 150 },
		lang = { s = "italic,bold", before = "⧼ ", after = " ⧽", bg = { 38, 64, 38 }, fg = { 105, 137, 105 } },
	},

	para = {}, -- Inherits base fg

	strong = { s = "bold", fg = 180 },
	emph = { s = "italic", fg = 180 },
	code = {
		fg = 249, -- Base inline code style
		tbl = { fg = 136, s = "italic" },
		num = { fg = 145 },
		str = { fg = 144 },
		bool = { fg = 146 },
		opt = { fg = 110 },
		arg = { fg = 108 },
		flag = { fg = 111, s = "bold" },
		meta = { fg = 247, s = "italic" },
		neg = { fg = 167 },
		multi = { fg = 179 },
		fn = { before = "ʄ(", after = ")", fg = 175 },
		file = { before = "Ⓕ ", fg = 152 },
		dir = { before = "Ⓓ ", fg = 153 },
		status = { fg = "cyan", s = "italic" },
		def = { s = "dim" },
		req = { s = "bold" },
	},
	strikethrough = { s = "strikethrough", fg = 245 }, -- GFM strikethrough

	link = {
		title = { s = "underlined", fg = 67 },
		url = { fg = { 129, 161, 193 }, s = "dim", before = " (", after = ")", clip = 0, w = 0.2 },
	},

	image = {
		alt = { s = "italic", before = "[img: ", after = "]" },
		url = { s = "dim", before = " (", after = ")" },
	},

	thematic_break = {
		w = 0.5,
		align = "center",
		content = "⁓",
		fill = true,
		fg = 59,
	},

	-- List styles
	list = {
		indent_per_level = 4,
	},

	list_item = {
		-- Unordered list marker (uses TSS content property)
		ul = {
			content = "⦁ ",
			fg = 110,
		},
		-- Ordered list marker (number is dynamic, style applied to formatted string)
		ol = {
			fg = 245,
		},
	},

	-- Task list styles (GFM)
	task_list = {
		checked = { content = "❨❩ ", fg = 107 },
		unchecked = { content = "❨ ❩ ", fg = 245 },
	},

	-- Table styles (GFM)
	table = {
		-- block_indent = 1, -- applies to full rendered table lines
		overflow = "wrap", -- wrap (default) or clip
		border = DEFAULT_TABLE_BORDERS,
		header = { s = "bold", fg = 180, align = "center" },
		cell = { fg = 250 },
	},

	footnote_ref = { ts = "superscript", s = "bold", fg = 67 },
	footnotes = {
		separator = { fg = 59 },
	},
	footnote = {
		marker = { s = "bold", fg = 67 },
		content = { fg = 245 },
	},

	-- Divs use bordered boxes like code_block, with class name displayed as label
	div = {
		default = {
			align = "left",
			w = 0.7,
			pad = 1, -- Left padding inside the box
			border = DEFAULT_BORDERS,
			fg = 250,
			label = { s = "italic,bold", before = "⧼ ", after = " ⧽", fg = 59, w = 0 },
		},
		warning = {
			align = "center",
			fg = 214,
			border = make_colored_borders(214),
			label = { s = "italic,bold", before = "⧼ ", after = " ⧽", bg = { 64, 48, 28 }, fg = 214 },
		},
		note = {
			fg = 109,
			border = make_colored_borders(109),
			label = { s = "italic,bold", before = "⧼ ", after = " ⧽", bg = { 38, 48, 58 }, fg = 109 },
		},
		tip = {
			fg = 107,
			border = make_colored_borders(107),
			label = { s = "italic,bold", before = "⧼ ", after = " ⧽", bg = { 38, 58, 38 }, fg = 107 },
		},
		caution = {
			fg = 167,
			border = make_colored_borders(167),
			label = { s = "italic,bold", before = "⧼ ", after = " ⧽", bg = { 58, 38, 38 }, fg = 167 },
		},
	},

	-- Blockquote styles (left bar style)
	blockquote = {
		fg = 245,
		indent = 0,
		bar = { content = "┃ ", fg = 67 }, -- Vertical bar on left
	},
}

-- Scoped override to disable clipping inside paragraphs so inline styles
-- (bold, italic, links, …) don't get clipped by a parent width constraint.
local PARAGRAPH_NO_CLIP_RSS = {
	para = { clip = -1, w = 0 },
	strong = { clip = -1, w = 0 },
	emph = { clip = -1, w = 0 },
	strikethrough = { clip = -1, w = 0 },
	code = { clip = -1, w = 0 },
	link = {
		title = { clip = -1, w = 0 },
		url = { clip = -1, w = 0 },
	},
	image = {
		alt = { clip = -1, w = 0 },
		url = { clip = -1, w = 0 },
	},
}

return {
	DEFAULT_BORDERS = DEFAULT_BORDERS,
	DEFAULT_TABLE_BORDERS = DEFAULT_TABLE_BORDERS,
	DEFAULT_RSS = DEFAULT_RSS,
	PARAGRAPH_NO_CLIP_RSS = PARAGRAPH_NO_CLIP_RSS,
}
