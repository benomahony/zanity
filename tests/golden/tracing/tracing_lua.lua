local tracer = require("opentelemetry.global").tracer("billing")

local M = {}

function M.charge(ctx, id)
  local ctx, span = tracer:start(ctx, "charge")
  return use(ctx, id)
end

function M.refund(ctx, id)
  local ctx, span = tracer:start(ctx, "refund")
  local ok = use(ctx, id)
  span:finish()
  return ok
end

function M.detached(ctx, id)
  local _, span = tracer:start(ctx, "detached")
  local ok = use(ctx, id)
  span:finish()
  return ok
end

function M.concatenated(ctx, id)
  local ctx, span = tracer:start(ctx, "charge " .. id)
  local ok = use(ctx, id)
  span:finish()
  return ok
end

function M.formatted(ctx, id)
  local ctx, span = tracer:start(ctx, string.format("charge %s", id))
  local ok = use(ctx, id)
  span:finish()
  return ok
end

function M.paired(engine)
  local first, second = engine:start()
  return use(first, second)
end

function M.started(pool, cfg)
  local srv, err = pool:start(cfg)
  return srv, err
end

function M.start_op(ctx)
  local ctx, span = tracer:start(ctx, "op")
  span:set_attributes()
  return ctx, span
end

function M:keep(ctx)
  local ctx, span = tracer:start(ctx, "keep")
  self.span = span
  self.ctx = ctx
end

return M
