local resolver = require("dns.resolver")
local std = require("std")

local root_servers = {
	[1] = { "a.root-servers.net", "198.41.0.4", "2001:503:ba3e::2:30", "Verisign, Inc." },
	[2] = {
		"b.root-servers.net",
		"199.9.14.201",
		"2001:500:200::b",
		"University of Southern California Information Sciences Institute",
	},
	[3] = { "c.root-servers.net", "192.33.4.12", "2001:500:2::c", "Cogent Communications" },
	[4] = { "d.root-servers.net", "199.7.91.13", "2001:500:2d::d", "University of Maryland" },
	[5] = { "e.root-servers.net", "192.203.230.10", "2001:500:a8::e", "NASA (Ames Research Center)" },
	[6] = { "f.root-servers.net", "192.5.5.241", "2001:500:2f::f", "Internet Systems Consortium, Inc." },
	[7] = { "g.root-servers.net", "192.112.36.4", "2001:500:12::d0d", "US Department of Defense (NIC)" },
	[8] = { "h.root-servers.net", "198.97.190.53", "2001:500:1::53", "US Army (Research Lab)" },
	[9] = { "i.root-servers.net", "192.36.148.17", "2001:7fe::53", "Netnod" },
	[10] = { "j.root-servers.net", "192.58.128.30", "2001:503:c27::2:30", "Verisign, Inc." },
	[11] = { "k.root-servers.net", "193.0.14.129", "2001:7fd::1", "RIPE NCC" },
	[12] = { "l.root-servers.net", "199.7.83.42", "2001:500:9f::42", "ICANN" },
	[13] = { "m.root-servers.net", "202.12.27.33", "2001:dc3::35", "WIDE Project" },
}

local parse_resolvconf = function()
	local resolvconf = std.fs.read_file("/etc/resolv.conf")
	if resolvconf then
		local ns =
			resolvconf:match("nameserver ([0-9][0-9]?[0-9]?%.[0-9][0-9]?[0-9]?%.[0-9][0-9]?[0-9]?%.[0-9][0-9]?[0-9]?)")
		if ns then
			return ns
		end
	end
	return nil, "failed to parse /etc/resolv.conf"
end

local config = {
	system = parse_resolvconf(),
	fallback = "1.1.1.1",
}

local simple_query = function(domain, record_type, ns, args)
	local ns = ns or config.system or config.fallback
	local record_type = record_type or "A"
	local r = resolver.new({ ns }, 2)
	if not args.cache then
		r:disableCache()
	end
	if args.tcp then
		r:enableTcp()
	end
	local response, err = r:resolveRaw(domain, record_type)
	if not response then
		return nil, err
	end

	local answer = {}
	local glue = {}
	for i, a in ipairs(response.answers) do
		table.insert(answer, { a.name, a.content, a.ttl, a.type })
	end
	if #answer == 0 then
		for i, a in ipairs(response.authorities) do
			table.insert(answer, { a.name, a.content, a.ttl, a.type })
		end
	end
	if response.additionals then
		for i, a in ipairs(response.additionals) do
			if not glue[a.name] then
				glue[a.name] = { [a.type] = { a.content } }
			else
				if not glue[a.name][a.type] then
					glue[a.name][a.type] = {}
				end
				table.insert(glue[a.name][a.type], a.content)
			end
		end
	end
	return answer, glue, ns
end

local resolve_fullchain = function(domain, record_type, args)
	local root_idx = math.random(13)
	local root_ip = root_servers[root_idx][2]

	local answer = {
		tld = domain:match("([^.]+)$"),
		tld_ns = {},
		domain_ns = {},
		recs = {},
		root_ns_name = root_servers[root_idx][1],
	}

	local response, glue = simple_query(answer.tld, "NS", root_ip, args)
	if not response then
		return nil, "failed TLD NS request:" .. tostring(glue)
	end
	answer.tld_ns = response
	answer.tld_ns_glue = glue

	local tld_ns_idx = math.random(#answer.tld_ns)
	local name = answer.tld_ns[tld_ns_idx][2]
	local tld_ns_ip
	if answer.tld_ns_glue[name] and answer.tld_ns_glue[name]["A"] then
		tld_ns_ip = answer.tld_ns_glue[name]["A"][1]
	else
		response, err = simple_query(name, nil, nil, args)
		if response == nil then
			return nil, "failed to resolve tld NS IP: " .. tostring(err)
		end
		tld_dns_ip = response[2]
	end
	answer.tld_ns_name = name

	response, glue = simple_query(domain, "NS", tld_ns_ip, args)
	if not response then
		return nil, "failed domain NS request:" .. tostring(glue)
	end
	answer.domain_ns = response
	answer.domain_ns_glue = glue

	local domain_ns_idx = math.random(#answer.domain_ns)
	local domain_ns_name = answer.domain_ns[domain_ns_idx][2]
	answer.domain_ns_name = domain_ns_name
	if glue[domain_ns_name] then
		answer.domain_ns_ip = glue[domain_ns_name]["A"][1]
	else
		response, glue = simple_query(domain_ns_name, nil, nil, args)
		if not response then
			return nil, "failed to resolve authoritative NS IP:" .. tostring(glue)
		end
		answer.domain_ns_ip = response[1][2]
	end
	response, glue = simple_query(domain, record_type, domain_ns_ip, args)
	if not response then
		return nil, "failed to query authoritative NS: " .. tostring(glue)
	end
	answer.recs = response
	answer.glue = glue
	return answer
end

return { simple = simple_query, fullchain = resolve_fullchain, config = config }
