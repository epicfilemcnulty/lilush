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

-- Somehow WolfSSL Base64_Encode, which we have exposed in crypto module,
-- fails on this data...Gotta debug this later, for now we use this
-- substitute function
local function base64_encode(data)
	local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local result = {}

	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		b = b or 0
		c = c or 0

		local bitmap = a * 65536 + b * 256 + c

		table.insert(result, base64_chars:sub(math.floor(bitmap / 262144) + 1, math.floor(bitmap / 262144) + 1))
		table.insert(
			result,
			base64_chars:sub(math.floor((bitmap % 262144) / 4096) + 1, math.floor((bitmap % 262144) / 4096) + 1)
		)
		table.insert(
			result,
			i + 1 <= #data
					and base64_chars:sub(math.floor((bitmap % 4096) / 64) + 1, math.floor((bitmap % 4096) / 64) + 1)
				or "="
		)
		table.insert(result, i + 2 <= #data and base64_chars:sub((bitmap % 64) + 1, (bitmap % 64) + 1) or "=")
	end

	return table.concat(result)
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
	-- Protocol requires data to be split into chunks of 4096 bytes
	local chunk_size = 4096
	local chunks = {}
	for i = 1, #encoded_data, chunk_size do
		table.insert(chunks, encoded_data:sub(i, i + chunk_size - 1))
	end
	-- Send first chunk with metadata
	if #chunks > 1 then
		-- Multi-chunk transmission
		io.write(string.format("\027_G%s,m=1;%s\027\\", opt_str, chunks[1]))
		io.flush()

		-- Send middle chunks
		for i = 2, #chunks - 1 do
			io.write(string.format("\027_Gm=1;%s\027\\", chunks[i]))
			io.flush()
		end

		-- Send final chunk
		io.write(string.format("\027_Gm=0;%s\027\\", chunks[#chunks]))
		io.flush()
	else
		-- Single chunk transmission
		io.write(string.format("\027_G%s;%s\027\\", opt_str, chunks[1]))
		io.flush()
	end
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

-- Auxiliary functions for the isometric projection object

-- Transform 3D coordinates to isometric 2D coordinates
local world_to_isometric = function(self, x, y, z)
	-- Apply isometric transformation matrix
	-- Standard isometric projection with configurable angles
	local cos_x = math.cos(self.cfg.angle_x)
	local sin_x = math.sin(self.cfg.angle_x)
	local cos_y = math.cos(self.cfg.angle_y)
	local sin_y = math.sin(self.cfg.angle_y)

	-- Scale Z to reduce depth distortion
	z = z * self.cfg.scale_z

	-- Apply rotation around X-axis, then Y-axis
	local y1 = y * cos_x - z * sin_x
	local z1 = y * sin_x + z * cos_x

	local x2 = x * cos_y + z1 * sin_y
	local y2 = y1

	return x2, y2
end

-- Calculate bounds for 3D coordinates in isometric space
local calculate_bounds = function(self, points)
	points = points or {}
	-- Calculate data center point first
	local data_center_3d
	if #points == 0 then
		data_center_3d = { 0, 0, 0 }
		self.cfg.grid_range = self.cfg.grid_range or 90
		self.cfg.center_3d = self.cfg.center_3d or data_center_3d
		return -100, 100, -100, 100 -- Default bounds
	else
		local sumX, sumY, sumZ = 0, 0, 0
		for _, point in ipairs(points) do
			sumX = sumX + point.coords[1]
			sumY = sumY + point.coords[2]
			sumZ = sumZ + point.coords[3]
		end
		data_center_3d = { sumX / #points, sumY / #points, sumZ / #points }
	end
	if not self.cfg.center_3d then
		self.cfg.center_3d = data_center_3d
	end
	local cX, cY = self:world_to_isometric(self.cfg.center_3d[1], self.cfg.center_3d[2], self.cfg.center_3d[3])

	-- Calculate grid_range if not set manually
	if not self.cfg.grid_range then
		if not self.cfg.range then
			-- Find the maximum distance from the data center in 3D space
			local max_distance = 0
			for _, point in ipairs(points) do
				local dx = point.coords[1] - data_center_3d[1]
				local dy = point.coords[2] - data_center_3d[2]
				local dz = point.coords[3] - data_center_3d[3]
				local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
				max_distance = math.max(max_distance, distance)
			end
			self.cfg.grid_range = max_distance * self.cfg.grid_coeff
		else
			self.cfg.grid_range = self.cfg.range * self.cfg.grid_coeff
		end
	end

	local filtered = {}
	if self.cfg.range then
		for _, point in ipairs(points) do
			local dx = point.coords[1] - self.cfg.center_3d[1]
			local dy = point.coords[2] - self.cfg.center_3d[2]
			local dz = point.coords[3] - self.cfg.center_3d[3]
			local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
			if distance <= self.cfg.range then
				table.insert(filtered, point)
			end
		end
		if #filtered == 0 then
			filtered = { { coords = self.cfg.center_3d } }
		end
	else
		filtered = points
	end
	-- Transform all points to isometric coordinates to find bounds
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge

	for _, point in ipairs(filtered) do
		local isoX, isoY = self:world_to_isometric(point.coords[1], point.coords[2], point.coords[3])
		minX = math.min(minX, isoX)
		maxX = math.max(maxX, isoX)
		minY = math.min(minY, isoY)
		maxY = math.max(maxY, isoY)
	end

	-- Calculate range with zoom factor
	local rX = (maxX - minX) / self.cfg.zoom
	local rY = (maxY - minY) / self.cfg.zoom

	-- Ensure minimum range to avoid division by zero
	rX = math.max(rX, 1)
	rY = math.max(rY, 1)

	-- Add plot area padding
	local pX = rX * self.cfg.padding
	local pY = rY * self.cfg.padding

	-- Calculate final bounds centered on chosen point
	local fminX = cX - (rX + pX) / 2
	local fmaxX = cX + (rX + pX) / 2
	local fminY = cY - (rY + pY) / 2
	local fmaxY = cY + (rY + pY) / 2

	return fminX, fmaxX, fminY, fmaxY
end

-- Convert isometric coordinates to screen coordinates
local isometric_to_screen = function(self, isoX, isoY, minX, maxX, minY, maxY)
	local plotWidth = self.cfg.width - 2 * self.cfg.margin
	local plotHeight = self.cfg.height - 2 * self.cfg.margin

	local screenX = self.cfg.margin + ((isoX - minX) / (maxX - minX)) * plotWidth
	local screenY = self.cfg.height - self.cfg.margin - ((isoY - minY) / (maxY - minY)) * plotHeight

	return math.floor(screenX), math.floor(screenY)
end

-- Draw isometric grid relative to the data bounds and center
local draw_grid = function(self, minX, maxX, minY, maxY, points)
	-- Use the grid_range calculated in calculate_bounds
	local grid_step = self.cfg.grid_range * 2 / self.cfg.grid_lines

	-- Center the grid on the chosen center point
	local grid_center_x = self.cfg.center_3d[1]
	local grid_center_y = self.cfg.center_3d[2]
	local grid_center_z = self.cfg.center_3d[3]

	-- Draw grid lines parallel to each axis
	for i = 0, self.cfg.grid_lines do
		local offset = -self.cfg.grid_range + i * grid_step

		-- Lines parallel to X-axis (varying Y, constant Z at center)
		local points_x = {}
		for j = 0, self.cfg.grid_lines do
			local y_offset = -self.cfg.grid_range + j * grid_step
			local world_x = grid_center_x + offset
			local world_y = grid_center_y + y_offset
			local world_z = grid_center_z
			local isoX, isoY = self:world_to_isometric(world_x, world_y, world_z)
			local screenX, screenY = self:isometric_to_screen(isoX, isoY, minX, maxX, minY, maxY)
			table.insert(points_x, { screenX, screenY })
		end
		-- Draw connected line segments
		for j = 1, #points_x - 1 do
			self.canvas:line(
				points_x[j][1],
				points_x[j][2],
				points_x[j + 1][1],
				points_x[j + 1][2],
				self.cfg.colors.grid
			)
		end

		-- Lines parallel to Y-axis (varying X, constant Z at center)
		local points_y = {}
		for j = 0, self.cfg.grid_lines do
			local x_offset = -self.cfg.grid_range + j * grid_step
			local world_x = grid_center_x + x_offset
			local world_y = grid_center_y + offset
			local world_z = grid_center_z
			local isoX, isoY = self:world_to_isometric(world_x, world_y, world_z)
			local screenX, screenY = self:isometric_to_screen(isoX, isoY, minX, maxX, minY, maxY)
			table.insert(points_y, { screenX, screenY })
		end
		-- Draw connected line segments
		for j = 1, #points_y - 1 do
			self.canvas:line(
				points_y[j][1],
				points_y[j][2],
				points_y[j + 1][1],
				points_y[j + 1][2],
				self.cfg.colors.grid
			)
		end
	end
end

-- Draw main coordinate axes through the center point
local draw_axis = function(self, minX, maxX, minY, maxY)
	-- Get the center point coordinates
	local grid_center_x = self.cfg.center_3d[1]
	local grid_center_y = self.cfg.center_3d[2]
	local grid_center_z = self.cfg.center_3d[3]

	-- Transform center to screen coordinates
	local center_iso_x, center_iso_y = self:world_to_isometric(grid_center_x, grid_center_y, grid_center_z)
	local center_screen_x, center_screen_y =
		self:isometric_to_screen(center_iso_x, center_iso_y, minX, maxX, minY, maxY)

	-- X-axis (from center)
	local x_axis_end_iso_x, x_axis_end_iso_y =
		self:world_to_isometric(grid_center_x + self.cfg.grid_range, grid_center_y, grid_center_z)
	local x_axis_end_screen_x, x_axis_end_screen_y =
		self:isometric_to_screen(x_axis_end_iso_x, x_axis_end_iso_y, minX, maxX, minY, maxY)
	self.canvas:line(center_screen_x, center_screen_y, x_axis_end_screen_x, x_axis_end_screen_y, self.cfg.colors.axis)

	-- Y-axis (from center)
	local y_axis_end_iso_x, y_axis_end_iso_y =
		self:world_to_isometric(grid_center_x, grid_center_y + self.cfg.grid_range, grid_center_z)
	local y_axis_end_screen_x, y_axis_end_screen_y =
		self:isometric_to_screen(y_axis_end_iso_x, y_axis_end_iso_y, minX, maxX, minY, maxY)
	self.canvas:line(center_screen_x, center_screen_y, y_axis_end_screen_x, y_axis_end_screen_y, self.cfg.colors.axis)

	-- Z-axis (from center)
	local z_axis_end_iso_x, z_axis_end_iso_y =
		self:world_to_isometric(grid_center_x, grid_center_y, grid_center_z + self.cfg.grid_range)
	local z_axis_end_screen_x, z_axis_end_screen_y =
		self:isometric_to_screen(z_axis_end_iso_x, z_axis_end_iso_y, minX, maxX, minY, maxY)
	self.canvas:line(center_screen_x, center_screen_y, z_axis_end_screen_x, z_axis_end_screen_y, self.cfg.colors.axis)
end

-- Generate color based on distance from center with optional height encoding
local color_by_distance = function(self, point)
	-- Calculate 3D distance from center
	local dx = point.coords[1] - self.cfg.center_3d[1]
	local dy = point.coords[2] - self.cfg.center_3d[2]
	local dz = point.coords[3] - self.cfg.center_3d[3]
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

	-- Use grid_range as the reference distance for normalization
	local max_distance = self.cfg.grid_range or 100
	local distance_factor = math.max(0, 1 - (distance / max_distance))

	-- Color coding options (can be made configurable):
	local color_mode = self.cfg.color_mode or "distance" -- "distance", "temperature", "height"

	if color_mode == "temperature" then
		-- Temperature gradient: close = red/orange, far = blue/white
		local temp_factor = distance_factor
		local r = 255 * (0.4 + temp_factor * 0.6) -- Red increases with closeness
		local g = 255 * (0.2 + temp_factor * 0.5) -- Moderate green
		local b = 255 * (0.8 - temp_factor * 0.5) -- Blue decreases with closeness
		return { math.floor(r), math.floor(g), math.floor(b) }
	elseif color_mode == "height" then
		-- Height-based coloring with distance intensity
		local height_factor = (dz + max_distance) / (2 * max_distance) -- Normalize Z to [0, 1]
		height_factor = math.max(0, math.min(1, height_factor))

		-- Use HSV-like approach: height controls hue, distance controls brightness
		local base_intensity = 100 + (distance_factor * 155) -- 100-255 range

		if height_factor < 0.5 then
			-- Below center: blue to cyan
			local t = height_factor * 2
			local r = base_intensity * 0.2
			local g = base_intensity * t
			local b = base_intensity
			return { math.floor(r), math.floor(g), math.floor(b) }
		else
			-- Above center: yellow to red
			local t = (height_factor - 0.5) * 2
			local r = base_intensity
			local g = base_intensity * (1 - t * 0.7)
			local b = base_intensity * 0.2
			return { math.floor(r), math.floor(g), math.floor(b) }
		end
	else -- "distance" mode (default)
		-- Simple intensity-based coloring (closer = brighter)
		local intensity = 80 + (distance_factor * 175) -- Range: 80-255
		return { math.floor(intensity), math.floor(intensity), math.floor(intensity) }
	end
end

local render = function(self, points)
	local minX, maxX, minY, maxY = self:calculate_bounds(points)
	-- Filter points by spherical range if config.range is set
	local filtered = {}
	if self.cfg.range then
		for _, point in ipairs(points) do
			local dx = point.coords[1] - self.cfg.center_3d[1]
			local dy = point.coords[2] - self.cfg.center_3d[2]
			local dz = point.coords[3] - self.cfg.center_3d[3]
			local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
			if distance <= self.cfg.range then
				table.insert(filtered, point)
			end
		end
	else
		filtered = points
	end
	-- Draw grid
	if self.cfg.show_grid then
		self:draw_grid(minX, maxX, minY, maxY, points)
	end
	if self.cfg.show_axis then
		self:draw_axis(minX, maxX, minY, maxY)
	end
	-- Sort points by depth (Z-coordinate after transformation) for proper rendering order
	local points_by_depth = {}
	for _, point in ipairs(filtered) do
		local isoX, isoY = self:world_to_isometric(point.coords[1], point.coords[2], point.coords[3])
		-- Use negative Y as depth (points with larger Y render first, behind others)
		table.insert(points_by_depth, { point = point, isoX = isoX, isoY = isoY, depth = -isoY })
	end

	table.sort(points_by_depth, function(a, b)
		return a.depth < b.depth
	end)

	-- Draw points in depth order
	for _, entry in ipairs(points_by_depth) do
		local point = entry.point
		local screenX, screenY = self:isometric_to_screen(entry.isoX, entry.isoY, minX, maxX, minY, maxY)
		local color = point.color or self:color_by_distance(point)
		self.canvas:circle(screenX, screenY, math.floor(self.cfg.point_size * self.cfg.zoom), color)
	end
end

local new_isometric_projection = function(config, points)
	local default_config = {
		-- Isometric projection angles (in radians)
		angle_x = math.rad(30), -- Rotation around X-axis (use 26.565 angle for x for dimetric "video game" projection)
		angle_y = math.rad(45), -- Rotation around Y-axis
		scale_z = 1.0, -- Scale factor for Z-axis to reduce depth distortion
		zoom = 1.0, -- Zoom factor
		-- `center_3d` can be used to set a predefined center coordinates (otherwise it's calculated from the data):
		-- center_3d = { 0, 0, 0 },
		-- `range` can be used to specify a spherical filter radius from center_3d, e.g:
		-- range = 50, -- Only show points within 50 units from center
		--
		-- Canvas settings (in pixels)
		width = 800,
		height = 600,
		margin = 10, -- Margin around the plot area
		padding = 0.1, -- Padding of the plot area, percent of the data range
		point_size = 2, -- Radius of points in pixels
		grid_lines = 8, -- Number of grid lines per axis
		grid_coeff = 0.8, -- Whether grid shall cover the whole (1.0) data range, or less, or more.
		-- `grid_range` is calculated automatically, and can be manually overriden here
		show_grid = true,
		show_axis = true,
		color_mode = "distance",
		colors = {
			bg = { 0, 0, 0, 0 },
			grid = { 90, 90, 90, 255 },
			axis = { 150, 150, 150, 255 },
		},
	}
	std.tbl.merge(default_config, config)
	local canvas = new_canvas(default_config)
	local iso_proj = {
		cfg = default_config,
		canvas = canvas,
		world_to_isometric = world_to_isometric,
		isometric_to_screen = isometric_to_screen,
		calculate_bounds = calculate_bounds,
		draw_grid = draw_grid,
		draw_axis = draw_axis,
		color_by_distance = color_by_distance,
		render = render,
	}
	return iso_proj
end

return {
	send_data = send_data,
	send_cmd = send_cmd,
	delete_image = delete_image,
	new_canvas = new_canvas,
	new_isometric_projection = new_isometric_projection,
}
