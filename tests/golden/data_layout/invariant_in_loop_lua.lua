local function count(lines, word)
  local found = 0
  for _, line in ipairs(lines) do
    if string.find(line, string.lower(word)) then
      found = found + 1
    end
  end
  return found
end

local function each(lines)
  local found = 0
  for _, line in ipairs(lines) do
    found = found + #string.lower(line)
  end
  return found
end

return { count = count, each = each }
