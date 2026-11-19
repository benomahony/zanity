local token = math.random(1, 2 ^ 31)
local safe_token = resty_random.bytes(16, true)
return token, safe_token
