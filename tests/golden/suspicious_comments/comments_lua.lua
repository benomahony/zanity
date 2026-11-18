-- FIXME: this accepts expired credentials.
local function authenticate(token)
  return token ~= nil
end

-- Debug output is intentionally disabled; bugfix links belong in the issue tracker.
local function quiet()
  return true
end

return { authenticate = authenticate, quiet = quiet }
