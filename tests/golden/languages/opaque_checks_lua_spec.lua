it("total includes tax", function()
  assert.is_true(total() == 110)
end)

it("receipt omits refunds", function()
  assert.is_false(receipt() ~= "paid")
end)

it("total stays under limit", function()
  assert.is_true(total() < LIMIT)
end)

it("total is positive", function()
  assert.is_true(total() > 0 and total() < LIMIT)
end)

it("total reads plainly", function()
  assert.are.equal(110, total())
end)

it("total with plain assert", function()
  assert(total() == 110)
end)
