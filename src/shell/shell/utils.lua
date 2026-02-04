-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local core = require("std.core")
local json = require("cjson.safe")
local storage = require("shell.store")
local term = require("term")
local theme = require("shell.theme")
local style = require("term.tss")
local input = require("term.input")
local history = require("term.input.history")
local wg = require("wireguard")
local pager = require("shell.utils.pager")
local pipeline = require("shell.utils.pipeline")

local zx_complete = function(args)
	local candidates = {}
	local pattern = ".-"
	for _, arg in ipairs(args) do
		pattern = pattern .. arg .. ".-"
	end
	local store = storage.new()
	local snippets = store:list_snippets()
	store:close(true)
	for _, snippet in ipairs(snippets) do
		if snippet:match(pattern) then
			table.insert(candidates, snippet)
		end
	end
	candidates = std.tbl.sort_by_str_len(candidates)
	for i, c in ipairs(candidates) do
		candidates[i] = " " .. c
	end
	return candidates
end

local wg_parse_network = function(name)
	local network = wg.get_device(name)
	if not network then
		return nil
	end
	local peers = {}
	for i, peer in ipairs(network.peers) do
		local peer_nets = {}
		for _, net in ipairs(peer.allowed_ips) do
			table.insert(peer_nets, net.ip .. "/" .. tostring(net.cidr))
		end
		peers[peer.public_key] = {
			bytes = { rx = peer.rx_bytes, tx = peer.tx_bytes },
			last_handshake = peer.last_handshake_time_sec,
			keepalive = peer.persistent_keepalive_interval,
			nets = peer_nets,
			endpoint = peer.endpoint,
		}
	end
	return { name = network.name, pub_key = network.public_key, peers = peers }
end

local wg_info = function()
	local wg_networks = wg.list_devices() or {}
	local info = {}
	for _, name in ipairs(wg_networks) do
		info[name] = wg_parse_network(name)
	end
	return info
end

local wg_apply = function(config_name)
	local conf_json, err = std.fs.read_file("/etc/wireguard/" .. config_name .. ".json")
	if err then
		return nil, "Failed to read wireguard config: " .. tostring(err)
	end
	local wg_device, err = json.decode(conf_json)
	if err then
		return nil, "Failed to decode json config: " .. tostring(err)
	end
	for _, peer in ipairs(wg_device.peers) do
		if not peer.remove_me then
			peer.remove_me = false
		end
		if not peer.replace_allowed_ips then
			peer.replace_allowed_ips = true
		end
	end
	local overlay_ip = wg_device.overlay_ip
	wg_device.overlay_ip = nil
	wg.add_device(wg_device.name)
	wg.set_device(wg_device)
	wg.add_ipv4_addr(wg_device.name, overlay_ip, 32)
	wg.iface_up(wg_device.name)
	for _, peer in ipairs(wg_device.peers) do
		for _, rec in ipairs(peer.allowed_ips) do
			wg.add_route(rec.ip, rec.cidr, wg_device.name, 253) -- 253 == scope link
		end
	end
	return true
end

local wg_down = function(dev_name)
	return wg.del_device(dev_name)
end

return {
	zx_complete = zx_complete,
	parse_pipeline = pipeline.parse,
	parse_cmdline = pipeline.parse_cmdline,
	run_pipeline = pipeline.run,
	wg_info = wg_info,
	wg_apply = wg_apply,
	wg_down = wg_down,
	wg_parse_network = wg_parse_network,
	pager = pager,
}
