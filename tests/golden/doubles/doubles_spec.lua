local mailer = require("mailer")

it("sends the receipt", function()
  local send = spy.on(mailer, "send")
  local clock = stub(os, "time")
  checkout()
  assert.are.equal(1, #outbox())
end)

it("totals the basket", function()
  assert.are.equal(3, total({ 1, 2 }))
end)
