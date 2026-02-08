local botls = require("botls")
math.randomseed(os.time())
local bot, err = botls.new_from_env()
if not bot then
	print("failed to init BOTLS: " .. tostring(err))
	os.exit(-1)
end
bot:manage()
