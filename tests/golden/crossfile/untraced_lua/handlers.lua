local tracer = require("opentelemetry.global").get_tracer_provider():tracer("handlers")

local handlers = {}

function handlers.refund(self)
  return { json = { refunded = true } }
end

function handlers.charge(self)
  local context, span = tracer:start(self.context, "charge")
  span:finish()
  return { json = context }
end

function handlers.price(cache)
  return cache:get("small")
end

return handlers
