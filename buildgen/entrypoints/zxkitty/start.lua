local zx = require("zx")
local args = { turbo = false, scale = 2, machine = os.getenv("ZX80_MACHINE_TYPE"), rom = os.getenv("ZX80_ROM_PATH") }
arg = arg or {}
for i, v in ipairs(arg) do
	if v == "-t" then
		args.turbo = true
	elseif v == "-s" then
		args.scale = tonumber(arg[i + 1]) or 2
	else
		args.program = v
	end
end
local emu = zx.new({ tape_turbo = args.turbo, scale = args.scale, machine = args.machine, rom_path = args.rom })
local ok, err = emu:run(args.program)
emu:close()
if not ok then
	print(err)
	os.exit(1)
end
