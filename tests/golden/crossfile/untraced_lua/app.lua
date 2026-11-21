local lapis = require("lapis")
local handlers = require("handlers")
local tracer = require("opentelemetry.global").get_tracer_provider():tracer("orders")

local app = lapis.Application()

app:get("/orders/:id", function(self)
  return { json = { id = self.params.id } }
end)

app:post("/orders", function(self)
  local context, span = tracer:start(self.context, "create_order")
  span:finish()
  return { json = context }
end)

app:post("/refunds", handlers.refund)
app:post("/charges", handlers.charge)

return app
