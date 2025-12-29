-- SPDX-FileCopyrightText: © 2025 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

--[[
    Simple in-memory job manager for PTY-backed background jobs.
    Each job runs on its own PTY; a logger child drains the PTY to a log file
    (or /dev/null) while detached so the job never blocks on output.

    Attaching temporarily stops the logger and streams PTY I/O to the terminal
    until the user detaches (Ctrl-]) or the job exits.
]]

local std = require("std")
local core = require("std.core")

local jobs = {
	next_id = 1,
	entries = {},
	order = {},
}

--[[
   Default detach key is `Ctrl-]` which maps to ASCII GS (0x1D, decimal 29).

   To pick a different Ctrl key, use: code = string.byte("X") & 0x1F (Ctrl-X in this case)

   Override with LILUSH_JOB_DETACH_KEY (numeric ASCII code), e.g.
   `export LILUSH_JOB_DETACH_KEY=20` for `Ctrl-T`
]]
local detach_key = tonumber(os.getenv("LILUSH_JOB_DETACH_KEY") or "") or 29

local start_logger = function(master_fd, log_path)
	local pid = std.ps.fork()
	if pid < 0 then
		return nil, "failed to fork logger"
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

local start = function(cmd, args, opts)
	local args = args or {}
	local opts = opts or {}
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
		std.ps.exec(cmd, unpack(args))
		os.exit(127)
	end

	local id = jobs.next_id
	jobs.next_id = jobs.next_id + 1

	local log_path = "/tmp/lilush_job_" .. tostring(id) .. ".log"
	if opts.log == false then
		log_path = nil
	end
	local logger_pid = start_logger(pty.master, log_path)
	local entry = {
		id = id,
		pid = pid,
		cmd = cmd,
		args = args,
		log_path = log_path,
		master = pty.master,
		logger_pid = logger_pid or 0,
		status = "running",
		started = os.time(),
	}
	jobs.entries[id] = entry
	table.insert(jobs.order, id)
	return entry
end

local reap = function()
	local new_order = {}
	for _, id in ipairs(jobs.order) do
		local job = jobs.entries[id]
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
				jobs.entries[id] = nil
			else
				table.insert(new_order, id)
			end
		elseif job then
			jobs.entries[id] = nil
		end
	end
	jobs.order = new_order
end

local list = function()
	reap()
	local out = {}
	for _, id in ipairs(jobs.order) do
		table.insert(out, jobs.entries[id])
	end
	return out
end

local get = function(id)
	return jobs.entries[id]
end

local kill = function(id, signal)
	local job = jobs.entries[id]
	if not job then
		return nil, "no such job"
	end
	local signal = signal or 15
	local ok, err = std.ps.kill(job.pid, signal)
	if not ok then
		return nil, err
	end
	return true
end

local attach = function(id)
	local job = jobs.entries[id]
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
	std.ps.pty_attach(job.master, detach_key)
	if job.logger_pid and job.logger_pid > 0 then
		std.ps.kill(job.logger_pid, 18)
	end
	return true
end

return {
	start = start,
	list = list,
	get = get,
	kill = kill,
	attach = attach,
	reap = reap,
	detach_key = detach_key,
}
