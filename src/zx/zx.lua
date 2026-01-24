-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
    ZX Spectrum Emulator for Lilush

    Supports ZX Spectrum 48K, 128K, and +2 machines.

    This module provides an object-oriented interface for running
    ZX Spectrum programs and games in a Kitty-compatible terminal.

    Usage:
        local zx = require("zx")
        local emu = zx.new({ machine = "128k" })
        emu:load_rom("/path/to/rom")
        emu:run("/path/to/game.tap")  -- Run a TAP file (blocking)
]]

local std = require("std")
local core = require("zx.core")
local keyboard = require("zx.keyboard")
local screen = require("zx.screen")
local term = require("term")
local socket = require("socket")
local bit = require("bit")

-- Default configuration
local default_config = {
	scale = 2, -- Screen scale factor (1-4)
	frame_skip = 0, -- Number of frames to skip between renders
	rom_path = "", -- Path to ZX Spectrum ROM
	audio_enabled = true, -- Enable audio output
	audio_device = "auto", -- "auto", card number (0, 1, ...), or /dev/snd/pcmC1D0p
	machine = "48k", -- Machine type: "48k", "128k", or "plus2"
	-- Tape loading options
	tape_turbo = true, -- Enable turbo tape loading (faster, but no border stripes)
	tape_turbo_frames = 4, -- Extra frames per real frame during turbo loading
	tape_sound = true, -- Emulate tape loading sound (muted in turbo mode)
}

-- Load ROM into the emulator
local load_rom = function(self, rom_path)
	local data, err = std.fs.read_file(rom_path)
	if not data then
		return nil, "Failed to read ROM: " .. (err or "unknown error")
	end

	return self.emu:load_rom(data)
end

-- Main emulator loop (blocking)
local run = function(self, filepath)
	if not self.emu then
		return nil, "Emulator not initialized"
	end

	local cfg = self.config
	local kb = self.keyboard
	local scr = self.screen
	local paused = false

	if cfg.rom_path and cfg.rom_path ~= "" then
		local ok, rom_err = self:load_rom(cfg.rom_path)
		if not ok then
			self:close()
			return nil, rom_err
		end
	end

	local loaded_snapshot = false
	if self.emu.set_tape_audio then
		self.emu:set_tape_audio(cfg.tape_sound and not cfg.tape_turbo)
	end
	if filepath then
		local ext = filepath:match("%.(%w+)$")
		if ext then
			ext = ext:lower()
		end
		if ext == "tap" then
			local tap_data, tap_err = std.fs.read_file(filepath)
			if not tap_data then
				self:close()
				return nil, "Failed to read TAP file: " .. (tap_err or "unknown error")
			end
			local ok, load_err = self.emu:load_tap(tap_data)
			if not ok then
				self:close()
				return nil, load_err or "Failed to load TAP"
			end
		elseif ext == "tzx" then
			local tzx_data, tzx_err = std.fs.read_file(filepath)
			if not tzx_data then
				self:close()
				return nil, "Failed to read TZX file: " .. (tzx_err or "unknown error")
			end
			local ok, load_err = self.emu:load_tzx(tzx_data)
			if not ok then
				self:close()
				return nil, load_err or "Failed to load TZX"
			end
		elseif ext == "z80" then
			local z80_data, z80_err = std.fs.read_file(filepath)
			if not z80_data then
				self:close()
				return nil, "Failed to read Z80 snapshot: " .. (z80_err or "unknown error")
			end
			local ok, load_err = self.emu:load_z80(z80_data)
			if not ok then
				self:close()
				return nil, load_err or "Failed to load Z80 snapshot"
			end
			loaded_snapshot = true
		end
	end
	if not loaded_snapshot then
		self.emu:reset()
	end

	local audio_active = false
	if self.audio_module then
		local ok, rate, buf_size, period_size = self.audio_module.init(44100, cfg.audio_device)
		if ok then
			audio_active = true
		else
			-- Ensure audio_module is nil on failure to prevent further calls
			self.audio_module = nil
		end
	end

	local alt = term.alt_screen()
	term.clear()

	local win_w, win_h, cell_w, cell_h = term.get_pixel_dimensions(100)
	if not win_w then
		local term_rows, term_cols = term.window_size()
		cell_w, cell_h = 10, 20
		win_w = term_cols * cell_w
		win_h = term_rows * cell_h
	end

	local full_width = screen.FULL_WIDTH * cfg.scale
	local full_height = screen.FULL_HEIGHT * cfg.scale

	local border_left_px = screen.BORDER_LEFT * cfg.scale
	local border_top_px = screen.BORDER_TOP * cfg.scale

	local frame_px_x = math.floor((win_w - full_width) / 2)
	local frame_px_y = math.floor((win_h - full_height) / 2)
	frame_px_x = math.max(0, frame_px_x)
	frame_px_y = math.max(0, frame_px_y)

	local main_px_x = frame_px_x + border_left_px
	local main_px_y = frame_px_y + border_top_px

	local frame_col = math.floor(frame_px_x / cell_w) + 1
	local frame_row = math.floor(frame_px_y / cell_h) + 1
	local main_col = math.floor(main_px_x / cell_w) + 1
	local main_row = math.floor(main_px_y / cell_h) + 1

	local frame_offset_x = frame_px_x % cell_w
	local frame_offset_y = frame_px_y % cell_h
	local main_offset_x = main_px_x % cell_w
	local main_offset_y = main_px_y % cell_h

	local emu_frames = 0
	local next_tick = socket.gettime()
	local frame_time = 1 / 50
	local last_fps_log = socket.gettime()
	local fps_smooth = 0
	local frame_count = 0
	local no_render_frames = 0
	local skip_count = 0
	local last_time = socket.gettime()
	local fps = 0

	while self.running do
		local now0 = socket.gettime()

		while core.poll_stdin(0) do
			local cp, mods, event, shifted, base = term.get()
			if cp then
				local mods_mask = (mods or 1) - 1
				local key_id = base or cp

				if event == 3 then
					kb:handle_term_event(cp, mods_mask, event, shifted, base, self.emu)
				else
					if event == 1 then
						if cp == "ESC" or (bit.band(mods_mask, 4) ~= 0 and (key_id == "c" or key_id == "q")) then
							self.running = false
							break
						elseif cp == "F1" then
							self.emu:reset()
							next_tick = socket.gettime() + frame_time
						elseif cp == "F2" then
							paused = not paused
							next_tick = socket.gettime() + frame_time
						elseif cp == "F3" then
							local data = self.emu:get_screen()
							if data then
								local name = string.format("zxscr_%d.SCR", os.time())
								std.fs.write_file(name, data)
							end
						elseif cp == "F4" then
							if self.emu.save_z80 then
								local snap, snap_err = self.emu:save_z80()
								if snap then
									local name = string.format("zxsnap_%d.Z80", os.time())
									std.fs.write_file(name, snap)
								end
							end
						elseif cp == "F8" then
							cfg.tape_turbo = not cfg.tape_turbo
							if self.emu.set_tape_audio then
								self.emu:set_tape_audio(cfg.tape_sound and not cfg.tape_turbo)
							end
						elseif cp == "F9" then
							local tape_regs = self.emu:get_registers()
							local playing = (tape_regs.tape_playing == 1)
							self.emu:tape_play(not playing)
						elseif cp == "F10" then
							self.emu:tape_rewind()
						else
							kb:handle_term_event(cp, mods_mask, event, shifted, base, self.emu)
						end
					else
						kb:handle_term_event(cp, mods_mask, event, shifted, base, self.emu)
					end
				end
			end
		end
		kb:tick(now0)

		if not self.running then
			break
		end

		if paused then
			core.poll_stdin(10)
		else
			while socket.gettime() < next_tick do
				core.poll_stdin(1)
			end

			local screen_dirty = self.emu:run_frame()
			emu_frames = emu_frames + 1
			next_tick = next_tick + frame_time

			if audio_active and self.audio_module then
				local samples = self.emu:get_audio_samples()
				if samples and #samples > 0 then
					self.audio_module.write(samples)
				end
			end

			local now1 = socket.gettime()
			if now1 > next_tick then
				local behind = math.floor((now1 - next_tick) / frame_time)
				local catchup = math.min(behind, 5)
				for _ = 1, catchup do
					self.emu:run_frame()
					emu_frames = emu_frames + 1
					next_tick = next_tick + frame_time
					if audio_active and self.audio_module then
						local samples = self.emu:get_audio_samples()
						if samples and #samples > 0 then
							self.audio_module.write(samples)
						end
					end
				end
				if (now1 - next_tick) > 0.25 then
					next_tick = now1
				end
			end

			local regs = self.emu:get_registers()
			local tape_playing = (regs.tape_playing == 1)

			if cfg.tape_turbo and tape_playing then
				for _ = 1, cfg.tape_turbo_frames do
					self.emu:run_frame()
					emu_frames = emu_frames + 1
				end
			end

			local render_every = 1
			if fps_smooth < 45 then
				render_every = 2
			end
			if fps_smooth < 30 then
				render_every = 3
			end

			no_render_frames = no_render_frames + 1
			local do_render = screen_dirty or (no_render_frames >= 10)
			if render_every > 1 and (frame_count % render_every) ~= 0 then
				do_render = false
			end

			if do_render and skip_count == 0 then
				no_render_frames = 0
				local scr_data = self.emu:get_screen()

				local border_lines = self.emu:get_border_lines()
				local show_border_stripes = tape_playing and border_lines and not cfg.tape_turbo

				if show_border_stripes then
					term.go(frame_row, frame_col)
					scr:render_with_border(scr_data, border_lines, cfg.scale, true, frame_offset_x, frame_offset_y)
				else
					term.go(main_row, main_col)
					scr:render_fast(scr_data, cfg.scale, main_offset_x, main_offset_y)
				end
			end

			frame_count = frame_count + 1
			local now = socket.gettime()
			if now - last_time >= 1.0 then
				fps = emu_frames
				fps_smooth = fps_smooth * 0.8 + fps * 0.2
				emu_frames = 0
				frame_count = 0
				last_time = now
			end
			skip_count = (skip_count + 1) % (cfg.frame_skip + 1)
		end
	end

	if audio_active and self.audio_module then
		self.audio_module.close()
	end
	alt:done()
	self:close()
	return true
end

-- Peek memory
local peek = function(self, addr)
	return self.emu:peek(addr)
end

-- Poke memory
local poke = function(self, addr, value)
	return self.emu:poke(addr, value)
end

-- Get CPU registers
local get_registers = function(self)
	return self.emu:get_registers()
end

-- Get current machine type
local get_machine_type = function(self)
	return self.emu:get_machine_type()
end

-- Get AY-3-8912 register state (128k only, returns nil for 48k)
local get_ay_registers = function(self)
	return self.emu:get_ay_registers()
end

-- Get memory banking state (for debugging 128k issues)
local get_banking_state = function(self)
	return self.emu:get_banking_state()
end

-- Close the emulator and cleanup resources
local close = function(self)
	if self.emu then
		self.emu:close()
		self.emu = nil
	end
	if self.audio_module then
		self.audio_module.close()
		self.audio_module = nil
	end
end

local new = function(config)
	local self = {}

	self.config = {}
	for k, v in pairs(default_config) do
		if config[k] == nil then
			self.config[k] = v
		else
			self.config[k] = config[k]
		end
	end
	if self.config.audio_enabled then
		-- Audio module (optional - may fail if ALSA not available)
		local audio_ok, audio_module = pcall(require, "zx.audio")
		if audio_ok then
			self.audio_module = audio_module
		end
	end
	self.emu = core.new(self.config.machine)
	self.keyboard = keyboard.new()
	self.screen = screen.new()
	self.running = true

	self.load_rom = load_rom
	self.run = run
	self.close = close
	self.peek = peek
	self.poke = poke
	self.get_ay_registers = get_ay_registers
	self.get_registers = get_registers
	self.get_machine_type = get_machine_type
	self.get_banking_state = get_banking_state
	return self
end

return { new = new }
