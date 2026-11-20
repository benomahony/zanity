local function labels(values)
  local out = {}
  for i, value in ipairs(values) do
    out[i] = string.format("%d", value)
  end
  return out
end

return labels
