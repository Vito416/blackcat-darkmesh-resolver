-- Minimal metrics stub: counts and durations written to NDJSON file (mock-friendly).

local Metrics = {}

local LOG_PATH = os.getenv "METRICS_LOG" or "metrics/metrics.log"
local ENABLED = os.getenv "METRICS_ENABLED" ~= "0"
local PROM_PATH = os.getenv "METRICS_PROM_PATH"
local PROM_MODE = os.getenv "METRICS_PROM_MODE"
local FLUSH_EVERY = tonumber(os.getenv "METRICS_FLUSH_EVERY" or "0")
local FLUSH_INTERVAL = tonumber(os.getenv "METRICS_FLUSH_INTERVAL_SEC" or "0")
local counters = {}
local gauges = {}
local meta = {}
local since_flush = 0
local last_flush = os.time()
local timer = require "ao.shared.timer"
local lfs_ok, lfs = pcall(require, "lfs")
local started = false

local function register(name, kind, help)
  if not name then
    return
  end
  meta[name] = meta[name] or {}
  meta[name].type = kind or meta[name].type or "counter"
  if help then
    meta[name].help = help
  end
end

Metrics.register = register

local function ensure_dir(path)
  local dir = path:match "(.+)/[^/]+$"
  if dir then
    os.execute(string.format('mkdir -p "%s"', dir))
  end
end

local function log(event)
  if not ENABLED or not LOG_PATH then
    return
  end
  ensure_dir(LOG_PATH)
  local f = io.open(LOG_PATH, "a")
  if not f then
    return
  end
  f:write(
    string.format(
      '{"ts":"%s","event":"%s","value":%s}\n',
      os.date "!%Y-%m-%dT%H:%M:%SZ",
      event.name or "metric",
      event.value or 0
    )
  )
  f:close()
end

local function enforce_prom_mode(path)
  if not PROM_MODE or PROM_MODE == "" then
    return
  end
  os.execute(string.format('chmod %s "%s"', PROM_MODE, path))
end

function Metrics.inc(name, value)
  if os.getenv "METRICS_DISABLED" == "1" then
    return
  end
  value = value or 1
  register(name, "counter")
  counters[name] = (counters[name] or 0) + value
  log { name = name, value = counters[name] }
  since_flush = since_flush + 1
  if FLUSH_EVERY > 0 and since_flush >= FLUSH_EVERY then
    Metrics.flush_prom()
    since_flush = 0
  elseif FLUSH_EVERY == 0 then
    Metrics.flush_prom()
  end
end

function Metrics.tick()
  if os.getenv "METRICS_DISABLED" == "1" then
    return
  end
  local now = os.time()
  if FLUSH_INTERVAL > 0 and (now - last_flush) >= FLUSH_INTERVAL then
    Metrics.flush_prom()
    last_flush = now
    since_flush = 0
  end
  if FLUSH_INTERVAL > 0 then
    timer.start(FLUSH_INTERVAL, Metrics.flush_prom)
  end
end

function Metrics.flush_prom()
  if not PROM_PATH then
    return
  end
  -- optional gauges sourced from queue files so gateway can scrape them
  local function file_lines(path)
    if not path or path == "" then
      return nil
    end
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local n = 0
    for _ in f:lines() do
      n = n + 1
    end
    f:close()
    return n
  end
  local queue_path = os.getenv "AO_QUEUE_PATH"
  local retry_path = os.getenv "AO_WEBHOOK_RETRY_PATH" or os.getenv "AO_RETRY_QUEUE_PATH"
  local breaker_flag = os.getenv "AO_PSP_BREAKER_FLAG"
  local outbox_size = file_lines(queue_path)
  local retry_size = file_lines(retry_path)
  local function file_mtime(path)
    if not lfs_ok or not path or path == "" then
      return nil
    end
    local st = lfs.attributes(path)
    return st and st.modification or nil
  end
  if outbox_size then
    register("ao_outbox_queue_size", "gauge", "Lines present in AO outbox queue file")
    gauges.ao_outbox_queue_size = outbox_size
  end
  local mtime = file_mtime(queue_path)
  if mtime then
    register("ao_outbox_lag_seconds", "gauge", "Seconds since outbox queue file was updated")
    gauges.ao_outbox_lag_seconds = math.max(0, os.time() - mtime)
  end
  if retry_size then
    register("ao_webhook_retry_queue_size", "gauge", "Pending webhook retry queue length")
    gauges.ao_webhook_retry_queue_size = retry_size
  end
  if breaker_flag then
    local bf = io.open(breaker_flag, "r")
    if bf then
      local val = bf:read "*l"
      bf:close()
      register("ao_psp_breaker_open", "gauge", "Payment provider breaker flag (1=open)")
      gauges.ao_psp_breaker_open = tonumber(val) or 0
    end
  end
  local function prom_sanitize(name)
    return (name or "metric"):gsub("[^%w_]", "_")
  end
  local function prom_name(name, kind)
    local base = prom_sanitize(name)
    if kind == "counter" and not base:match "_total$" then
      return base .. "_total"
    end
    return base
  end
  local emitted = {}
  ensure_dir(PROM_PATH)
  local f = io.open(PROM_PATH, "w")
  if not f then
    return
  end
  local function emit(name, kind, value)
    local cfg = meta[name] or { type = kind }
    local pname = prom_name(name, cfg.type or kind)
    if not emitted[pname] then
      if cfg.help then
        f:write(string.format("# HELP %s %s\n", pname, cfg.help))
      end
      f:write(string.format("# TYPE %s %s\n", pname, cfg.type or kind))
      emitted[pname] = true
    end
    f:write(string.format("%s %s\n", pname, tostring(value)))
  end
  for k, v in pairs(counters) do
    emit(k, "counter", v)
  end
  for k, v in pairs(gauges) do
    emit(k, "gauge", v)
  end
  f:close()
  enforce_prom_mode(PROM_PATH)
end

function Metrics.last_flush_ts()
  return last_flush
end

function Metrics.get(name)
  return counters[name] or 0
end

function Metrics.counter(name, value)
  Metrics.inc(name, value)
end

function Metrics.gauge(name, value)
  if os.getenv "METRICS_DISABLED" == "1" then
    return
  end
  register(name, "gauge")
  gauges[name] = value
  log { name = name, value = value }
end

function Metrics._reset()
  counters = {}
  gauges = {}
end

function Metrics.get_gauge(name)
  return gauges[name]
end

function Metrics.start_background()
  if started then
    return
  end
  started = true
  if FLUSH_INTERVAL > 0 then
    timer.start(FLUSH_INTERVAL, Metrics.flush_prom)
  end
end

-- Register common AO metrics used by ops/alerts so they get HELP/TYPE lines.
local default_meta = {
  ao_ingest_apply_ok = { type = "counter", help = "AO ingest events applied successfully" },
  ao_ingest_apply_failed = { type = "counter", help = "AO ingest apply failures" },
  ao_cache_hit = { type = "counter", help = "Cache hits served from AO cache" },
  ao_cache_miss = { type = "counter", help = "Cache misses (recompute)" },
  ao_cache_stale_hit = { type = "counter", help = "Stale cache entries served" },
  ao_cache_stale_fallback = {
    type = "counter",
    help = "Served stale cache because fresh computation failed",
  },
  ao_sitemap_export_total = { type = "counter", help = "Sitemap exports executed" },
  ao_sitemap_export_duration_seconds = {
    type = "gauge",
    help = "Duration of last sitemap export in seconds",
  },
  ao_feed_export_total = { type = "counter", help = "Catalog feed exports executed" },
  ao_feed_export_failed = { type = "counter", help = "Catalog feed export failures" },
  ao_feed_export_duration_seconds = {
    type = "gauge",
    help = "Duration of last catalog feed export in seconds",
  },
  ao_page_view_total = { type = "counter", help = "Page view events emitted" },
  ao_product_view_total = { type = "counter", help = "Product view events emitted" },
  ao_risk_event_total = { type = "counter", help = "Risk signals emitted" },
  ao_subscription_start_total = { type = "counter", help = "Subscriptions started" },
  ao_subscription_cancel_total = { type = "counter", help = "Subscriptions cancelled" },
  ao_subscription_churn_total = { type = "counter", help = "Subscription churn events" },
  ao_outbox_queue_size = {
    type = "gauge",
    help = "Lines present in AO outbox queue file (write side export)",
  },
  ao_outbox_lag_seconds = {
    type = "gauge",
    help = "Seconds since outbox queue file was last updated",
  },
  ao_webhook_retry_queue_size = {
    type = "gauge",
    help = "Webhook retry queue size from write bridge",
  },
  ao_psp_breaker_open = { type = "gauge", help = "Breaker flag value (1=open) for PSP webhooks" },
}

for name, cfg in pairs(default_meta) do
  register(name, cfg.type, cfg.help)
end

-- auto-start if interval specified
Metrics.start_background()

return Metrics
