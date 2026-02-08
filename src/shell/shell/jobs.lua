-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
    Simple in-memory job manager for PTY-backed background jobs.
    Each job runs on its own PTY; a logger child drains the PTY to a log file
    (or /dev/null) while detached so the job never blocks on output.

    Attaching temporarily stops the logger and streams PTY I/O to the terminal
    until the user detaches (Ctrl-]) or the job exits.
]]

local std = require("std")
local core = require("std.core")

--[[
   Default detach key is `Ctrl-]` which maps to ASCII GS (0x1D, decimal 29).

   To pick a different Ctrl key, use: code = string.byte("X") & 0x1F (Ctrl-X in this case)

   Override with LILUSH_JOB_DETACH_KEY (numeric ASCII code), e.g.
   `export LILUSH_JOB_DETACH_KEY=20` for `Ctrl-T`
]]
local detach_key = tonumber(os.getenv("LILUSH_JOB_DETACH_KEY")) or 29

local start_logger = function(master_fd, log_path)
	local pid = std.ps.fork()
	if pid < 0 then
		return nil, "failed to fork job logger"
	end
	if pid ~= 0 then
		return pid
	end
	local target = log_path or "/dev/null"
	local log_fd = core.open(target, 5)
	if not log_fd then
		os.exit(127)
	end
	while true do
		local chunk, err = core.read(master_fd, 4096)
		if not chunk or chunk == "" then
			break
		end
		core.write(log_fd, chunk, #chunk)
	end
	core.close(log_fd)
	core.close(master_fd)
	os.exit(0)
end

local start = function(self, cmd, args, opts)
	local launch_args = args or {}
	local launch_opts = opts or {}
	local pty, err = std.ps.pty_open()
	if not pty then
		return nil, err
	end

	local pid = std.ps.fork()
	if pid < 0 then
		return nil, "failed to fork"
	end
	if pid == 0 then
		std.ps.setsid()
		local slave_fd = core.open(pty.slave, 3)
		if not slave_fd then
			os.exit(127)
		end
		std.ps.tiocstty(slave_fd)
		std.ps.dup2(slave_fd, 0)
		std.ps.dup2(slave_fd, 1)
		std.ps.dup2(slave_fd, 2)
		if slave_fd > 2 then
			core.close(slave_fd)
		end
		core.close(pty.master)
		std.ps.exec(cmd, unpack(launch_args))
		os.exit(127)
	end

	local id = self.__state.next_id
	self.__state.next_id = self.__state.next_id + 1

	local log_path = "/tmp/" .. std.nanoid() .. ".log"
	if launch_opts.log == false then
		log_path = nil
	end
	local logger_pid = start_logger(pty.master, log_path)
	local entry = {
		id = id,
		pid = pid,
		cmd = cmd,
		args = launch_args,
		log_path = log_path,
		master = pty.master,
		logger_pid = logger_pid or 0,
		status = "running",
		started = os.time(),
	}
	self.__state.entries[id] = entry
	table.insert(self.__state.order, id)
	return entry
end

local poll = function(self)
	for _, id in ipairs(self.__state.order) do
		local job = self.__state.entries[id]
		if job and job.status == "running" then
			local ret, status = std.ps.waitpid(job.pid)
			if ret and ret > 0 then
				job.status = "exited"
				job.exit_status = status or 0
				job.finished = os.time()
				if job.master then
					core.close(job.master)
					job.master = nil
				end
				if job.logger_pid and job.logger_pid > 0 then
					std.ps.waitpid(job.logger_pid)
				end
			end
		end
	end
end

-- Remove all finished jobs from the job table
local reap = function(self)
	local new_order = {}
	for _, id in ipairs(self.__state.order) do
		local job = self.__state.entries[id]
		if job.status == "exited" then
			self.__state.entries[id] = nil
		else
			table.insert(new_order, id)
		end
	end
	self.__state.order = new_order
end

local list = function(self)
	local out = {}
	for _, id in ipairs(self.__state.order) do
		table.insert(out, self.__state.entries[id])
	end
	return out
end

local get = function(self, id)
	return self.__state.entries[id]
end

local kill = function(self, id, signal)
	local job = self.__state.entries[id]
	if not job then
		return nil, "no such job"
	end
	local kill_signal = tonumber(signal) or 15 -- SIGTERM by default
	local ok, err = std.ps.kill(job.pid, kill_signal)
	if not ok then
		return nil, err
	end
	return true
end

local attach = function(self, id)
	local job = self.__state.entries[id]
	if not job then
		return nil, "no such job"
	end
	if job.status ~= "running" then
		return nil, "job is not running"
	end
	if not job.master then
		return nil, "job is not attachable"
	end
	if job.logger_pid and job.logger_pid > 0 then
		std.ps.kill(job.logger_pid, 19)
	end
	std.ps.pty_attach(job.master, self.cfg.detach_key)
	if job.logger_pid and job.logger_pid > 0 then
		std.ps.kill(job.logger_pid, 18)
	end
	return true
end

local new = function(config)
	local cfg = config or {}
	if cfg.detach_key == nil then
		cfg.detach_key = detach_key
	end

	local jobs = {
		cfg = cfg,
		__state = {
			next_id = 1,
			entries = {},
			order = {},
		},
		start = start,
		list = list,
		get = get,
		kill = kill,
		attach = attach,
		poll = poll,
		reap = reap,
	}
	return jobs
end

return {
	new = new,
}
