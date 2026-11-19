local function divide(value, divisor)
  local bad = value / 0
  local floored = value // 0
  local good = value / divisor
  local near_zero = value / 0.1
  return bad + floored + good + near_zero
end

return divide
