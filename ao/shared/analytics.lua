-- Simple analytics/risk/subscription helpers (secretless, future-proof).
-- Counts via metrics and optionally appends NDJSON to METRICS_LOG.

local json_ok, json = pcall(require, "cjson.safe")
if not json_ok then
  json_ok, json = pcall(require, "cjson")
end
local metrics = require "ao.shared.metrics"

local Analytics = {}

local function encode_json(value)
  if not (json_ok and json and json.encode) then
    return nil
  end
  local ok, encoded = pcall(json.encode, value)
  if not ok then
    return nil
  end
  return encoded
end

local function write_log(ev)
  local path = os.getenv "METRICS_LOG"
  if not path or path == "" then
    return
  end
  local f = io.open(path, "a")
  if not f then
    return
  end
  ev.ts = os.date "!%Y-%m-%dT%H:%M:%SZ"
  local payload = encode_json(ev)
  if not payload then
    f:close()
    return
  end
  f:write(payload)
  f:write "\n"
  f:close()
end

function Analytics.page_view(site, path, locale)
  metrics.inc "ao_page_view"
  write_log { event = "page_view", site = site, path = path, locale = locale }
end

function Analytics.product_view(site, sku, locale)
  metrics.inc "ao_product_view"
  write_log { event = "product_view", site = site, sku = sku, locale = locale }
end

-- risk event: attrs should already be hashed/obfuscated
function Analytics.risk_event(kind, attrs)
  metrics.inc "ao_risk_event"
  local ev = attrs or {}
  ev.event = kind or "risk"
  write_log(ev)
end

function Analytics.subscription_start(site, plan, attrs)
  metrics.inc "ao_subscription_start"
  local ev = attrs or {}
  ev.event = "subscription_start"
  ev.site = site
  ev.plan = plan
  write_log(ev)
end

function Analytics.subscription_cancel(site, plan, reason, attrs)
  metrics.inc "ao_subscription_cancel"
  metrics.inc "ao_subscription_churn"
  local ev = attrs or {}
  ev.event = "subscription_cancel"
  ev.site = site
  ev.plan = plan
  ev.reason = reason
  write_log(ev)
end

return Analytics
