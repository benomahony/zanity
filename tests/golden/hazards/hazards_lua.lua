local M = {}

function M.flagged(db, name, api_token, data, x)
  if not x == "a" then
    x = 1
  end
  https.request({ url = name, verify = "none" })
  ngx.md5(data)
  os.execute("ls " .. name)
  db:query("SELECT * FROM users WHERE name = '" .. name .. "'")
  local elapsed = os.time() - x
  print("using", api_token)
  if x then
    for _, y in ipairs(data) do
      if y then
        while y do
          if y > 1 then
            y = y - 1
          end
        end
      end
    end
  end
  return elapsed
end

function M.quiet(db, name, token, data, x)
  if not (x == "a") then
    x = 1
  end
  https.request({ url = name, verify = "peer" })
  ngx.sha256(data)
  os.execute("ls")
  db:query("SELECT * FROM users WHERE name = ?", name)
  local start = os.clock()
  print("parsed token", #token)
  return start
end

function M.classify(n)
  if n == 0 then
    return 0
  elseif n == 1 then
    return 1
  elseif n == 2 then
    return 2
  elseif n == 3 then
    return 3
  elseif n == 4 then
    return 4
  elseif n == 5 then
    return 5
  elseif n == 6 then
    return 6
  elseif n == 7 then
    return 7
  elseif n == 8 then
    return 8
  elseif n == 9 then
    return 9
  elseif n == 10 then
    return 10
  elseif n == 11 then
    return 11
  elseif n == 12 then
    return 12
  elseif n == 13 then
    return 13
  elseif n == 14 then
    return 14
  elseif n == 15 then
    return 15
  end
  return -1
end

function M.differs(a, b)
  return not a ~= b
end

function M.vimscript(helpers, path)
  helpers.exec("set rtp+=" .. path)
end

return M
