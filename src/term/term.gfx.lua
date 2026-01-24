--[[

  Module for working with Kitty's terminal graphics
  [protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)

  The whole interaction with the protocol is basically built around
  the two functions -- `send_data` and `send_cmd`. Depending
  on the set options Kitty might send a response to a command --
  it's user's responsibility to handle those as they see fit.

]]
local std = require("std")
local sbuf = require("string.buffer")

-- Optimized base64 encoding using string.buffer and pre-computed lookup
local bit = require("bit")
local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
-- Pre-compute single character strings for direct indexing (1-based)
local b64 = {}
for i = 1, 64 do
	b64[i - 1] = base64_chars:sub(i, i)
end

local function base64_encode(data)
	local len = #data
	-- Pre-allocate output buffer (base64 produces 4 bytes per 3 input bytes)
	local out = sbuf.new(math.ceil(len / 3) * 4 + 4)

	local i = 1
	while i <= len - 2 do
		local a, b, c = data:byte(i, i + 2)
		-- Use bit operations instead of multiplication/division
		out:put(
			b64[bit.rshift(a, 2)],
			b64[bit.bor(bit.lshift(bit.band(a, 3), 4), bit.rshift(b, 4))],
			b64[bit.bor(bit.lshift(bit.band(b, 15), 2), bit.rshift(c, 6))],
			b64[bit.band(c, 63)]
		)
		i = i + 3
	end

	-- Handle remaining 1 or 2 bytes
	local rem = len - i + 1
	if rem == 2 then
		local a, b = data:byte(i, i + 1)
		out:put(
			b64[bit.rshift(a, 2)],
			b64[bit.bor(bit.lshift(bit.band(a, 3), 4), bit.rshift(b, 4))],
			b64[bit.lshift(bit.band(b, 15), 2)],
			"="
		)
	elseif rem == 1 then
		local a = data:byte(i)
		out:put(
			b64[bit.rshift(a, 2)],
			b64[bit.lshift(bit.band(a, 3), 4)],
			"=="
		)
	end

	return out:get()
end

local options_to_str = function(options)
	options = options or {}
	local buf = sbuf.new()
	for k, v in pairs(options) do
		buf:put(k, "=", tostring(v), ",")
	end
	local opt_str = buf:get():gsub(",$", "")
	return opt_str
end

local send_data = function(data, options)
	local opt_str = options_to_str(options)
	local encoded_data = base64_encode(data)
	local len = #encoded_data
	-- Protocol requires data to be split into chunks of 4096 bytes
	local chunk_size = 4096

	if len <= chunk_size then
		-- Single chunk - simple case
		io.write(string.format("\027_G%s;%s\027\\", opt_str, encoded_data))
		io.flush()
		return
	end

	-- Multi-chunk: build entire output in a buffer, then single write
	local out = sbuf.new(len + 1024)  -- Extra space for escape sequences
	local frame_opts = (options.a and options.a == "f") and "a=f," or ""

	-- First chunk with full options
	out:put("\027_G", opt_str, ",m=1;", encoded_data:sub(1, chunk_size), "\027\\")

	-- Middle chunks
	local pos = chunk_size + 1
	while pos + chunk_size <= len do
		out:put("\027_G", frame_opts, "m=1;", encoded_data:sub(pos, pos + chunk_size - 1), "\027\\")
		pos = pos + chunk_size
	end

	-- Final chunk
	out:put("\027_G", frame_opts, "m=0;", encoded_data:sub(pos), "\027\\")

	-- Single write for entire transmission
	io.write(out:get())
	io.flush()
end

local send_data_shm = function(data, options)
	options = options or {}
	local shm_name = std.nanoid()

	-- Create shared memory object
	local ok, err = std.create_shm(shm_name, data)
	if err then
		print(err)
		return nil, err
	end

	-- Set transmission medium to shared memory
	options.t = "s" -- shared memory
	options.S = #data -- data size

	local opt_str = options_to_str(options)
	io.write(string.format("\027_G%s;" .. base64_encode(shm_name) .. "\027\\", opt_str))
	io.flush()
end

local send_cmd = function(options)
	local opt_str = options_to_str(options)
	io.write("\027_G" .. opt_str .. "\027\\")
	io.flush()
end

local delete_image = function(options)
	options = options or {}
	options.a = "d"
	send_cmd(options)
end
-- If there is no id in the options,
-- we propagate the call to self:send.
--
-- Otherwise we issue a command for kitty to display
-- an image with the given id.
local display_canvas = function(self, options)
	options = options or {}
	if options.i == nil then
		self:send(options)
		return true
	end
	options.a = "p"
	send_cmd(options)
end

local send_canvas = function(self, options)
	options = options or {}
	if options.i == nil then
		-- if neither `i` nor `a` is set,
		-- we assume that immediate display is
		-- the intention
		options.a = options.a or "T"
	end
	if options.s == nil then
		options.s = self.cfg.width
	end
	if options.v == nil then
		options.v = self.cfg.height
	end
	if options.f == nil then
		options.f = 32
	end
	if options.t and options.t == "s" then
		send_data_shm(self:tostring(), options)
	else
		send_data(self:tostring(), options)
	end
end

local new_canvas = function(config)
	config = config or {}

	local default_config = {
		width = 800,
		height = 600,
		colors = {
			bg = { 0, 0, 0, 0 },
			main = { 252, 252, 252, 255 },
		},
	}

	std.tbl.merge(default_config, config)

	local canvas = {
		data = {},
		cfg = default_config,
		-- methods
		tostring = function(self)
			local rgba_data = sbuf.new(self.cfg.width * self.cfg.height * 4)
			for y = 1, self.cfg.height do
				for x = 1, self.cfg.width do
					local pixel = self.data[y][x]
					local alpha = pixel[4] or 255 -- Default to fully solid if no alpha provided
					rgba_data:put(string.char(pixel[1], pixel[2], pixel[3], alpha))
				end
			end
			return rgba_data:get()
		end,
		display = display_canvas,
		send = send_canvas,
		fill = function(self, col)
			col = col or self.cfg.colors.bg
			for y = 1, self.cfg.height do
				self.data[y] = {}
				for x = 1, self.cfg.width do
					self.data[y][x] = { col[1], col[2], col[3], col[4] or 255 }
				end
			end
		end,
		pixel = function(self, x, y, col)
			col = col or self.cfg.colors.main
			if x > 0 and x <= self.cfg.width and y > 0 and y <= self.cfg.height then
				self.data[y][x] = { col[1], col[2], col[3], col[4] or 255 }
			end
		end,
		line = function(self, x1, y1, x2, y2, col)
			col = col or self.cfg.colors.main
			local dx = math.abs(x2 - x1)
			local dy = math.abs(y2 - y1)
			local sx = x1 < x2 and 1 or -1
			local sy = y1 < y2 and 1 or -1
			local err = dx - dy

			local x, y = x1, y1

			while true do
				self:pixel(x, y, col)
				if x == x2 and y == y2 then
					break
				end
				local e2 = 2 * err
				if e2 > -dy then
					err = err - dy
					x = x + sx
				end
				if e2 < dx then
					err = err + dx
					y = y + sy
				end
			end
		end,
		circle = function(self, cx, cy, radius, col)
			col = col or self.cfg.colors.main
			for y = cy - radius, cy + radius do
				for x = cx - radius, cx + radius do
					local dx = x - cx
					local dy = y - cy
					if dx * dx + dy * dy <= radius * radius then
						self:pixel(x, y, col)
					end
				end
			end
		end,
		rect = function(self, x1, y1, x2, y2, col, filled)
			if filled then
				for y = math.min(y1, y2), math.max(y1, y2) do
					for x = math.min(x1, x2), math.max(x1, x2) do
						self:pixel(x, y, col)
					end
				end
			else
				self:line(x1, y1, x2, y1, col) -- top
				self:line(x2, y1, x2, y2, col) -- right
				self:line(x2, y2, x1, y2, col) -- bottom
				self:line(x1, y2, x1, y1, col) -- left
			end
		end,
	}
	canvas:fill()
	return canvas
end

return {
	send_data = send_data,
	send_cmd = send_cmd,
	delete_image = delete_image,
	new_canvas = new_canvas,
}
