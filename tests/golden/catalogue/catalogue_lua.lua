local M = {}

function M.flagged(x, items)
  if x then
  end
  for _ in ipairs(items) do
  end
  if true then
    x = 1
  end
  while false do
    x = 2
  end
  if x == 1.5 then
    x = 3
  end
  local db_password = "hunter2"
  debug.debug()
  mobdebug.start()
  for _, item in ipairs(items) do
    break
    x = item
  end
  return x
end

function M.quiet(x, items)
  if x then
    -- nothing to do until the cache is warm
  end
  if x == 0.0 then
    x = 1
  end
  local y = x == 10
  local ok = pcall(items.close, items)
  local password_env = "DB_PASSWORD"
  local token_type = "Bearer"
  local empty_secret = ""
  for _, item in ipairs(items) do
    if item then
      goto continue
    end
    x = item
    ::continue::
  end
  return x, y, ok
end

function M.stub() end

return M
