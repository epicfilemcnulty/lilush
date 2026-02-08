local reliw = require("reliw")
math.randomseed(os.time())
local reliw_srv, err = reliw.new()
if not reliw_srv then
	print("failed to init RELIW: " .. tostring(err))
	os.exit(-1)
end
reliw_srv:run()
