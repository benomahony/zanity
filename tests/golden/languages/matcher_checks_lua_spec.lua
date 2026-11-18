it("total includes tax", function()
  assert.are.equal(110, total())
end)

it("total rounds to cents", function()
  lu.assertEquals(total(), 110)
end)

it("total prints receipt", function()
  print(total())
end)

function TestTotal:test_prints_receipt()
  print(total())
end

function TestTotal:test_rounds_to_cents()
  lu.assertEquals(total(), 110)
end
