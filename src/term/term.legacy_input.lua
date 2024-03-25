-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")

local legacy_codes = {
	key_codes = {
		[1] = "Ctrl+A",
		[2] = "Ctrl+B", -- Start of Text
		[3] = "Ctrl+C", -- End of Text
		[4] = "Ctrl+D", -- EOT, End of Transmission
		[5] = "Ctrl+E",
		[6] = "Ctrl+F",
		[7] = "Ctrl+G", -- Bell! Bell!
		[8] = "Ctrl+H", -- Ctrl+Backspace -- same code
		[9] = "Tab", -- Also Ctrl+I
		[10] = "Ctrl+J", -- line feed, LF, \n
		[11] = "Ctrl+K",
		[12] = "Ctrl+L",
		[13] = "Enter", -- Carriage return, \r, also Ctrl+M
		[14] = "Ctrl+N",
		[15] = "Ctrl+O",
		[16] = "Ctrl+P",
		[17] = "Ctrl+Q",
		[18] = "Ctrl+R",
		[19] = "Ctrl+S",
		[20] = "Ctrl+T",
		[21] = "Ctrl+U",
		[22] = "Ctrl+V",
		[23] = "Ctrl+W",
		[24] = "Ctrl+X",
		[25] = "Ctrl+Y",
		[26] = "Ctrl+Z",
		[127] = "Backspace",
	},
	esc_seqs = {
		["[A"] = "Up",
		["[B"] = "Down",
		["[C"] = "Right",
		["[D"] = "Left",
		["[H"] = "Home",
		["[F"] = "End",
		["[5~"] = "PageUp",
		["[6~"] = "PageDown",
		["[2~"] = "Insert",
		["[3~"] = "Del",
		["[1;5D"] = "Ctrl+Left",
		["[1;5C"] = "Ctrl+Right",
		["[1;5A"] = "Ctrl+Up",
		["[1;5B"] = "Ctrl+Down",
		["[1;3D"] = "Alt+Left",
		["[1;3C"] = "Alt+Right",
		["[1;3A"] = "Alt+Up",
		["[1;3B"] = "Alt+Down",
		["OP"] = "F1",
		["OQ"] = "F2",
		["OR"] = "F3",
		["OS"] = "F4",
		["[15~"] = "F5",
		["[17~"] = "F6",
		["[18~"] = "F7",
		["[19~"] = "F8",
		["[20~"] = "F9",
		["[21~"] = "F10",
		["[23~"] = "F11",
		["[24~"] = "F12",
		["a"] = "Alt+A",
		["b"] = "Alt+B",
		["c"] = "Alt+C",
		["d"] = "Alt+D",
		["e"] = "Alt+E",
		["f"] = "Alt+F",
		["g"] = "Alt+G",
		["h"] = "Alt+H",
		["i"] = "Alt+I",
		["k"] = "Alt+K",
		["l"] = "Alt+L",
		["m"] = "Alt+M",
		["n"] = "Alt+N",
		["o"] = "Alt+O",
		["p"] = "Alt+P",
		["q"] = "Alt+Q",
		["r"] = "Alt+R",
		["s"] = "Alt+S",
		["t"] = "Alt+T",
		["u"] = "Alt+U",
		["v"] = "Alt+V",
		["w"] = "Alt+W",
		["x"] = "Alt+X",
		["y"] = "Alt+Y",
		["z"] = "Alt+Z",
		["."] = "Alt+.",
		[","] = "Alt+,",
		["/"] = "Alt+/",
		["A"] = "Alt+Shift+A",
		["B"] = "Alt+Shift+B",
		["C"] = "Alt+Shift+C",
		["D"] = "Alt+Shift+D",
		["E"] = "Alt+Shift+E",
		["F"] = "Alt+Shift+F",
		["G"] = "Alt+Shift+G",
		["H"] = "Alt+Shift+H",
		["I"] = "Alt+Shift+I",
		["K"] = "Alt+Shift+K",
		["L"] = "Alt+Shift+L",
		["M"] = "Alt+Shift+M",
		["N"] = "Alt+Shift+N",
		["O"] = "Alt+Shift+O",
		["P"] = "Alt+Shift+P",
		["Q"] = "Alt+Shift+Q",
		["R"] = "Alt+Shift+R",
		["S"] = "Alt+Shift+S",
		["T"] = "Alt+Shift+T",
		["U"] = "Alt+Shift+U",
		["V"] = "Alt+Shift+V",
		["W"] = "Alt+Shift+W",
		["X"] = "Alt+Shift+X",
		["Y"] = "Alt+Shift+Y",
		["Z"] = "Alt+Shift+Z",
	},
}

local legacy_get = function()
	local code = io.read(1)
	if code then
		if string.byte(code) == 27 then
			local seq = {}
			repeat
				local c = io.read(1)
				if c then
					table.insert(seq, c)
				end
			until not c
			if #seq == 0 then
				return "Esc"
			end
			local s = table.concat(seq)
			if legacy_codes.esc_seqs[s] then
				return legacy_codes.esc_seqs[s]
			end
			if s == "\r" then
				return "Alt+Enter"
			end
			return "~" .. s
		end
		if legacy_codes.key_codes[string.byte(code)] then
			return legacy_codes.key_codes[string.byte(code)]
		end
		if std.utf.valid_b1(code) then
			local suffix = io.read(std.utf.byte_count(code)) or ""
			if std.utf.valid_seq(code .. suffix) then
				return code .. suffix
			else
				return std.utf.replacement_symbol
			end
		end
	end
	return code
end

return { get = legacy_get }
