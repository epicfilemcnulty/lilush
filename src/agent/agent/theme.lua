-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Agent theme - default styles for agent mode output and prompt.

This module provides hardcoded default styles for the agent.
Unlike shell.theme, it does not support user customization (yet).
]]

local theme = {
	-- Agent mode output styles (used by agent/mode/agent.lua)
	agent = {
		error = { fg = 167 },
		info = { fg = 245 },

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

	-- Prompt styles (used by agent/mode/agent.prompt.lua)
	prompts = {
		agent = {
			sep = { fg = 243 },
			mode = {
				prefix = { fg = 99, content = "[" },
				suffix = { fg = 99, content = "]" },
				label = { fg = 147, s = "bold", content = "agent" },
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

return theme
