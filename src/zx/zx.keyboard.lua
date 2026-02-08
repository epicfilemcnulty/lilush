-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
    ZX Spectrum Keyboard Mapping

    The ZX Spectrum has a 40-key keyboard organized into 8 half-rows
    of 5 keys each, read via port 0xFE. Each half-row is selected by
    one of the high address lines (active low).

    This module maps terminal key events from Kitty keyboard protocol
    to the ZX Spectrum keyboard matrix.

    Keyboard layout:

    Row 0 (0xFEFE): CAPS SHIFT, Z, X, C, V
    Row 1 (0xFDFE): A, S, D, F, G
    Row 2 (0xFBFE): Q, W, E, R, T
    Row 3 (0xF7FE): 1, 2, 3, 4, 5
    Row 4 (0xEFFE): 0, 9, 8, 7, 6
    Row 5 (0xDFFE): P, O, I, U, Y
    Row 6 (0xBFFE): ENTER, L, K, J, H
    Row 7 (0x7FFE): SPACE, SYMBOL SHIFT, M, N, B
]]

local M = {}

local bit = require("bit")

-- Key to row/bit mapping (shared, read-only)
-- Format: { row, bit } where bit 0 is rightmost in the half-row
local KEY_MAP = {
	-- Row 0: CAPS SHIFT, Z, X, C, V
	["CAPS_SHIFT"] = { 0, 0 },
	["z"] = { 0, 1 },
	["x"] = { 0, 2 },
	["c"] = { 0, 3 },
	["v"] = { 0, 4 },

	-- Row 1: A, S, D, F, G
	["a"] = { 1, 0 },
	["s"] = { 1, 1 },
	["d"] = { 1, 2 },
	["f"] = { 1, 3 },
	["g"] = { 1, 4 },

	-- Row 2: Q, W, E, R, T
	["q"] = { 2, 0 },
	["w"] = { 2, 1 },
	["e"] = { 2, 2 },
	["r"] = { 2, 3 },
	["t"] = { 2, 4 },

	-- Row 3: 1, 2, 3, 4, 5
	["1"] = { 3, 0 },
	["2"] = { 3, 1 },
	["3"] = { 3, 2 },
	["4"] = { 3, 3 },
	["5"] = { 3, 4 },

	-- Row 4: 0, 9, 8, 7, 6
	["0"] = { 4, 0 },
	["9"] = { 4, 1 },
	["8"] = { 4, 2 },
	["7"] = { 4, 3 },
	["6"] = { 4, 4 },

	-- Row 5: P, O, I, U, Y
	["p"] = { 5, 0 },
	["o"] = { 5, 1 },
	["i"] = { 5, 2 },
	["u"] = { 5, 3 },
	["y"] = { 5, 4 },

	-- Row 6: ENTER, L, K, J, H
	["ENTER"] = { 6, 0 },
	["l"] = { 6, 1 },
	["k"] = { 6, 2 },
	["j"] = { 6, 3 },
	["h"] = { 6, 4 },

	-- Row 7: SPACE, SYMBOL SHIFT, M, N, B
	[" "] = { 7, 0 },
	["SYMBOL_SHIFT"] = { 7, 1 },
	["m"] = { 7, 2 },
	["n"] = { 7, 3 },
	["b"] = { 7, 4 },
}

-- Alias common terminal key names to ZX keys (shared, read-only)
local KEY_ALIASES = {
	-- Letters (lowercase handled, add uppercase as CAPS+letter)
	["Z"] = { "CAPS_SHIFT", "z" },
	["X"] = { "CAPS_SHIFT", "x" },
	["C"] = { "CAPS_SHIFT", "c" },
	["V"] = { "CAPS_SHIFT", "v" },
	["A"] = { "CAPS_SHIFT", "a" },
	["S"] = { "CAPS_SHIFT", "s" },
	["D"] = { "CAPS_SHIFT", "d" },
	["F"] = { "CAPS_SHIFT", "f" },
	["G"] = { "CAPS_SHIFT", "g" },
	["Q"] = { "CAPS_SHIFT", "q" },
	["W"] = { "CAPS_SHIFT", "w" },
	["E"] = { "CAPS_SHIFT", "e" },
	["R"] = { "CAPS_SHIFT", "r" },
	["T"] = { "CAPS_SHIFT", "t" },
	["P"] = { "CAPS_SHIFT", "p" },
	["O"] = { "CAPS_SHIFT", "o" },
	["I"] = { "CAPS_SHIFT", "i" },
	["U"] = { "CAPS_SHIFT", "u" },
	["Y"] = { "CAPS_SHIFT", "y" },
	["L"] = { "CAPS_SHIFT", "l" },
	["K"] = { "CAPS_SHIFT", "k" },
	["J"] = { "CAPS_SHIFT", "j" },
	["H"] = { "CAPS_SHIFT", "h" },
	["M"] = { "CAPS_SHIFT", "m" },
	["N"] = { "CAPS_SHIFT", "n" },
	["B"] = { "CAPS_SHIFT", "b" },

	-- Special keys
	["LEFT_SHIFT"] = { "CAPS_SHIFT" },
	["RIGHT_SHIFT"] = { "CAPS_SHIFT" },
	["SHIFT"] = { "CAPS_SHIFT" },
	["LEFT_CTRL"] = { "SYMBOL_SHIFT" },
	["RIGHT_CTRL"] = { "SYMBOL_SHIFT" },
	["LEFT_ALT"] = { "SYMBOL_SHIFT" },
	["RIGHT_ALT"] = { "SYMBOL_SHIFT" },

	-- Arrow keys (CAPS + 5/6/7/8)
	["LEFT"] = { "CAPS_SHIFT", "5" },
	["DOWN"] = { "CAPS_SHIFT", "6" },
	["UP"] = { "CAPS_SHIFT", "7" },
	["RIGHT"] = { "CAPS_SHIFT", "8" },

	-- Other common mappings
	["BACKSPACE"] = { "CAPS_SHIFT", "0" }, -- DELETE on ZX
	["TAB"] = { "CAPS_SHIFT", " " }, -- BREAK
}

-- Keyboard class
local Keyboard = {}
Keyboard.__index = Keyboard

-- Create a new keyboard instance
function M.new()
	local self = setmetatable({
		pressed_keys = {},
		active = {}, -- id -> entry { zx_keys = {...}, ids = {...} }
	}, Keyboard)
	return self
end

local function _key_ids(cp, shifted, base)
	local out = {}
	local seen = {}
	local function add(v)
		if v and not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
	-- Prefer base as the most stable physical identifier, but keep fallbacks.
	add(base)
	add(cp)
	add(shifted)
	return out
end

local function _add_unique(out, seen, key_name)
	if not seen[key_name] then
		seen[key_name] = true
		out[#out + 1] = key_name
	end
end

-- Expand a single terminal event into ZX key names to press/release.
-- mods_mask is a bitmask using term.lua ordering (SHIFT=1, ALT=2, CTRL=4, ...).
local function expand_to_zx_keys(cp, mods_mask, shifted, base)
	local out = {}
	local seen = {}

	-- Treat held modifiers as separate matrix keys.
	if mods_mask and bit.band(mods_mask, 1) ~= 0 then
		_add_unique(out, seen, "CAPS_SHIFT")
	end
	if mods_mask and (bit.band(mods_mask, 2) ~= 0 or bit.band(mods_mask, 4) ~= 0) then
		_add_unique(out, seen, "SYMBOL_SHIFT")
	end

	local key = base or cp
	if not key then
		return out
	end

	-- Prefer explicit aliases first.
	local alias = KEY_ALIASES[key]
	if alias then
		for _, k in ipairs(alias) do
			_add_unique(out, seen, k)
		end
		return out
	end

	-- Direct mapping.
	if KEY_MAP[key] then
		_add_unique(out, seen, key)
		return out
	end

	-- Character keys: normalize to lowercase.
	if KEY_MAP[key:lower()] then
		_add_unique(out, seen, key:lower())
	end

	return out
end

-- Press a ZX key (internal method)
function Keyboard:_press_key(key_name, core)
	local mapping = KEY_MAP[key_name]
	if mapping then
		core:key_down(mapping[1], mapping[2])
		self.pressed_keys[key_name] = true
	end
end

-- Release a ZX key (internal method)
function Keyboard:_release_key(key_name, core)
	local mapping = KEY_MAP[key_name]
	if mapping then
		core:key_up(mapping[1], mapping[2])
		self.pressed_keys[key_name] = nil
	end
end

-- Release all keys
function Keyboard:release_all(core)
	for key_name, _ in pairs(self.pressed_keys) do
		self:_release_key(key_name, core)
	end
	self.active = {}
end

function Keyboard:tick(_now)
	-- No-op for now. Kept for API symmetry with other input handlers.
end

-- Handle a key event from the terminal
function Keyboard:handle_key(key, core)
	if not key then
		return
	end

	-- Parse modifier+key format
	local keys_to_press = {}

	-- Check for SHIFT+ prefix (indicates shift was held)
	if key:match("^SHIFT%+") then
		table.insert(keys_to_press, "CAPS_SHIFT")
		key = key:gsub("^SHIFT%+", "")
	end

	-- Check for CTRL+ prefix (map to symbol shift)
	if key:match("^CTRL%+") then
		table.insert(keys_to_press, "SYMBOL_SHIFT")
		key = key:gsub("^CTRL%+", "")
	end

	-- Check for ALT+ prefix (map to symbol shift)
	if key:match("^ALT%+") then
		table.insert(keys_to_press, "SYMBOL_SHIFT")
		key = key:gsub("^ALT%+", "")
	end

	-- Check if this key has an alias expansion
	local alias = KEY_ALIASES[key]
	if alias then
		for _, k in ipairs(alias) do
			table.insert(keys_to_press, k)
		end
	elseif KEY_MAP[key] then
		table.insert(keys_to_press, key)
	elseif KEY_MAP[key:lower()] then
		table.insert(keys_to_press, key:lower())
	end

	-- Press all the keys
	for _, k in ipairs(keys_to_press) do
		self:_press_key(k, core)
	end
end

-- Handle key release event
function Keyboard:handle_key_up(key, core)
	if not key then
		return
	end

	-- Similar parsing to handle_key but call release instead
	if key:match("^SHIFT%+") then
		self:_release_key("CAPS_SHIFT", core)
		key = key:gsub("^SHIFT%+", "")
	end

	if key:match("^CTRL%+") or key:match("^ALT%+") then
		self:_release_key("SYMBOL_SHIFT", core)
		key = key:gsub("^CTRL%+", ""):gsub("^ALT%+", "")
	end

	local alias = KEY_ALIASES[key]
	if alias then
		for _, k in ipairs(alias) do
			self:_release_key(k, core)
		end
	elseif KEY_MAP[key] then
		self:_release_key(key, core)
	elseif KEY_MAP[key:lower()] then
		self:_release_key(key:lower(), core)
	end
end

-- Handle a raw kkbp event coming from term.get().
-- This avoids stringifying modifiers and makes key up/down matching robust.
function Keyboard:handle_term_event(cp, mods_mask, event, shifted, base, core)
	if not cp or not event then
		return
	end

	local ids = _key_ids(cp, shifted, base)
	if #ids == 0 then
		return
	end

	if event == 3 then
		local entry
		for i = 1, #ids do
			entry = self.active[ids[i]]
			if entry then
				break
			end
		end
		if not entry then
			return
		end
		for i = 1, #entry.zx_keys do
			self:_release_key(entry.zx_keys[i], core)
		end
		for i = 1, #entry.ids do
			self.active[entry.ids[i]] = nil
		end
		return
	end

	-- Press/repeat: only press if this physical key isn't already active.
	for i = 1, #ids do
		if self.active[ids[i]] then
			return
		end
	end

	local zx_keys = expand_to_zx_keys(cp, mods_mask or 0, shifted, base)
	if #zx_keys == 0 then
		return
	end

	for i = 1, #zx_keys do
		self:_press_key(zx_keys[i], core)
	end
	local entry = { zx_keys = zx_keys, ids = ids }
	for i = 1, #ids do
		self.active[ids[i]] = entry
	end
end

-- Get current state of all keys (for debugging)
function Keyboard:get_pressed()
	local result = {}
	for k, _ in pairs(self.pressed_keys) do
		table.insert(result, k)
	end
	return result
end

return M
