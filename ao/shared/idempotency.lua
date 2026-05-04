-- Simple in-memory idempotency registry (lookup/record) shared across AO procs.

local Idem = {}
local store = {}
local ttl = tonumber(os.getenv "IDEM_TTL_SECONDS" or "300")
local max_entries = tonumber(os.getenv "IDEM_MAX_ENTRIES" or "1024")

local function now()
  return os.time()
end

local function prune()
  local count = 0
  for k, v in pairs(store) do
    if v.expire_at and v.expire_at < now() then
      store[k] = nil
    else
      count = count + 1
    end
  end
  if count > max_entries then
    local oldest_k, oldest_ts
    for k, v in pairs(store) do
      if not oldest_ts or v.recorded_at < oldest_ts then
        oldest_ts, oldest_k = v.recorded_at, k
      end
    end
    if oldest_k then
      store[oldest_k] = nil
    end
  end
end

function Idem.lookup(request_id)
  prune()
  local v = store[request_id]
  if not v then
    return nil
  end
  return v.resp
end

-- Legacy-friendly helper used by processes; returns cached response or nil.
-- Kept separate from lookup to preserve call-sites that expect `check(...)`.
function Idem.check(request_id)
  return Idem.lookup(request_id)
end

function Idem.record(request_id, resp)
  prune()
  store[request_id] = {
    resp = resp,
    recorded_at = now(),
    expire_at = now() + ttl,
  }
end

return Idem
