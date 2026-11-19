local port = tonumber(arg[1])
local code = tonumber(arg[2], 10)
local mask = tonumber("ff", 16)
return port, code, mask
