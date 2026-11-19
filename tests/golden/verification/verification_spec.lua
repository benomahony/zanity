it("sends the receipt", function()
  local mailer = mock({ send = function() end, close = function() end })
  checkout(mailer)
  assert.spy(mailer.send).was.called_with("receipt")
  assert.spy(mailer.close).was_not_called()
end)

it("totals the basket", function()
  assert.are.equal(3, total({ 1, 2 }))
end)

local function assert_called_like_a_helper(s)
  assert.spy(s).was.called()
end
