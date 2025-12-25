-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local core = require("std.core")

local fs = require("std.fs")
local txt = require("std.txt")

local function setenv(name, value)
	return core.setenv(name, value)
end

local function unsetenv(name)
	return core.unsetenv(name)
end

local function kill(pid, signal)
	return core.kill(pid, signal)
end

local function dup(oldfd)
	return core.dup(oldfd)
end

local function dup2(oldfd, newfd)
	return core.dup2(oldfd, newfd)
end

local function fork()
	return core.fork()
end

-- Raw file descriptor based pipe (legacy interface)
-- For new code, consider using pipe_file() which returns Lua FILE objects
local function pipe()
	local p, err = core.pipe()
	if p == nil then
		return nil, err
	end

	local read = function(self, count)
		local result, err = core.read(self.out, count)
		if result == nil then
			return nil, err
		end
		return result
	end

	local write = function(self, data, count)
		local result, err = core.write(self.inn, data, count)
		if result == nil then
			return nil, err
		end
		return result
	end

	local close_read = function(self)
		if self._out_open then
			core.close(self.out)
			self._out_open = false
		end
	end

	local close_write = function(self)
		if self._inn_open then
			core.close(self.inn)
			self._inn_open = false
		end
	end

	p._out_open = true
	p._inn_open = true

	setmetatable(p, {
		__index = {
			read = read,
			write = write,
			close_out = close_read,
			close_inn = close_write
		},
		__gc = function(self)
			close_read(self)
			close_write(self)
		end
	})
	return p
end

-- FILE* based pipe - returns Lua file objects compatible with io.* functions
-- This is the recommended interface for new code
local function pipe_file()
	local p, err = core.pipe_file()
	if p == nil then
		return nil, err
	end
	-- p.out and p.inn are now Lua FILE* objects
	-- They support standard file methods: read(), write(), close(), setvbuf(), etc.
	return p
end

local function getpid()
	return core.getpid()
end

local function exec(pathname, ...)
	local cmd_name = pathname:match("^.*/([^/]+)$")
	if not cmd_name then
		cmd_name = pathname
	end
	return core.exec(pathname, cmd_name, ...)
end

local function launch(cmd, stdin, stdout, stderr, ...)
	local pid = fork()
	if pid < 0 then
		return nil, "failed to fork"
	end
	if pid == 0 then --child
		if stdin then
			dup2(stdin, 0)
			core.close(stdin)
		end
		if stderr then
			dup2(stderr, 2)
			core.close(stderr)
		end
		if stdout then
			dup2(stdout, 1)
			core.close(stdout)
		end
		if type(cmd) == "table" then
			local status = cmd.func(cmd.name, { ... }, cmd.extra)
			os.exit(status)
		end
		exec(cmd, ...)
		os.exit(-1)
	end
	return pid
end

local function waitpid(pid)
	return core.waitpid(pid)
end

local function wait(pid)
	return core.wait(pid)
end

local exec_simple = function(cmd, nowait)
	local args = {}
	for arg in cmd:gmatch("%S+") do
		table.insert(args, arg)
	end
	local cmd = table.remove(args, 1)

	local stdout = pipe()
	local stderr = pipe()
	local pid = launch(cmd, nil, stdout.inn, stderr.inn, unpack(args))
	stdout:close_inn()
	stderr:close_inn()
	local out = stdout:read() or ""
	local err = stderr:read() or ""
	local out_lines = txt.lines(out)
	local err_lines = txt.lines(err)
	stdout:close_out()
	stderr:close_out()
	local dummy, code
	if nowait then
		dummy, code = waitpid(pid)
	else
		dummy, code = wait(pid)
	end
	return {
		status = code or 255,
		stdout = out_lines,
		stderr = err_lines,
	}
end

local exec_one_line = function(cmd)
	local result = exec_simple(cmd)
	if result and result.stdout[1] then
		return result.stdout[1]
	end
	return ""
end

local find_by_inode = function(inode)
	local pids = fs.list_files("/proc", "^%d", "d") or {}
	for pid, _ in pairs(pids) do
		local fds = fs.list_files("/proc/" .. pid .. "/fd", ".", "l", true) or {}
		for fd, st in pairs(fds) do
			-- might be misleading -- with this clause we are only looking for sockets...
			if st.target and st.target:match("socket:%[" .. inode .. "%]") then
				local proc_stats = fs.read_file("/proc/" .. pid .. "/stat") or ""
				local proc_name = proc_stats:match("^%d+ %(([^)]+)%)") or "n/a"
				return proc_name .. "(" .. pid .. ")"
			end
		end
	end
	return ""
end

local ps = {
	setenv = setenv,
	environ = environ,
	unsetenv = unsetenv,
	fork = fork,
	kill = kill,
	dup = dup,
	dup2 = dup2,
	pipe = pipe,
	pipe_file = pipe_file,
	exec = exec,
	exec_simple = exec_simple,
	exec_one_line = exec_one_line,
	launch = launch,
	waitpid = waitpid,
	wait = wait,
	getpid = getpid,
	find_by_inode = find_by_inode,
}
return ps
