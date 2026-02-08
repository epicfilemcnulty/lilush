math.randomseed(os.time())
local builtins = require("shell.builtins")
local builtin = builtins.get(cmd)
if builtin then
	return builtin.func(builtin.name, arg)
end
print("no such builtin:" .. tostring(cmd))
return -1
