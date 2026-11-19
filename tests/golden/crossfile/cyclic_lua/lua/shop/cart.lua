local items = require("shop.items")

local M = {}

function M.add(cart, sku)
  table.insert(cart, items.find(sku))
end

return M
