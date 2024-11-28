-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local buffer = require("string.buffer")

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
	-- Use ISO 8601 (well, without `T` in between the date and time) by default. See RFC3339 for details on ISO 8601.
	local fmt = fmt or "%Y-%m-%d %H:%M:%S"
	return os.date(fmt, ts)
end

-- Beware, the results are not accurate, we just assume a month to be 30 days,
-- and don't bother ourselves with the nitty-gritty details of the calendar madness.
-- For most cases this is good enough, though.
local time_span_human = function(seconds, precision)
	local seconds = seconds or os.time()
	local precision = precision or "second"
	local spans = { year = 31104000, month = 2592000, week = 604800, day = 86400, hour = 3600, minute = 60, second = 1 }

	local get_count = function(period, span_name)
		local count = period / spans[span_name]
		if count >= 1 then
			local approx_count = math.floor(period / spans[span_name])
			local remains = period - spans[span_name] * approx_count
			local plural = ""
			if approx_count > 1 then
				plural = "s"
			end
			return approx_count .. " " .. span_name .. plural, remains
		end
		return nil
	end

	local buf = buffer:new()
	for _, span_name in ipairs({ "year", "month", "week", "day", "hour", "minute", "second" }) do
		local count, remains = get_count(seconds, span_name)
		if count then
			buf:put(count)
			seconds = remains
		end
		if span_name == precision then
			break
		end
		if remains and remains > 0 then
			buf:put(", ")
		end
	end
	return buf:get()
end

local time_diff_human = function(date, precision, start_ts)
	local precision = precision or "second"
	local start_ts = start_ts or os.time()
	local date_ts = date_to_ts(date)
	local period = math.abs(start_ts - date_ts)
	return time_span_human(period, precision)
end

local conv = {
	date_to_ts = date_to_ts,
	ts_to_str = ts_to_str,
	hex_ipv4 = hex_ipv4,
	time_span_human = time_span_human,
	time_diff_human = time_diff_human,
	bytes_human = bytes_human,
}
return conv
