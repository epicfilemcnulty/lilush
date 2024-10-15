-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local bytes_human = function(size)
	local human_size = size .. " B"
	if size / 1024 / 1024 / 1024 / 1024 >= 1 then
		human_size = string.format("%.2f", size / 1024 / 1024 / 1024 / 1024) .. " TB"
	elseif size / 1024 / 1024 / 1024 >= 1 then
		human_size = string.format("%.2f", size / 1024 / 1024 / 1024) .. " GB"
	elseif size / 1024 / 1024 >= 1 then
		human_size = string.format("%.2f", size / 1024 / 1024) .. " MB"
	elseif size / 1024 >= 1 then
		human_size = string.format("%.2f", size / 1024) .. " KB"
	end
	return human_size
end

local hex_ipv4 = function(hex_ip_str)
	local ip_hex = hex_ip_str:sub(1, 8)
	local port_hex = hex_ip_str:sub(10)

	local decimal_ip_str = ""
	for i = 8, 2, -2 do
		local octet_hex = ip_hex:sub(i - 1, i)
		local octet_decimal = tonumber(octet_hex, 16)
		decimal_ip_str = decimal_ip_str .. octet_decimal .. "."
	end
	local decimal_port_str = tonumber(port_hex, 16) or ""
	return decimal_ip_str:sub(1, -2), decimal_port_str
end

local date_to_ts = function(date_str)
	local date_ts
	if tonumber(date_str) then
		date_ts = date_str
	elseif date_str:match("%d%dT%d%d") then
		local y, m, d, h, min, s = date_str:match("^([%d]+)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
		date_ts = os.time({
			year = tonumber(y),
			month = tonumber(m),
			day = tonumber(d),
			hour = tonumber(h),
			min = tonumber(min),
			sec = tonumber(s),
		})
	else
		local w_day, d, month_str, y, h, min, s = date_str:match("(%w+), (%d+) (%w+) (%d%d%d%d) (%d+):(%d+):(%d+)")
		local months = {
			Jan = 1,
			Feb = 2,
			Mar = 3,
			Apr = 4,
			May = 5,
			Jun = 6,
			Jul = 7,
			Aug = 8,
			Sep = 9,
			Oct = 10,
			Nov = 11,
			Dec = 12,
		}
		local m = months[month_str]
		date_ts = os.time({
			year = tonumber(y),
			month = tonumber(m),
			day = tonumber(d),
			hour = tonumber(h),
			min = tonumber(min),
			sec = tonumber(s),
		})
	end
	return date_ts
end

local ts_to_str = function(ts, fmt)
	local ts = ts or os.time()
	local fmt = fmt or "%Y-%m-%d %H:%M:%S"
	return os.date(fmt, ts)
end

local time_human = function(date)
	local date_ts = date_to_ts(date)
	local age = os.time() - date_ts
	local human_time
	local plural = ""
	if age / 86400 > 1 then
		local days = math.ceil(age / 86400)
		if days > 1 then
			plural = "s"
		end
		human_time = days .. " day" .. plural .. " ago"
	elseif age / 3600 > 1 then
		local hours = math.ceil(age / 3600)
		if hours > 1 then
			plural = "s"
		end
		human_time = hours .. " hour" .. plural .. " ago"
	else
		local minutes = math.ceil(age / 60)
		if minutes > 1 then
			plural = "s"
		end
		human_time = minutes .. " minute" .. plural .. " ago"
	end
	return human_time, date_ts
end

local conv = {
	date_to_ts = date_to_ts,
	ts_to_str = ts_to_str,
	hex_ipv4 = hex_ipv4,
	time_human = time_human,
	bytes_human = bytes_human,
}
return conv
