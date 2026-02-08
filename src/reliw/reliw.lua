-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local ws = require("web.server")
local json = require("cjson.safe")
local handle = require("reliw.handle")
local storage = require("reliw.store")

local default_reliw_config = {
	ip = "127.0.0.1",
	port = 8080,
	data_dir = "/www",
	cache_max_size = 5242880, -- 5 megabyte by default
	redis = {
		host = "127.0.0.1",
		port = 6379,
		db = 13,
		prefix = "RLW",
	},
	metrics = {
		ip = "127.0.0.1",
		port = 9101,
	},
}

local get_logger = function(self)
	return self.__state.logger
end

local configure = function(srv_cfg)
	local cfg = std.tbl.copy(default_reliw_config)
	return std.tbl.merge(cfg, srv_cfg)
end

local get_server_config = function()
	local config_file = os.getenv("RELIW_CONFIG_FILE") or "/etc/reliw/config.json"
	if not std.fs.file_exists(config_file) then
		return nil, "no config file found"
	end
	local config = json.decode(std.fs.read_file(config_file))
	if not config then
		return nil, "failed to read/decode config file"
	end
	return configure(config)
end

local new_server = function(srv_cfg)
	local srv, err = ws.new(srv_cfg, handle.func)
	if not srv then
		return nil, err
	end
	return srv
end

local track_child_pid = function(self, pid, name)
	if not pid or pid <= 0 then
		return
	end
	local child_pids = self.__state.child_pids
	if not child_pids then
		child_pids = {}
		self.__state.child_pids = child_pids
	end
	child_pids[pid] = name or "child"
end

local untrack_child_pid = function(self, pid)
	local child_pids = self.__state.child_pids
	if not child_pids or not pid or pid <= 0 then
		return false
	end
	if not child_pids[pid] then
		return false
	end
	child_pids[pid] = nil
	return true
end

local drain_exited_children = function(self)
	while true do
		local pid = std.ps.waitpid(-1)
		if not pid or pid <= 0 then
			break
		end
		untrack_child_pid(self, pid)
	end
end

local wait_for_primary_exit = function(self)
	if not self.__state.reliw_pid then
		return
	end
	local primary_pid = self.__state.reliw_pid
	while true do
		local pid = std.ps.wait(-1)
		if not pid or pid <= 0 then
			break
		end
		local is_primary = pid == primary_pid
		untrack_child_pid(self, pid)
		if is_primary then
			break
		end
	end
	drain_exited_children(self)
end

local spawn_metrics_server = function(self)
	local metrics_cfg = self.cfg.metrics
	if not metrics_cfg or metrics_cfg.disabled then
		return nil, "metrics are disabled"
	end
	local cfg = std.tbl.copy(self.cfg)
	cfg.ip = metrics_cfg.ip or cfg.ip
	cfg.port = metrics_cfg.port or cfg.port
	cfg.process = "metrics"
	cfg.ssl = nil
	cfg.log_level = 100
	local metrics = require("reliw.metrics")
	local srv, err = ws.new(cfg, metrics.show)
	if not srv then
		return nil, err
	end
	local logger = get_logger(self)
	local metrics_pid = std.ps.fork()
	if metrics_pid < 0 then
		logger:log({ msg = "metrics server spawn failed", process = "manager" }, "error")
		return nil
	end
	if metrics_pid == 0 then
		local ok, serve_ok, serve_err = pcall(srv.serve, srv)
		if not ok then
			logger:log({ msg = "metrics server crashed", process = "metrics", error = tostring(serve_ok) }, "error")
			os.exit(1)
		end
		if not serve_ok then
			logger:log(
				{ msg = "metrics server exited with error", process = "metrics", error = tostring(serve_err) },
				"error"
			)
			os.exit(1)
		end
		os.exit(0)
	end
	logger:log({ msg = "metrics server spawned", process = "manager", pid = metrics_pid })
	self.__state.metrics_pid = metrics_pid
	track_child_pid(self, metrics_pid, "metrics")
	return true
end

local spawn_server = function(self, srv_cfg)
	local logger = get_logger(self)
	local srv_cfg_ipv4 = std.tbl.copy(srv_cfg)
	srv_cfg_ipv4.process = "server_ipv4"
	local reliw_srv, err = new_server(srv_cfg_ipv4)
	if not reliw_srv then
		return nil, err
	end
	local reliw_pid = std.ps.fork()
	if reliw_pid < 0 then
		logger:log({ msg = "IPv4 server spawn failed", process = "manager" }, "error")
		return nil
	end
	if reliw_pid == 0 then
		local ok, serve_ok, serve_err = pcall(reliw_srv.serve, reliw_srv)
		if not ok then
			logger:log({ msg = "IPv4 server crashed", process = "server_ipv4", error = tostring(serve_ok) }, "error")
			os.exit(1)
		end
		if not serve_ok then
			logger:log(
				{ msg = "IPv4 server exited with error", process = "server_ipv4", error = tostring(serve_err) },
				"error"
			)
			os.exit(1)
		end
		os.exit(0)
	end
	logger:log({ msg = "IPv4 server spawned", process = "manager", pid = reliw_pid })
	self.__state.reliw_pid = reliw_pid
	track_child_pid(self, reliw_pid, "server_ipv4")

	if not srv_cfg.ipv6 then
		return true
	end

	local srv_cfg_ipv6 = std.tbl.copy(srv_cfg_ipv4)
	srv_cfg_ipv6.ip = srv_cfg_ipv6.ipv6
	srv_cfg_ipv6.process = "server_ipv6"
	local reliw6_srv, err = new_server(srv_cfg_ipv6)
	if not reliw6_srv then
		return nil, err
	end
	local reliw6_pid = std.ps.fork()
	if reliw6_pid < 0 then
		logger:log({ msg = "IPv6 server spawn failed", process = "manager" }, "error")
		return nil
	end
	if reliw6_pid == 0 then
		local ok, serve_ok, serve_err = pcall(reliw6_srv.serve, reliw6_srv)
		if not ok then
			logger:log({ msg = "IPv6 server crashed", process = "server_ipv6", error = tostring(serve_ok) }, "error")
			os.exit(1)
		end
		if not serve_ok then
			logger:log(
				{ msg = "IPv6 server exited with error", process = "server_ipv6", error = tostring(serve_err) },
				"error"
			)
			os.exit(1)
		end
		os.exit(0)
	end
	logger:log({ msg = "IPv6 server spawned", process = "manager", pid = reliw6_pid })
	self.__state.reliw6_pid = reliw6_pid
	track_child_pid(self, reliw6_pid, "server_ipv6")
	return true
end

local run = function(self)
	local cfg = self.cfg
	if cfg.metrics and not cfg.metrics.disabled then
		self.spawn_metrics_server(self)
	end
	if not self.spawn_server(self, cfg) then
		os.exit(1)
	end
	wait_for_primary_exit(self)
end

local has_child_pid = function(self, pid)
	if not pid or pid <= 0 then
		return false
	end
	local child_pids = self.__state.child_pids
	return child_pids and child_pids[pid] ~= nil or false
end

local list_child_pids = function(self)
	return std.tbl.copy(self.__state.child_pids or {})
end

local get_process_pids = function(self)
	return {
		ipv4 = self.__state.reliw_pid,
		ipv6 = self.__state.reliw6_pid,
		metrics = self.__state.metrics_pid,
	}
end

local new = function()
	local cfg, err = get_server_config()
	if not cfg then
		return nil, "failed to get reliw server config: " .. err
	end
	local store_validation, store_err = storage.new(cfg)
	if not store_validation then
		return nil, "failed to init store: " .. store_err
	end
	local _, close_err = store_validation.close(store_validation)
	if close_err then
		return nil, "failed to close store validation handle: " .. tostring(close_err)
	end

	local instance = {
		cfg = cfg,
		__state = {
			logger = std.logger.new(cfg.log_level),
			child_pids = {},
			reliw_pid = nil,
			reliw6_pid = nil,
			metrics_pid = nil,
		},
		run = run,
		spawn_server = spawn_server,
		spawn_metrics_server = spawn_metrics_server,
		has_child_pid = has_child_pid,
		list_child_pids = list_child_pids,
		get_process_pids = get_process_pids,
	}
	return instance
end

return {
	new = new,
}
