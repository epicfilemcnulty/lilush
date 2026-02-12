-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local term = require("term")
local unpack = table.unpack or unpack

local pack = function(...)
	return { n = select("#", ...), ... }
end

local run_with_state = function(enter_fn, leave_fn, handler)
	enter_fn()
	local result = pack(xpcall(function()
		return handler()
	end, debug.traceback))
	leave_fn()
	if not result[1] then
		error(result[2], 0)
	end
	return unpack(result, 2, result.n)
end

local enter_exec_mode = function(opts)
	local cfg = opts or {}
	term.disable_kkbp()
	term.disable_bracketed_paste()
	if cfg.newline then
		term.write("\r\n")
	end
	term.set_sane_mode()
end

local leave_exec_mode = function()
	term.set_raw_mode()
	term.enable_kkbp()
	term.enable_bracketed_paste()
end

local run_in_sane_mode = function(handler)
	return run_with_state(function()
		enter_exec_mode()
	end, leave_exec_mode, handler)
end

local run_in_raw_passthrough_mode = function(handler)
	return run_with_state(function()
		term.disable_kkbp()
		term.disable_bracketed_paste()
		term.set_raw_mode()
	end, function()
		term.set_sane_mode()
	end, handler)
end

return {
	enter_exec_mode = enter_exec_mode,
	leave_exec_mode = leave_exec_mode,
	run_in_sane_mode = run_in_sane_mode,
	run_in_raw_passthrough_mode = run_in_raw_passthrough_mode,
}
