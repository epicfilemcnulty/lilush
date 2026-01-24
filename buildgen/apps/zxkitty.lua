local start_code = [[
static const char START_CODE[] =
  "local zx = require('zx')\n"
  "local args = { turbo = false, scale = 2, machine = os.getenv('ZX80_MACHINE_TYPE'), rom = os.getenv('ZX80_ROM_PATH') }\n"
  "arg = arg or {}\n"
  "for i, v in ipairs(arg) do\n"
  "  if v == '-t' then\n"
  "    args.turbo = true\n"
  "  elseif v == '-s' then\n"
  "    args.scale = tonumber(arg[i+1]) or 2\n"
  "  else\n"
  "    args.program = v\n"
  "  end\n"
  "end\n"
  "local emu = zx.new({ tape_turbo = args.turbo, scale = args.scale, machine = args.machine, rom_path = args.rom })\n"
  "local ok, err = emu:run(args.program)\n"
  "emu:close()\n"
  "if not ok then\n"
  "  print(err)\n"
  "  os.exit(1)\n"
  "end\n";
]]

local custom_main = [[
int main(int argc, char **argv) {
    int error;
    lua_State *L = luaL_newstate();
    preload_modules(L);
 
    if (argc > 1) {
        if (strcmp(argv[1], "-v") == 0) {
            fprintf(stdout, "version {{VERSION}}\n");
            return 0;
        }
        int args = argc - 1;
        lua_createtable(L, args, args);
        int i;
        for (i = 1; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i);
        }
        lua_setglobal(L, "arg");
        error = luaL_dostring(L, START_CODE);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }
    fprintf(stderr, "Provide a path to TZX/TAP/Z80 file\n");
    return 1;
}
]]

return {
	binary = "zxkitty",
	luamods = {
		"luasocket",
		"std",
		"term",
		"zx",
	},
	c_libs = {
		"luasocket",
		"cjson",
		"std",
		"term",
		"zx",
	},
	install_path = "/usr/local/bin/zxkitty",
	start_code = start_code,
	custom_main = custom_main,
}
