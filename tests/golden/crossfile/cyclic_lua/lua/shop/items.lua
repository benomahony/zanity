local cart = require("shop.cart")

local M = {}

function M.find(sku)
  return { sku = sku }
end

function M.restock(basket, sku)
  cart.add(basket, sku)
end

return M
