local function doubled(values)
  local out = {}
  for _, value in ipairs(values) do
    table.insert(out, value * 2)
  end
  return out
end

return doubled
