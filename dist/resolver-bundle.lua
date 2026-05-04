-- bundled AO process (resolver)

package.preload["ao.shared.a11y"] = function()
  local loaded, err = load([====[-- Simple accessibility & performance lint for page content blocks.

local A11y = {}

local function warn(list, msg)
  table.insert(list, msg)
end

-- Validate a single block; return warnings appended to provided list.
local function validate_block(block, warnings, last_heading_level)
  local typ = block.type or block.kind
  if typ == "image" or typ == "hero" then
    if not block.alt or block.alt == "" then
      warn(warnings, "Image block missing alt text")
    end
  elseif typ == "link" then
    if not block.text or block.text == "" then
      warn(warnings, "Link block missing text")
    end
    if block.href and block.href:match "^javascript:" then
      warn(warnings, "Link uses javascript: URI, avoid for accessibility")
    end
  elseif typ == "heading" then
    local level = tonumber(block.level or block.depth or 0) or 0
    if level < 1 or level > 6 then
      warn(warnings, "Heading level must be 1-6")
    elseif last_heading_level and level > last_heading_level + 1 then
      warn(
        warnings,
        string.format("Heading level skips from h%d to h%d", last_heading_level, level)
      )
    end
    return level
  end
  return last_heading_level
end

---Validate a page content table (expects blocks array).
-- Returns ok:boolean, warnings:table
function A11y.validate_page(content)
  local warnings = {}
  if not content or type(content) ~= "table" then
    return true, warnings
  end
  local blocks = content.blocks or {}
  local last_heading_level = nil
  for _, block in ipairs(blocks) do
    last_heading_level = validate_block(block, warnings, last_heading_level)
  end
  return #warnings == 0, warnings
end

return A11y
]====], "ao.shared.a11y")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.analytics"] = function()
  local loaded, err = load([====[-- Simple analytics/risk/subscription helpers (secretless, future-proof).
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
]====], "ao.shared.analytics")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.arweave"] = function()
  local loaded, err = load([====[-- Arweave adapter for publish flow.
-- Default mode: file-backed mock under arweave/snapshots (deterministic, hash checked).
-- If ARWEAVE_MODE=mock (default), nothing leaves the machine.

local Ar = {}

local counter = 0
local manifests = {}

local MODE = os.getenv "ARWEAVE_MODE" or "mock"
local SNAPSHOT_DIR = os.getenv "ARWEAVE_STORAGE_DIR" or "arweave/snapshots"
local REQUEST_LOG = os.getenv "ARWEAVE_REQUEST_LOG" or "arweave/manifests"
local ENDPOINT = os.getenv "ARWEAVE_HTTP_ENDPOINT"
local API_KEY = os.getenv "ARWEAVE_HTTP_API_KEY"
local SIGNER = os.getenv "ARWEAVE_HTTP_SIGNER" -- path to key or wallet JSON
local HTTP_TIMEOUT = tonumber(os.getenv "ARWEAVE_HTTP_TIMEOUT" or "10")
local HTTP_REAL = os.getenv "ARWEAVE_HTTP_REAL" == "1"
local HTTP_SIGNER_HEADER = os.getenv "ARWEAVE_HTTP_SIGNER_HEADER" or "X-Arweave-Signer"
local HTTP_RETRIES = tonumber(os.getenv "ARWEAVE_HTTP_RETRIES" or "3")
local HTTP_BACKOFF_MS = tonumber(os.getenv "ARWEAVE_HTTP_BACKOFF_MS" or "200")
local MAX_MANIFEST_BYTES = tonumber(os.getenv "ARWEAVE_MAX_MANIFEST_BYTES" or "262144") -- 256 KiB
local HTTP_MAX_BODY = tonumber(os.getenv "ARWEAVE_HTTP_MAX_BODY" or "1048576") -- 1 MiB
local EXPECT_RESPONSE_HASH = os.getenv "ARWEAVE_EXPECT_RESPONSE_HASH"
local FORCE_ERROR = os.getenv "ARWEAVE_FORCE_ERROR" == "1"
local RESPONSE_PATTERN = os.getenv "ARWEAVE_RESPONSE_PATTERN" or '^%s*%{"'
local _, cjson_safe = pcall(require, "cjson.safe")
local cjson = cjson_safe or require "cjson" -- required dependency
local schema = require "ao.shared.schema"
local openssl_ok, openssl = pcall(require, "openssl")
local sodium_ok, sodium = pcall(require, "sodium")
if not sodium_ok then
  sodium_ok, sodium = pcall(require, "luasodium")
end

local function next_tx()
  counter = counter + 1
  return string.format("mock-tx-%06d", counter)
end

local function ensure_dir(path)
  os.execute(string.format('mkdir -p "%s"', path))
end

local function bin_to_hex(bytes)
  return (bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function sha256(str)
  if openssl_ok and openssl.digest then
    local d = openssl.digest.new "sha256"
    d:update(str)
    return bin_to_hex(d:final())
  elseif sodium_ok and sodium.crypto_hash_sha256 then
    return bin_to_hex(sodium.crypto_hash_sha256(str))
  else
    local r = io.popen(
      'printf %s "'
        .. str:gsub('"', '\\"')
        .. '" | openssl dgst -sha256 -binary 2>/dev/null | xxd -p',
      "r"
    )
    if r then
      local out = r:read "*a" or ""
      r:close()
      out = out:gsub("%s+", "")
      if #out > 0 then
        return out
      end
    end
  end
  return nil
end

local function file_sha256(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read "*a"
  f:close()
  return sha256(content)
end

local function has_curl()
  local ok = os.execute "command -v curl >/dev/null 2>&1"
  return ok == true or ok == 0
end

local function http_post(serialized, tx)
  ensure_dir(REQUEST_LOG)
  local response_path = string.format("%s/%s-response.json", REQUEST_LOG, tx)
  local auth_header = API_KEY and (' -H "Authorization: Bearer ' .. API_KEY .. '"') or ""
  local signer_header = SIGNER and (' -H "' .. HTTP_SIGNER_HEADER .. ": " .. SIGNER .. '"') or ""
  local curl_fmt = table.concat({
    'echo %q | curl -s -o "%s" -w "%%{http_code}"',
    '-H "Content-Type: application/json"%s%s',
    '--max-time %d -X POST "%s" --data-binary @-',
  }, " ")
  local status
  for attempt = 1, HTTP_RETRIES do
    local cmd = string.format(
      curl_fmt,
      serialized,
      response_path,
      auth_header,
      signer_header,
      HTTP_TIMEOUT,
      ENDPOINT or ""
    )
    local pipe = io.popen(cmd, "r")
    if pipe then
      status = pipe:read "*a"
      pipe:close()
      status = status and status:match "(%d+)"
      if status then
        status = tonumber(status)
      end
      if status and status < 500 then
        break
      end
    end
    if attempt < HTTP_RETRIES then
      local jitter = math.random() * 0.5 + 0.75 -- 0.75-1.25x
      os.execute(string.format("sleep %.3f", (HTTP_BACKOFF_MS * jitter) / 1000))
    end
  end
  return status, response_path
end

local function signer_exists()
  if not SIGNER or SIGNER == "" then
    return true
  end
  local f = io.open(SIGNER, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function fallback_checksum(str)
  local sum = 0
  for i = 1, #str do
    sum = (sum + string.byte(str, i)) % 0xFFFFFFFF
  end
  return string.format("%08x", sum)
end

local function is_array(tbl)
  local i = 0
  for _ in pairs(tbl) do
    i = i + 1
    if tbl[i] == nil then
      return false
    end
  end
  return true
end

local function sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function json_encode(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" then
    return value and "true" or "false"
  end
  if t == "number" then
    return tostring(value)
  end
  if t == "string" then
    return string.format("%q", value)
  end
  if t == "table" then
    if is_array(value) then
      local parts = {}
      for _, v in ipairs(value) do
        table.insert(parts, json_encode(v))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for _, k in ipairs(sorted_keys(value)) do
        local v = value[k]
        table.insert(parts, string.format("%q:%s", k, json_encode(v)))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return '"<unsupported>"'
end

local function persist_manifest(tx, content)
  ensure_dir(SNAPSHOT_DIR)
  local path = SNAPSHOT_DIR .. "/" .. tx .. ".json"
  local f = io.open(path, "w")
  if f then
    f:write(content)
    f:close()
  end
end

-- Stores a snapshot payload and returns a manifest transaction id and hash.
function Ar.put_snapshot(payload)
  local tx = next_tx()
  local serialized = json_encode(payload)
  if MAX_MANIFEST_BYTES and #serialized > MAX_MANIFEST_BYTES then
    return nil, "too_large"
  end
  local hash = sha256(serialized) or fallback_checksum(serialized)

  manifests[tx] = {
    payload = payload,
    hash = hash,
    storedAt = os.date "!%Y-%m-%dT%H:%M:%SZ",
  }

  if MODE == "mock" then
    persist_manifest(tx, serialized)
  end

  return tx, hash
end

function Ar.get_snapshot(tx)
  return manifests[tx]
end

function Ar.verify_snapshot(tx, expected_hash)
  local m = manifests[tx]
  if not m then
    return false, "not_found"
  end
  if expected_hash and m.hash ~= expected_hash then
    return false, "hash_mismatch"
  end
  return true
end

-- HTTP mode placeholder: log outbound request; real network disabled here.
local function log_request(tx, payload, hash)
  ensure_dir(REQUEST_LOG)
  local path = string.format("%s/%s-request.json", REQUEST_LOG, tx)
  local f = io.open(path, "w")
  if f then
    f:write(json_encode { tx = tx, hash = hash, payload = payload, mode = MODE })
    f:close()
  end
end

if MODE == "http" then
  -- Simulated HTTP call: writes request + simulated response status to manifests log.
  -- Still offline/off-chain; safe for local runs.
  function Ar.put_snapshot(payload)
    local tx = next_tx()
    local serialized = json_encode(payload)
    if MAX_MANIFEST_BYTES and #serialized > MAX_MANIFEST_BYTES then
      return nil, "too_large"
    end
    local hash = sha256(serialized) or fallback_checksum(serialized)
    local httpStatus, response_path
    if FORCE_ERROR then
      httpStatus = 500
    elseif HTTP_REAL and ENDPOINT and has_curl() and os.getenv "ARWEAVE_HTTP_DRYRUN" ~= "1" then
      if not signer_exists() then
        log_request(tx, {
          endpoint = ENDPOINT or "<missing-endpoint>",
          apiKey = API_KEY and "<redacted>",
          signer = SIGNER or "<missing>",
          timeout = HTTP_TIMEOUT,
          body = payload,
          simulated = true,
          error = "signer_missing",
        }, hash)
        return tx, hash
      end
      httpStatus, response_path = http_post(serialized, tx)
    else
      -- offline simulated response body so schema validation/path logic still runs
      ensure_dir(REQUEST_LOG)
      response_path = string.format("%s/%s-response.json", REQUEST_LOG, tx)
      local body = os.getenv "ARWEAVE_HTTP_SIM_BODY"
        or string.format('{"status":"ok","tx":"%s"}', tx)
      local f = io.open(response_path, "w")
      if f then
        f:write(body)
        f:close()
      end
      httpStatus = tonumber(os.getenv "ARWEAVE_HTTP_SIM_STATUS" or "200")
    end
    local signerHash = SIGNER and file_sha256(SIGNER) or nil
    if httpStatus and httpStatus >= 400 then
      log_request(tx, { error = "http_error", status = httpStatus })
      return nil, "http_error"
    end
    if response_path then
      local f = io.open(response_path, "r")
      if f then
        local body = f:read "*a" or ""
        f:close()
        if #body == 0 then
          log_request(tx, { warning = "empty_response" })
        elseif HTTP_MAX_BODY and #body > HTTP_MAX_BODY then
          log_request(tx, { error = "response_too_large", size = #body })
          return nil, "http_response_too_large"
        else
          if RESPONSE_PATTERN and not body:match(RESPONSE_PATTERN) then
            log_request(tx, { warning = "response_unexpected_pattern" })
            return nil, "http_response_invalid"
          end
          local parsed = cjson.decode(body)
          if not parsed then
            return nil, "http_response_invalid_json"
          end
          local ok_schema, err_schema = schema.validate("arweaveResponse", parsed)
          if not ok_schema then
            log_request(tx, { warning = "response_schema_invalid", errors = err_schema })
            return nil, "http_response_schema_invalid"
          end
          local resp_hash = sha256(body)
          if not resp_hash then
            log_request(tx, { warning = "response_hash_failed" })
          else
            log_request(tx, { responseHash = resp_hash })
            if EXPECT_RESPONSE_HASH and resp_hash ~= EXPECT_RESPONSE_HASH then
              return nil, "response_hash_mismatch"
            end
          end
        end
      end
    end
    log_request(tx, {
      endpoint = ENDPOINT or "<missing-endpoint>",
      apiKey = API_KEY and "<redacted>",
      signer = SIGNER and "<redacted>",
      signerHash = signerHash,
      timeout = HTTP_TIMEOUT,
      body = payload,
      simulated = not HTTP_REAL,
      httpStatus = httpStatus,
      responsePath = response_path,
    }, hash)
    return tx, hash
  end
end

-- Expose for tests
Ar._manifests = manifests

return Ar
]====], "ao.shared.arweave")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.assets"] = function()
  local loaded, err = load([====[-- Asset helpers: generate responsive variants and minimal CDN invalidation hooks.

local Assets = {}

local DEFAULT_SIZES = { 320, 640, 960, 1280, 1920 }
local DEFAULT_FORMATS = { "avif", "webp", "jpg" }

local function normalize_formats(formats)
  if not formats or #formats == 0 then
    return DEFAULT_FORMATS
  end
  local out = {}
  local seen = {}
  for _, f in ipairs(formats) do
    local fmt = tostring(f):lower()
    if not seen[fmt] then
      table.insert(out, fmt)
      seen[fmt] = true
    end
  end
  return out
end

local function normalize_sizes(sizes)
  if not sizes or #sizes == 0 then
    return DEFAULT_SIZES
  end
  local out = {}
  for _, s in ipairs(sizes) do
    local n = tonumber(s)
    if n and n > 0 then
      table.insert(out, math.floor(n))
    end
  end
  table.sort(out)
  return out
end

local function build_url(base_url, path)
  if not base_url or base_url == "" then
    return path
  end
  if base_url:sub(-1) == "/" then
    base_url = base_url:sub(1, -2)
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return base_url .. path
end

---Generate responsive variants for an image using a deterministic URL pattern.
-- The pattern is: {base}/{width}w/{basename}.{format}
function Assets.build_image_variants(src, opts)
  opts = opts or {}
  local sizes = normalize_sizes(opts.sizes)
  local formats = normalize_formats(opts.formats)
  local base_url = opts.base_url or os.getenv "ASSET_BASE_URL" or "/assets"

  local basename = src:gsub("^.*/", "")
  local variants = {}
  local srcset = {}

  for _, fmt in ipairs(formats) do
    srcset[fmt] = {}
    for _, w in ipairs(sizes) do
      local path = string.format("%dw/%s.%s", w, basename, fmt)
      local url = build_url(base_url, path)
      table.insert(srcset[fmt], string.format("%s %dw", url, w))
      table.insert(variants, { width = w, format = fmt, url = url })
    end
    srcset[fmt] = table.concat(srcset[fmt], ", ")
  end

  return {
    src = build_url(base_url, basename),
    sizes = sizes,
    formats = formats,
    variants = variants,
    srcset = srcset,
    loading = "lazy",
    placeholder = "blur",
  }
end

-- Lightweight CDN purge hook; caller passes relative or absolute paths.
function Assets.cdn_invalidate(paths)
  if type(paths) ~= "table" or #paths == 0 then
    return { purged = 0 }
  end
  local purged = 0
  local endpoint = os.getenv "CDN_PURGE_URL"
  for _, path in ipairs(paths) do
    if endpoint and endpoint ~= "" then
      os.execute(string.format("curl -s -X PURGE %s%s >/dev/null 2>&1", endpoint, path))
    else
      -- fallback: no-op echo
      os.execute(string.format('echo "PURGE %s" >/dev/null', path))
    end
    purged = purged + 1
  end
  return { purged = purged }
end

return Assets
]====], "ao.shared.assets")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.audit"] = function()
  local loaded, err = load([====[-- Append-only audit stub for local testing.

local Audit = {}
local records = {}
local LOG_DIR = os.getenv "AUDIT_LOG_DIR" or "arweave/manifests"
local MAX_IN_MEMORY = tonumber(os.getenv "AUDIT_MAX_RECORDS" or "1000")
local FORMAT = os.getenv "AUDIT_FORMAT" or "line" -- line | ndjson
local ROTATE_MAX = tonumber(os.getenv "AUDIT_ROTATE_MAX" or "1048576") -- bytes
local RETAIN_FILES = tonumber(os.getenv "AUDIT_RETAIN_FILES" or "10") -- number of rotated files per stream

local function ensure_dir(path)
  os.execute(string.format('mkdir -p "%s"', path))
end

local function is_array(tbl)
  local i = 0
  for _ in pairs(tbl) do
    i = i + 1
    if tbl[i] == nil then
      return false
    end
  end
  return true
end

local function json_encode(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" then
    return value and "true" or "false"
  end
  if t == "number" then
    return tostring(value)
  end
  if t == "string" then
    return string.format("%q", value)
  end
  if t == "table" then
    if is_array(value) then
      local parts = {}
      for _, v in ipairs(value) do
        table.insert(parts, json_encode(v))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(value) do
        table.insert(parts, string.format("%q:%s", k, json_encode(v)))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return '"<unsupported>"'
end

local lfs_ok, lfs = pcall(require, "lfs")

local function rotate_if_needed(path)
  if not path or path == "" then
    return
  end
  local f = io.open(path, "r")
  if not f then
    return
  end
  local content = f:read "*a"
  f:close()
  if #content >= ROTATE_MAX then
    local rotated = path .. "." .. os.date "!%Y%m%d%H%M%S"
    os.rename(path, rotated)
    if lfs_ok then
      -- retention
      local dir, file = path:match "(.+)/([^/]+)$"
      local prefix = file .. "."
      local rotated_files = {}
      for rfile in lfs.dir(dir) do
        if rfile:find("^" .. prefix) then
          table.insert(rotated_files, dir .. "/" .. rfile)
        end
      end
      table.sort(rotated_files, function(a, b)
        return a > b
      end) -- newest first (lexicographic on timestamp suffix)
      for i = RETAIN_FILES + 1, #rotated_files do
        os.remove(rotated_files[i])
      end
    end
  end
end

function Audit.append(entry)
  if os.getenv "AUDIT_DISABLE" == "1" then
    return true
  end
  if not entry.ts then
    entry.ts = os.date "!%Y-%m-%dT%H:%M:%SZ"
  end
  table.insert(records, entry)
  if #records > MAX_IN_MEMORY then
    table.remove(records, 1)
  end
  if LOG_DIR then
    ensure_dir(LOG_DIR)
    local path = string.format("%s/audit.log", LOG_DIR)
    rotate_if_needed(path)
    local f = io.open(path, "a")
    if f then
      if FORMAT == "ndjson" then
        f:write(json_encode(entry), "\n")
      else
        f:write(tostring(entry.action or "event"), " ", json_encode(entry), "\n")
      end
      f:close()
    end
  end
end

-- Helper to record a normalized event
-- fields: process, action, requestId, actorRole, siteId, resultCode
function Audit.record(process, action, msg, resp, extra)
  local entry = {
    process = process,
    action = action,
    requestId = msg and msg["Request-Id"],
    actorRole = msg and (msg["Actor-Role"] or msg.actorRole),
    siteId = msg and (msg["Site-Id"] or msg.siteId),
    status = resp and resp.status,
    resultCode = resp and resp.code or resp and resp.status,
  }
  if extra then
    for k, v in pairs(extra) do
      entry[k] = v
    end
  end
  Audit.append(entry)
  -- optional per-process log
  if LOG_DIR and process then
    local path = string.format("%s/audit-%s.log", LOG_DIR, process)
    rotate_if_needed(path)
    local f = io.open(path, "a")
    if f then
      if FORMAT == "ndjson" then
        f:write(json_encode(entry), "\n")
      else
        f:write(tostring(entry.action or "event"), " ", json_encode(entry), "\n")
      end
      f:close()
    end
  end
end

function Audit.all()
  return records
end

function Audit.log_path()
  return LOG_DIR and (LOG_DIR .. "/audit.log") or nil
end

function Audit.process_log_path(process)
  if not LOG_DIR or not process then
    return nil
  end
  return string.format("%s/audit-%s.log", LOG_DIR, process)
end

function Audit._clear()
  records = {}
end

return Audit
]====], "ao.shared.audit")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.auth"] = function()
  local loaded, err = load([====[-- Shared auth utilities: signature verification and role checks.
-- AO environment is expected to verify signatures; here we keep role/allowlist helpers.

local jwt_ok, jwt = pcall(require, "ao.shared.jwt")
local metrics_ok, metrics = pcall(require, "ao.shared.metrics")

local Auth = {}
local os_time = os.time

local NONCE_TTL = tonumber(os.getenv "AUTH_NONCE_TTL_SECONDS" or "300")
local NONCE_MAX = tonumber(os.getenv "AUTH_NONCE_MAX_ENTRIES" or "2048")
local NONCE_SQLITE = os.getenv "AUTH_NONCE_SQLITE"
local REQUIRE_NONCE = os.getenv "AUTH_REQUIRE_NONCE" ~= "0" -- default ON
local REQUIRE_SIGNATURE = os.getenv "AUTH_REQUIRE_SIGNATURE" ~= "0" -- default ON
local REQUIRE_TS = os.getenv "AUTH_REQUIRE_TIMESTAMP" ~= "0"
local TS_DRIFT = tonumber(os.getenv "AUTH_MAX_CLOCK_SKEW" or "300")
local RL_WINDOW = tonumber(os.getenv "AUTH_RATE_LIMIT_WINDOW_SECONDS" or "60")
local RL_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_REQUESTS" or "200")
local RL_SITE_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_PER_SITE" or "200")
local RL_CALLER_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_PER_CALLER" or "200")
local RL_MAX_BUCKETS = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_BUCKETS" or "4096")
local RL_BUCKET_TTL =
  tonumber(os.getenv "AUTH_RATE_LIMIT_BUCKET_TTL_SECONDS" or tostring(RL_WINDOW * 4))
local RL_STATE_FILE = os.getenv "AUTH_RATE_LIMIT_FILE"
local RL_SQLITE = os.getenv "AUTH_RATE_LIMIT_SQLITE"
local SIG_SECRET = os.getenv "AUTH_SIGNATURE_SECRET"
local SIG_PUBLIC = os.getenv "AUTH_SIGNATURE_PUBLIC"
local SIG_TYPE = os.getenv "AUTH_SIGNATURE_TYPE" or "hmac" -- hmac | ed25519
local JWT_SECRET = os.getenv "AUTH_JWT_HS_SECRET"
local REQUIRE_JWT = os.getenv "AUTH_REQUIRE_JWT" == "1"
local DEVICE_TOKEN = os.getenv "AUTH_DEVICE_TOKEN"
local REQUIRE_DEVICE = os.getenv "AUTH_REQUIRE_DEVICE_TOKEN" == "1"
local REJECT_PLACEHOLDERS = os.getenv "ALLOW_PLACEHOLDER_SECRETS" ~= "1"
local PLACEHOLDER_SECRETS = {
  ["changeme-jwt-hmac"] = true,
  ["changeme-outbox-hmac"] = true,
  ["changeme-trust-hmac"] = true,
  ["changeme"] = true,
  ["change-me"] = true,
}
local openssl_ok, openssl = pcall(require, "openssl")
local sodium_ok, sodium = pcall(require, "sodium")
if not sodium_ok then
  sodium_ok, sodium = pcall(require, "luasodium")
end
local ed25519_ok, ed25519 = pcall(require, "ed25519") -- pure-lua (MIT) if installed
local sqlite_ok, sqlite = pcall(require, "lsqlite3")
local SHELL_FALLBACK = os.getenv "AUTH_ALLOW_SHELL_FALLBACK" == "1" -- default now off
local json_ok, json = pcall(require, "cjson.safe")
local FLAGS_FILE = os.getenv "AUTH_RESOLVER_FLAGS_FILE" or os.getenv "AO_FLAGS_PATH"

local nonce_store = {}
local nonce_db
local nonce_db_loaded = false
local rate_store = {}
local rate_db_loaded = false
local resolver_flags = {}

-- load persisted rate store (simple CSV key,count,reset)
if RL_STATE_FILE then
  local f = io.open(RL_STATE_FILE, "r")
  if f then
    for line in f:lines() do
      local key, count, reset = line:match "^([^,]+),(%d+),(%d+)"
      if key and count and reset then
        rate_store[key] = { count = tonumber(count), reset = tonumber(reset) }
      end
    end
    f:close()
  end
end

local SIGNATURE_EXCLUDE_KEYS = {
  Signature = true,
  signature = true,
  ["Signature-Ref"] = true,
}

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

local function hex_encode(bytes)
  if not bytes then
    return nil
  end
  if openssl_ok and openssl.hex then
    return openssl.hex(bytes)
  end
  if sodium_ok then
    if sodium.to_hex then
      return sodium.to_hex(bytes)
    end
    if sodium.bin2hex then
      return sodium.bin2hex(bytes)
    end
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function sorted_pairs(tbl)
  local keys = {}
  for k in pairs(tbl) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local i = 0
  return function()
    i = i + 1
    local key = keys[i]
    if key then
      return key, tbl[key]
    end
  end
end

local function canonical_value(val)
  local t = type(val)
  if t == "table" then
    local parts = {}
    for k, v in sorted_pairs(val) do
      parts[#parts + 1] = tostring(k) .. "=" .. canonical_value(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    return tostring(val)
  elseif t == "string" then
    return val
  else
    return ""
  end
end

local function canonical_payload(msg)
  if type(msg) ~= "table" then
    return ""
  end
  local cleaned = {}
  for k, v in pairs(msg) do
    if not SIGNATURE_EXCLUDE_KEYS[k] then
      cleaned[k] = v
    end
  end
  return canonical_value(cleaned)
end

local function extract_bearer(msg)
  if msg.jwt then
    return msg.jwt
  end
  if msg.JWT then
    return msg.JWT
  end
  if msg.token then
    return msg.token
  end
  local authz = msg.Authorization or msg.authorization or msg.auth
  if authz and type(authz) == "string" then
    return (authz:gsub("^%s*[Bb]earer%s+", ""))
  end
end

local function placeholder_secret(secret)
  if not REJECT_PLACEHOLDERS then
    return false
  end
  if not secret or secret == "" then
    return false
  end
  local lower = tostring(secret):lower()
  if PLACEHOLDER_SECRETS[lower] then
    return true
  end
  return lower:find "change%-me" or lower:find "changeme"
end

function Auth.consume_jwt(msg)
  if REQUIRE_JWT and (not JWT_SECRET or JWT_SECRET == "") then
    return false, "jwt_secret_missing"
  end
  if not JWT_SECRET or JWT_SECRET == "" then
    return true
  end
  if placeholder_secret(JWT_SECRET) then
    return false, "placeholder_jwt_secret"
  end
  if not jwt_ok then
    return not REQUIRE_JWT, "jwt_module_missing"
  end
  local token = extract_bearer(msg)
  if not token or token == "" then
    if REQUIRE_JWT then
      return false, "missing_jwt"
    end
    return true
  end
  local ok, claims = jwt.verify_hs256(token, JWT_SECRET)
  if not ok then
    return false, claims or "jwt_invalid"
  end
  if claims.exp and os_time() > claims.exp then
    return false, "jwt_expired"
  end
  msg["Actor-Id"] = msg["Actor-Id"] or claims.sub or claims.actor
  msg["Actor-Role"] = msg["Actor-Role"] or claims.role
  msg["Tenant"] = msg["Tenant"] or claims.tenant
  msg.Nonce = msg.Nonce or claims.nonce
  msg.jwt_claims = claims
  return true
end

-- Accepts either dash or camel case field names for flexibility with gateways.
local function extract_role(msg)
  return msg["Actor-Role"] or msg.actorRole or msg.role
end

local function prune_nonces()
  local now = os_time()
  local count = 0
  for k, v in pairs(nonce_store) do
    local exp = v.exp or v
    if exp < now then
      nonce_store[k] = nil
    else
      count = count + 1
    end
  end
  if count > NONCE_MAX then
    -- drop oldest
    local oldest_key, oldest_exp
    for k, v in pairs(nonce_store) do
      local exp = v.exp or v
      if not oldest_exp or exp < oldest_exp then
        oldest_exp = exp
        oldest_key = k
      end
    end
    if oldest_key then
      nonce_store[oldest_key] = nil
    end
  end
end

local function load_nonce_db()
  if nonce_db_loaded or not NONCE_SQLITE then
    return
  end
  if not sqlite_ok then
    return false, "nonce_sqlite_missing"
  end
  nonce_db = sqlite.open(NONCE_SQLITE)
  if not nonce_db then
    return false, "nonce_sqlite_open_failed"
  end
  nonce_db:exec "CREATE TABLE IF NOT EXISTS nonces (nonce TEXT PRIMARY KEY, exp INT, rid TEXT)"
  nonce_db_loaded = true
  return true
end

local function nonce_db_get(nonce)
  if not nonce_db then
    return nil
  end
  local stmt = nonce_db:prepare "SELECT exp,rid FROM nonces WHERE nonce=?"
  stmt:bind_values(nonce)
  local row = stmt:step() == sqlite.ROW and { exp = stmt:get_value(0), rid = stmt:get_value(1) }
    or nil
  stmt:finalize()
  return row
end

local function nonce_db_put(nonce, exp, rid)
  if not nonce_db then
    return
  end
  local stmt = nonce_db:prepare "INSERT OR REPLACE INTO nonces (nonce, exp, rid) VALUES (?, ?, ?)"
  stmt:bind_values(nonce, exp, rid)
  stmt:step()
  stmt:finalize()
end

local function nonce_db_cleanup(now)
  if nonce_db then
    nonce_db:exec(string.format("DELETE FROM nonces WHERE exp < %d", now))
  end
end

function Auth.require_nonce(msg)
  prune_nonces()
  local nonce = msg.Nonce or msg.nonce
  if not nonce then
    if REQUIRE_NONCE then
      return false, "missing_nonce"
    end
    return true
  end

  local now = os_time()
  local function memo_seen(entry)
    if entry and entry.exp and entry.exp >= now then
      return entry
    end
  end

  local seen = memo_seen(nonce_store[nonce])

  if not seen and NONCE_SQLITE then
    local ok_db, err_db = load_nonce_db()
    if ok_db == false then
      return false, err_db
    end
    seen = memo_seen(nonce_db_get(nonce))
  end

  if seen then
    if seen.rid and seen.rid == msg["Request-Id"] then
      return true
    end
    return false, "replay_nonce"
  end

  local record = { exp = now + NONCE_TTL, rid = msg["Request-Id"] }
  nonce_store[nonce] = record
  if NONCE_SQLITE and nonce_db_loaded then
    nonce_db_put(nonce, record.exp, record.rid)
    nonce_db_cleanup(now)
  end
  prune_nonces()
  return true
end

local function require_timestamp(msg)
  if not REQUIRE_TS then
    return true
  end
  local ts = msg.ts or msg.timestamp or msg["X-Timestamp"]
  if not ts then
    return false, "missing_timestamp"
  end
  ts = tonumber(ts)
  if not ts then
    return false, "invalid_timestamp"
  end
  local now = os_time()
  if math.abs(now - ts) > TS_DRIFT then
    return false, "timestamp_skew"
  end
  return true
end

function Auth.require_signature(msg)
  local sig = msg.Signature or msg.signature or msg["Signature-Ref"]
  if not sig then
    if REQUIRE_SIGNATURE then
      return false, "missing_signature"
    end
    return true
  end

  local target = canonical_payload(msg)

  if SIG_TYPE == "ed25519" and SIG_PUBLIC then
    if ed25519_ok and ed25519.verify then
      local pub = assert(io.open(SIG_PUBLIC, "rb")):read "*a"
      local raw_sig = ed25519.fromhex and ed25519.fromhex(sig) or sig
      if raw_sig and ed25519.verify(raw_sig, target, pub) then
        return true
      end
    end
    if sodium_ok and sodium.crypto_sign_verify_detached then
      local pub = assert(io.open(SIG_PUBLIC, "rb")):read "*a"
      local raw_sig
      if sodium.from_hex then
        raw_sig = sodium.from_hex(sig)
      else
        local bytes = {}
        for byte in sig:gmatch "%x%x" do
          bytes[#bytes + 1] = string.char(tonumber(byte, 16))
        end
        raw_sig = table.concat(bytes)
      end
      if raw_sig and sodium.crypto_sign_verify_detached(raw_sig, target, pub) then
        return true
      end
    end
    if openssl_ok and openssl.pkey and openssl.hex then
      local pub_pem = assert(io.open(SIG_PUBLIC, "r")):read "*a"
      local pkey = openssl.pkey.read(pub_pem, true, "public")
      local raw_sig = openssl.hex(sig)
      local ok, _ = pkey:verify(raw_sig, target, "NONE")
      if ok then
        return true
      end
    end
    if SHELL_FALLBACK then
      local tmp = os.tmpname()
      local f = io.open(tmp, "w")
      if f then
        f:write(target)
        f:close()
      end
      local cmd = string.format(
        "openssl pkeyutl -verify -pubin -inkey %q -rawin -in %q -sigfile %q 2>/dev/null",
        SIG_PUBLIC,
        tmp,
        tmp .. ".sig"
      )
      local sf = io.open(tmp .. ".sig", "w")
      if sf then
        sf:write(sig)
        sf:close()
      end
      local ok = os.execute(cmd)
      os.remove(tmp)
      os.remove(tmp .. ".sig")
      if ok == true or ok == 0 then
        return true
      end
    end
    return false, "bad_signature"
  else
    if not SIG_SECRET then
      return not REQUIRE_SIGNATURE, REQUIRE_SIGNATURE and "missing_signature_secret" or nil
    end
    local function canonical_key(secret)
      if not secret then
        return nil
      end
      if #secret == 32 then
        return secret
      end
      if #secret > 32 then
        return secret:sub(1, 32)
      end
      return secret .. string.rep("\0", 32 - #secret)
    end
    if openssl_ok and openssl.hmac then
      local raw = openssl.hmac.digest("sha256", target, SIG_SECRET, true)
      if not raw then
        return false, "sig_verify_failed"
      end
      local hex = hex_encode(raw)
      if hex:lower() ~= tostring(sig):lower() then
        return false, "bad_signature"
      end
      return true
    elseif sodium_ok and sodium.crypto_auth then
      local key = canonical_key(SIG_SECRET)
      local tag = sodium.crypto_auth(target, key)
      local hex = hex_encode(tag)
      if hex:lower() ~= tostring(sig):lower() then
        return false, "bad_signature"
      end
      return true
    else
      -- Fail closed when signature verification is required but no crypto backend is available.
      return false, "sig_backend_missing"
    end
  end
end

function Auth.verify_outbox_hmac(msg)
  local secret = os.getenv "OUTBOX_HMAC_SECRET"
  if not secret or secret == "" then
    return true
  end
  if placeholder_secret(secret) then
    return false, "placeholder_outbox_hmac_secret"
  end
  local provided = msg.hmac or msg.Hmac
  if not provided then
    return false, "missing_outbox_hmac"
  end
  local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
  if not crypto_ok then
    return false, "crypto_missing"
  end
  local payload = (msg["Site-Id"] or "")
    .. "|"
    .. (msg["Page-Id"] or msg["Order-Id"] or "")
    .. "|"
    .. (msg.Version or msg["Manifest-Tx"] or msg.Amount or "")
  local expected = crypto.hmac_sha256_hex(payload, secret)
  if not expected or expected:lower() ~= tostring(provided):lower() then
    return false, "outbox_hmac_mismatch"
  end
  return true
end

-- Optional action-aware wrapper for OUTBOX_HMAC enforcement.
-- opts.require_for: only enforce when opts.require_for[action] == true
-- opts.skip_for: skip enforcement when opts.skip_for[action] == true
function Auth.verify_outbox_hmac_for_action(msg, opts)
  opts = opts or {}
  local action = msg and msg.Action
  if type(action) ~= "string" or action == "" then
    return Auth.verify_outbox_hmac(msg)
  end

  if type(opts.require_for) == "table" then
    if not opts.require_for[action] then
      return true
    end
    return Auth.verify_outbox_hmac(msg)
  end

  if type(opts.skip_for) == "table" and opts.skip_for[action] then
    return true
  end

  return Auth.verify_outbox_hmac(msg)
end

local function rate_key(msg)
  local site = msg["Site-Id"] or "global"
  local actor = msg.Subject or msg["Actor-Id"] or msg["Actor-Role"] or "anon"
  return site .. ":" .. actor
end

local function prune_rate()
  local now = os_time()
  for k, v in pairs(rate_store) do
    if v.reset < now then
      rate_store[k] = nil
    end
  end
  if RL_BUCKET_TTL and RL_BUCKET_TTL > 0 then
    for k, v in pairs(rate_store) do
      local reset = tonumber(v.reset) or now
      if now - reset > RL_BUCKET_TTL then
        rate_store[k] = nil
      end
    end
  end
  if RL_MAX_BUCKETS and RL_MAX_BUCKETS > 0 then
    local count = 0
    local oldest_key, oldest_reset
    for k, v in pairs(rate_store) do
      count = count + 1
      local reset = tonumber(v.reset) or now
      if not oldest_reset or reset < oldest_reset then
        oldest_reset = reset
        oldest_key = k
      end
    end
    while count > RL_MAX_BUCKETS and oldest_key do
      rate_store[oldest_key] = nil
      count = count - 1
      oldest_key, oldest_reset = nil, nil
      for k, v in pairs(rate_store) do
        local reset = tonumber(v.reset) or now
        if not oldest_reset or reset < oldest_reset then
          oldest_reset = reset
          oldest_key = k
        end
      end
    end
  end
end

local function load_rate_store_sqlite()
  if not RL_SQLITE or not sqlite_ok or rate_db_loaded then
    return
  end
  Auth._db = sqlite.open(RL_SQLITE)
  Auth._db:exec "CREATE TABLE IF NOT EXISTS rate (k TEXT PRIMARY KEY, count INT, reset INT)"
  for row in Auth._db:nrows "SELECT k,count,reset FROM rate" do
    rate_store[row.k] =
      { count = tonumber(row.count) or 0, reset = tonumber(row.reset) or os_time() }
  end
  rate_db_loaded = true
end

function Auth.check_rate_limit(msg)
  load_rate_store_sqlite()
  prune_rate()
  local key = rate_key(msg)
  local now = os_time()
  local bucket = rate_store[key] or { count = 0, reset = now + RL_WINDOW }
  bucket.count = bucket.count + 1
  if bucket.reset < now then
    bucket.count = 1
    bucket.reset = now + RL_WINDOW
  end
  rate_store[key] = bucket
  if bucket.count > RL_MAX then
    if metrics_ok and metrics.counter then
      metrics.counter("ao.auth.rate_global_block", 1)
    end
    return false, "rate_limited"
  end

  -- per-site cap
  if RL_SITE_MAX and RL_SITE_MAX > 0 and msg["Site-Id"] then
    local site_key = "site:" .. msg["Site-Id"]
    local s = rate_store[site_key] or { count = 0, reset = now + RL_WINDOW }
    if s.reset < now then
      s.count = 0
      s.reset = now + RL_WINDOW
    end
    s.count = s.count + 1
    rate_store[site_key] = s
    if s.count > RL_SITE_MAX then
      if metrics_ok and metrics.counter then
        metrics.counter("ao.auth.rate_site_block", 1)
      end
      return false, "rate_limited_site"
    end
  end

  -- per-caller cap (gateway/worker)
  if RL_CALLER_MAX and RL_CALLER_MAX > 0 and msg["X-Caller"] then
    local caller_key = "caller:" .. tostring(msg["X-Caller"])
    local c = rate_store[caller_key] or { count = 0, reset = now + RL_WINDOW }
    if c.reset < now then
      c.count = 0
      c.reset = now + RL_WINDOW
    end
    c.count = c.count + 1
    rate_store[caller_key] = c
    if c.count > RL_CALLER_MAX then
      if metrics_ok and metrics.counter then
        metrics.counter("ao.auth.rate_caller_block", 1)
      end
      return false, "rate_limited_caller"
    end
  end
  if metrics_ok and metrics.gauge then
    metrics.gauge(
      "ao.auth.rate_buckets",
      (function()
        local n = 0
        for _ in pairs(rate_store) do
          n = n + 1
        end
        return n
      end)()
    )
  end
  if RL_SQLITE and sqlite_ok then
    if not Auth._db then
      Auth._db = sqlite.open(RL_SQLITE)
      Auth._db:exec "CREATE TABLE IF NOT EXISTS rate (k TEXT PRIMARY KEY, count INT, reset INT)"
    end
    local stmt = Auth._db:prepare "INSERT OR REPLACE INTO rate (k,count,reset) VALUES (?, ?, ?)"
    stmt:bind_values(key, bucket.count, bucket.reset)
    stmt:step()
    stmt:finalize()
  elseif RL_STATE_FILE then
    local f = io.open(RL_STATE_FILE, "w")
    if f then
      for rk, rv in pairs(rate_store) do
        f:write(string.format("%s,%d,%d\n", rk, rv.count, rv.reset))
      end
      f:close()
    end
  end
  return true
end

function Auth.require_role(msg, allowed_roles)
  if not allowed_roles or #allowed_roles == 0 then
    return true
  end
  local role = extract_role(msg)
  if not role then
    return false, "missing_role"
  end
  if not contains(allowed_roles, role) then
    return false, "forbidden_role"
  end
  return true
end

-- Convenience: pick allowlist by action map { action = {roles...} }
function Auth.require_role_for_action(msg, policy_table)
  local roles = policy_table[msg.Action]
  if not roles then
    return true
  end
  return Auth.require_role(msg, roles)
end

local function load_resolver_flags()
  if not FLAGS_FILE or FLAGS_FILE == "" or not json_ok then
    return
  end
  local f = io.open(FLAGS_FILE, "r")
  if not f then
    return
  end
  local tmp = {}
  for line in f:lines() do
    local obj = json.decode(line)
    if obj and obj.resolverId and obj.flag then
      tmp[obj.resolverId] = obj
    end
  end
  f:close()
  resolver_flags = tmp
end

local function check_resolver_flag(msg)
  if not FLAGS_FILE then
    return true
  end
  local rid = msg["Resolver-Id"] or msg.ResolverId or msg.resolverId or msg.resolver
  if not rid then
    return true
  end
  load_resolver_flags()
  local entry = resolver_flags[rid]
  if not entry then
    return true
  end
  if entry.flag == "blocked" then
    return false, "resolver_blocked"
  elseif entry.flag == "suspicious" then
    local action = msg.Action or ""
    if action:match "^[Gg]et" or action:match "^[Ll]ist" then
      return true
    end
    return false, "resolver_suspicious_readonly"
  end
  return true
end

local function require_device_token(msg)
  local token = msg["Device-Token"] or msg.deviceToken or msg.device_token or msg.device
  if not token or token == "" then
    if REQUIRE_DEVICE then
      return false, "missing_device_token"
    end
    return true
  end
  if DEVICE_TOKEN and DEVICE_TOKEN ~= "" then
    if token ~= DEVICE_TOKEN then
      return false, "device_token_mismatch"
    end
  end
  return true
end

-- Combined security gate used by routes
function Auth.enforce(msg)
  local ok_jwt, err_jwt = Auth.consume_jwt(msg)
  if not ok_jwt then
    return false, err_jwt
  end
  local ok_nonce, err_nonce = Auth.require_nonce(msg)
  if not ok_nonce then
    return false, err_nonce
  end
  local ok_ts, err_ts = require_timestamp(msg)
  if not ok_ts then
    return false, err_ts
  end
  local ok_sig, err_sig = Auth.require_signature(msg)
  if not ok_sig then
    return false, err_sig
  end
  local ok_flag, err_flag = check_resolver_flag(msg)
  if not ok_flag then
    return false, err_flag
  end
  local ok_dev, err_dev = require_device_token(msg)
  if not ok_dev then
    return false, err_dev
  end
  local ok_rl, err_rl = Auth.check_rate_limit(msg)
  if not ok_rl then
    return false, err_rl
  end
  return true
end

return Auth
]====], "ao.shared.auth")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.codec"] = function()
  local loaded, err = load([====[-- Shared codecs and response normalization.

local Codec = {}

function Codec.ok(payload)
  return {
    status = "OK",
    payload = payload or {},
  }
end

function Codec.error(code, message, meta)
  return {
    status = "ERROR",
    code = code,
    message = message,
    meta = meta,
  }
end

function Codec.missing_tags(missing)
  return Codec.error("MISSING_TAGS", "Required tags are missing", { missing = missing })
end

function Codec.unknown_action(action)
  return Codec.error("UNKNOWN_ACTION", "Unsupported action", { action = action })
end

function Codec.not_found(resource)
  return Codec.error("NOT_FOUND", resource .. " not found", { resource = resource })
end

function Codec.not_implemented(action)
  return Codec.error("NOT_IMPLEMENTED", "Handler not implemented", { action = action })
end

return Codec
]====], "ao.shared.codec")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.export"] = function()
  local loaded, err = load([====[-- PII-scrubbing append-only export for WeaveDB/Arweave bundling.
-- Enabled when AO_WEAVEDB_EXPORT_PATH (or WRITE_OUTBOX_EXPORT_PATH) is set.

local Export = {}

local path = os.getenv "AO_WEAVEDB_EXPORT_PATH" or os.getenv "WRITE_OUTBOX_EXPORT_PATH"
local json_ok, cjson = pcall(require, "cjson.safe")

-- Keys to drop entirely to avoid persisting PII on immutable storage.
local pii_keys = {
  address = true,
  Address = true,
  line1 = true,
  line2 = true,
  city = true,
  postal = true,
  region = true,
  phone = true,
  email = true,
  subject = true,
  ["Subject"] = true,
  customerId = true,
  ["Customer-Id"] = true,
  customerRef = true,
  ["Customer-Ref"] = true,
  token = true,
  tokenHash = true,
  ["Token-Hash"] = true,
  sessionHash = true,
  ["Session-Hash"] = true,
  jwt = true,
  JWT = true,
  taxId = true,
  vatId = true,
  tracking = true,
  trackingNumber = true,
}

local function scrub(value)
  local t = type(value)
  if t ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    if not pii_keys[k] then
      out[k] = scrub(v)
    end
  end
  return out
end

function Export.write(ev)
  if not path or not json_ok or not ev then
    return
  end
  local f = io.open(path, "a")
  if not f then
    return
  end
  local ok, encoded = pcall(cjson.encode, scrub(ev))
  if ok and encoded then
    f:write(encoded)
    f:write "\n"
  end
  f:close()
end

-- expose for tests
Export._scrub = scrub

return Export
]====], "ao.shared.export")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.i18n"] = function()
  local loaded, err = load([====[-- Locale helpers: detect locale from path prefixes and normalize to supported locales.

local I18n = {}

local function normalize_locale(locale)
  if not locale or locale == "" then
    return nil
  end
  return locale:lower()
end

---Detect locale prefix in a URL path and strip it.
-- @param path string (e.g. "/en/products/1")
-- @param supported table array of locales; if nil, no detection performed
-- @param default_locale string fallback locale
-- @return locale (string), stripped_path (string)
function I18n.detect_locale(path, supported, default_locale)
  local locale = normalize_locale(default_locale) or "en"
  local normalized_path = path or "/"
  if not supported or #supported == 0 or not path or path == "" then
    return locale, normalized_path
  end

  for _, candidate in ipairs(supported) do
    local lc = normalize_locale(candidate)
    local prefix = "/" .. lc
    if normalized_path == prefix then
      return lc, "/"
    end
    if normalized_path:sub(1, #prefix + 1) == prefix .. "/" then
      return lc, normalized_path:sub(#prefix + 1)
    end
  end

  return locale, normalized_path
end

return I18n
]====], "ao.shared.i18n")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.idempotency"] = function()
  local loaded, err = load([====[-- Simple in-memory idempotency registry (lookup/record) shared across AO procs.

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
]====], "ao.shared.idempotency")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.ids"] = function()
  local loaded, err = load([====[-- Deterministic ID generation and namespacing helpers.
-- These keep key shapes consistent across processes.

local IDs = {}

local function normalize_path(path)
  if not path or path == "" then
    return "/"
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  -- collapse duplicate slashes (lightweight)
  path = path:gsub("//+", "/")
  return path
end

function IDs.site_key(site_id)
  return ("site:%s"):format(site_id)
end

function IDs.domain_key(host)
  return ("domain:%s"):format(host)
end

function IDs.version_key(site_id, version_id)
  return ("version:%s:%s"):format(site_id, version_id)
end

function IDs.route_key(site_id, path, locale)
  local normalized = normalize_path(path)
  if locale and locale ~= "" then
    return ("route:%s:%s:%s"):format(site_id, normalized, locale:lower())
  end
  return ("route:%s:%s"):format(site_id, normalized)
end

function IDs.page_key(site_id, page_id, version_id, locale)
  if locale and locale ~= "" then
    return ("page:%s:%s:%s:%s"):format(site_id, page_id, version_id or "active", locale:lower())
  end
  return ("page:%s:%s:%s"):format(site_id, page_id, version_id or "active")
end

function IDs.layout_key(layout_id, version_id, locale)
  if locale and locale ~= "" then
    return ("layout:%s:%s:%s"):format(layout_id, version_id or "active", locale:lower())
  end
  return ("layout:%s:%s"):format(layout_id, version_id or "active")
end

function IDs.menu_key(site_id, menu_id, version_id, locale)
  if locale and locale ~= "" then
    return ("menu:%s:%s:%s:%s"):format(site_id, menu_id, version_id or "active", locale:lower())
  end
  return ("menu:%s:%s:%s"):format(site_id, menu_id, version_id or "active")
end

function IDs.product_key(site_id, sku)
  return ("product:%s:%s"):format(site_id, sku)
end

function IDs.category_key(site_id, category_id)
  return ("category:%s:%s"):format(site_id, category_id)
end

function IDs.entitlement_key(subject, asset)
  return ("entitlement:%s:%s"):format(subject, asset)
end

return IDs
]====], "ao.shared.ids")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.jwt"] = function()
  local loaded, err = load([====[-- Minimal JWT HS256 verifier (no clock skew handling).
local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
local ok_mime, mime = pcall(require, "mime")
local ok_json, cjson = pcall(require, "cjson.safe")

local Jwt = {}

local function b64url_decode(input)
  input = input:gsub("-", "+"):gsub("_", "/")
  local pad = #input % 4
  if pad > 0 then
    input = input .. string.rep("=", 4 - pad)
  end
  if ok_mime and mime.unb64 then
    return mime.unb64(input)
  end
  return nil
end

function Jwt.verify_hs256(token, secret)
  if not token or token == "" or not secret then
    return false, "missing_token"
  end
  if not crypto_ok or not crypto.hmac_sha256_hex then
    return false, "crypto_missing"
  end
  local header_b64, payload_b64, sig_b64 = token:match "([^%.]+)%.([^%.]+)%.([^%.]+)"
  if not (header_b64 and payload_b64 and sig_b64) then
    return false, "invalid_format"
  end
  local signed = header_b64 .. "." .. payload_b64
  local signature = b64url_decode(sig_b64)
  if not signature then
    return false, "bad_signature_b64"
  end
  local expected_hex = crypto.hmac_sha256_hex(signed, secret)
  local expected = expected_hex
    and expected_hex:gsub("%x%x", function(x)
      return string.char(tonumber(x, 16))
    end)
  if not expected or expected ~= signature then
    return false, "signature_mismatch"
  end
  if not ok_json then
    return false, "json_missing"
  end
  local ok_h = pcall(cjson.decode, b64url_decode(header_b64) or "")
  local ok_p, payload = pcall(cjson.decode, b64url_decode(payload_b64) or "")
  if not (ok_h and ok_p) then
    return false, "decode_failed"
  end
  return true, payload
end

return Jwt
]====], "ao.shared.jwt")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.layout_components"] = function()
  local loaded, err = load([====[-- Layout component validator for block-based layouts.

local Layout = {}

local function warn(list, msg)
  table.insert(list, msg)
end

local validators = {}

validators.hero = function(comp, warnings)
  if not comp.title or comp.title == "" then
    warn(warnings, "hero.title required")
  end
  if comp.image and (not comp.image.alt or comp.image.alt == "") then
    warn(warnings, "hero.image.alt required when image set")
  end
  if comp.image then
    comp.image.loading = comp.image.loading or "lazy"
    comp.image.placeholder = comp.image.placeholder or "blur"
  end
  if comp.cta and not comp.cta.aria_label then
    warn(warnings, "hero.cta.aria_label recommended")
  end
end

validators.grid = function(comp, warnings)
  if not comp.items or type(comp.items) ~= "table" or #comp.items == 0 then
    warn(warnings, "grid.items must be non-empty array")
  end
end

validators.carousel = function(comp, warnings)
  if not comp.slides or type(comp.slides) ~= "table" or #comp.slides == 0 then
    warn(warnings, "carousel.slides must be non-empty array")
    return
  end
  for _, slide in ipairs(comp.slides) do
    if not slide.image then
      warn(warnings, "carousel.slide.image required")
    elseif not slide.alt or slide.alt == "" then
      warn(warnings, "carousel.slide.alt required")
    end
    slide.loading = slide.loading or "lazy"
    slide.placeholder = slide.placeholder or "blur"
    if slide.cta and not slide.cta.aria_label then
      warn(warnings, "carousel.slide.cta.aria_label recommended")
    end
  end
end

validators.rich_text = function(comp, warnings)
  if not comp.body or comp.body == "" then
    warn(warnings, "rich_text.body required")
  end
end

validators.form = function(comp, warnings)
  if not comp.fields or type(comp.fields) ~= "table" or #comp.fields == 0 then
    warn(warnings, "form.fields must be non-empty array")
    return
  end
  for _, f in ipairs(comp.fields) do
    if not f.name or not f.label then
      warn(warnings, "form.field name and label required")
    end
    if f.type == "button" and not f.aria_label then
      warn(warnings, "form.button aria_label recommended")
    end
  end
end

local allowed_types = {
  hero = true,
  grid = true,
  carousel = true,
  rich_text = true,
  form = true,
}

---Validate array of components.
-- @return ok:boolean, warnings:table
function Layout.validate(components)
  local warnings = {}
  if not components or type(components) ~= "table" then
    return true, warnings
  end
  for _, comp in ipairs(components) do
    local typ = comp.type or comp.kind
    if not typ or not allowed_types[typ] then
      warn(warnings, "Unsupported component type")
    else
      local v = validators[typ]
      if v then
        v(comp, warnings)
      end
    end
  end
  return #warnings == 0, warnings
end

return Layout
]====], "ao.shared.layout_components")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.metrics"] = function()
  local loaded, err = load([====[-- Minimal metrics stub: counts and durations written to NDJSON file (mock-friendly).

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
]====], "ao.shared.metrics")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.persist"] = function()
  local loaded, err = load([====[-- Persistence adapter with three tiers:
-- 1) WeaveDB export (append-only, PII-scrubbed) if AO_WEAVEDB_EXPORT_PATH is set.
-- 2) Local snapshot (PII-scrubbed) when AO_STATE_DIR is set.
-- 3) In-memory fallback.

local persist = {}

local base = os.getenv "AO_STATE_DIR"
local export_ok, export = pcall(require, "ao.shared.export")
local json_ok, cjson = pcall(require, "cjson.safe")

-- PII keys to remove before writing immutable storage.
local pii_keys = {
  address = true,
  Address = true,
  line1 = true,
  line2 = true,
  city = true,
  postal = true,
  region = true,
  phone = true,
  email = true,
  subject = true,
  ["Subject"] = true,
  customerId = true,
  ["Customer-Id"] = true,
  customerRef = true,
  ["Customer-Ref"] = true,
  token = true,
  tokenHash = true,
  ["Token-Hash"] = true,
  sessionHash = true,
  ["Session-Hash"] = true,
  jwt = true,
  JWT = true,
}

local function scrub(value)
  local t = type(value)
  if t ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    if not pii_keys[k] then
      out[k] = scrub(v)
    end
  end
  return out
end

local function path_for(ns)
  if not base then
    return nil
  end
  return base .. "/" .. ns .. ".json"
end

function persist.load(ns, default_value)
  local p = path_for(ns)
  if not p or not json_ok then
    return default_value
  end
  local f = io.open(p, "r")
  if not f then
    return default_value
  end
  local content = f:read "*a"
  f:close()
  local decoded = cjson.decode(content or "")
  if type(decoded) == "table" then
    return decoded
  end
  return default_value
end

function persist.save(ns, value)
  local p = path_for(ns)
  -- Append PII-scrubbed state snapshot to WeaveDB export (immutable)
  if export_ok and type(export.write) == "function" then
    export.write {
      kind = "state_snapshot",
      ns = ns,
      ts = os.time(),
      state = scrub(value),
    }
  end
  -- Write local snapshot (mutable, used for fast reload)
  if p and json_ok then
    local ok, encoded = pcall(cjson.encode, scrub(value))
    if not ok or not encoded then
      return
    end
    local f = io.open(p, "w")
    if not f then
      return
    end
    f:write(encoded)
    f:close()
  end
end

return persist
]====], "ao.shared.persist")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.schema"] = function()
  local loaded, err = load([====[-- Minimal JSON Schema validator with optional python/jsonschema backend.
-- If SCHEMA_VALIDATOR=python and python3+jsonschema are available,
-- uses that; otherwise falls back to the embedded validator below.

local Schema = {}
local SCHEMA_MODE = os.getenv "SCHEMA_VALIDATOR" or "auto" -- auto|python|embedded

-- Schemas embedded as Lua tables (converted from schemas/*.json)
local SCHEMAS = {
  page = {
    type = "object",
    required = { "id", "title", "blocks" },
    properties = {
      id = { type = "string" },
      title = { type = "string" },
      locale = { type = "string" },
      layoutId = { type = "string" },
      blocks = { type = "array", items = { type = "object" } },
    },
  },
  product = {
    type = "object",
    required = { "sku", "name" },
    properties = {
      sku = { type = "string" },
      name = { type = "string" },
      description = { type = "string" },
      price = { type = "number" },
      assets = { type = "array", items = { type = "string" } },
    },
  },
  route = {
    type = "object",
    required = { "siteId", "path", "pageId" },
    properties = {
      siteId = { type = "string" },
      path = { type = "string" },
      locale = { type = "string" },
      pageId = { type = "string" },
      type = { type = "string" },
    },
  },
  publish = {
    type = "object",
    required = { "publishId", "versionId", "manifestTx" },
    properties = {
      publishId = { type = "string" },
      versionId = { type = "string" },
      manifestTx = { type = "string" },
      activatedAt = { type = "string" },
      rollbackTo = { type = "string" },
    },
  },
  entitlement = {
    type = "object",
    required = { "subject", "asset" },
    properties = {
      subject = { type = "string", minLength = 1, maxLength = 128 },
      asset = { type = "string", minLength = 1, maxLength = 256 },
      policy = { type = "string", minLength = 1, maxLength = 128 },
    },
  },
  accessAsset = {
    type = "object",
    required = { "asset", "ref" },
    properties = {
      asset = { type = "string", minLength = 1, maxLength = 256, pattern = "^[%w%-%._:/]+$" },
      ref = { type = "string", minLength = 1, maxLength = 2048, pattern = "^ar://[%w%-]+$" },
      visibility = { type = "string", enum = { "protected", "public", "private" } },
    },
  },
  registryConfig = {
    type = "object",
    required = {},
    properties = {
      version = { type = "string", minLength = 1, maxLength = 128 },
      metadata = { type = "object" },
      flags = {
        type = "object",
        properties = {
          cors = { type = "boolean" },
          corsAllowlist = {
            type = "array",
            minItems = 1,
            items = { type = "string", pattern = "^https?://[%w%.-]+(:%d+)?/?$" },
          },
          immutable = { type = "boolean" },
          allowUploads = { type = "boolean" },
          ttlSeconds = { type = "number", minimum = 0, maximum = 31536000 },
          rateLimitPerMinute = { type = "number", minimum = 0, maximum = 10000 },
          maxUploadBytes = { type = "number", minimum = 0, maximum = 104857600 },
          allowAnonRead = { type = "boolean" },
          requireMfa = { type = "boolean" },
        },
      },
      region = { type = "string", enum = { "eu", "us", "apac" } },
      tier = { type = "string", enum = { "dev", "staging", "prod" } },
      codeHash = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
      buildId = { type = "string", minLength = 1, maxLength = 128 },
      signerPubKey = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
      tableProfile = {
        type = "string",
        enum = {
          "minimal",
          "core-observability",
          "auth-rbac",
          "commerce-lite",
          "monitoring-outbox",
        },
      },
      schemaManifestTx = { type = "string", pattern = "^[A-Za-z0-9_-]{10,128}$" },
      schemaHash = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
      policies = {
        type = "object",
        properties = {
          allowAnonymousRead = { type = "boolean" },
          allowAnonymousWrite = { type = "boolean" },
          auditLevel = { type = "string", enum = { "none", "basic", "full" } },
          dataResidency = { type = "string", enum = { "eu", "us", "apac", "global" } },
          piiHandling = { type = "string", enum = { "deny", "mask", "allow" } },
          allowedOrigins = {
            type = "array",
            items = { type = "string", pattern = "^https?://[%w%.-]+(:%d+)?/?$" },
            minItems = 1,
          },
          ipAllowlist = {
            type = "array",
            items = { type = "string", pattern = "^%d+%.%d+%.%d+%.%d+/%d%d?$" },
            minItems = 0,
          },
          allowedMethods = {
            type = "array",
            items = {
              type = "string",
              enum = { "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" },
            },
            minItems = 1,
          },
        },
      },
    },
  },
  arweaveResponse = {
    type = "object",
    required = { "status" },
    properties = {
      status = { type = "string" },
      message = { type = "string" },
      tx = { type = "string" },
    },
  },
}

local function type_of(value)
  local t = type(value)
  if t == "table" then
    local i = 0
    for _ in pairs(value) do
      i = i + 1
      if value[i] == nil then
        return "object"
      end
    end
    return "array"
  end
  return t
end

local function validate_properties(value, schema, path, errors)
  if schema.required then
    for _, req in ipairs(schema.required) do
      if value[req] == nil then
        table.insert(errors, path .. req .. " is required")
      end
    end
  end
  if schema.properties then
    for name, prop in pairs(schema.properties) do
      if value[name] ~= nil then
        local actual_type = type_of(value[name])
        if prop.type and actual_type ~= prop.type then
          table.insert(errors, path .. name .. " expected " .. prop.type .. ", got " .. actual_type)
        end
        if prop.enum then
          local ok_enum = false
          for _, ev in ipairs(prop.enum) do
            if ev == value[name] then
              ok_enum = true
            end
          end
          if not ok_enum then
            table.insert(errors, path .. name .. " not in enum")
          end
        end
        if prop.pattern and actual_type == "string" then
          if not tostring(value[name]):match(prop.pattern) then
            table.insert(errors, path .. name .. " does not match pattern")
          end
        end
        if
          prop.minLength
          and actual_type == "string"
          and #tostring(value[name]) < prop.minLength
        then
          table.insert(errors, path .. name .. " shorter than minLength")
        end
        if
          prop.maxLength
          and actual_type == "string"
          and #tostring(value[name]) > prop.maxLength
        then
          table.insert(errors, path .. name .. " longer than maxLength")
        end
        if prop.type == "array" and prop.items and value[name] ~= nil then
          for idx, item in ipairs(value[name]) do
            local item_type = type_of(item)
            if prop.items.type and item_type ~= prop.items.type then
              table.insert(
                errors,
                path
                  .. name
                  .. "["
                  .. idx
                  .. "] expected "
                  .. prop.items.type
                  .. ", got "
                  .. item_type
              )
            end
            if
              prop.items.pattern
              and type(item) == "string"
              and not tostring(item):match(prop.items.pattern)
            then
              table.insert(errors, path .. name .. "[" .. idx .. "] does not match pattern")
            end
            if prop.items.enum then
              local ok_enum = false
              for _, ev in ipairs(prop.items.enum) do
                if ev == item then
                  ok_enum = true
                end
              end
              if not ok_enum then
                table.insert(errors, path .. name .. "[" .. idx .. "] not in enum")
              end
            end
          end
          if prop.minItems and #value[name] < prop.minItems then
            table.insert(errors, path .. name .. " fewer than minItems")
          end
        elseif prop.type == "object" and prop.properties and type(value[name]) == "table" then
          validate_properties(value[name], prop, path .. name .. ".", errors)
        end
        if prop.format == "date-time" and actual_type == "string" then
          if not tostring(value[name]):match "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$" then
            table.insert(errors, path .. name .. " invalid date-time")
          end
        end
        if prop.minimum and actual_type == "number" and value[name] < prop.minimum then
          table.insert(errors, path .. name .. " below minimum")
        end
        if prop.maximum and actual_type == "number" and value[name] > prop.maximum then
          table.insert(errors, path .. name .. " above maximum")
        end
      end
    end
  end
end

local function validate_against(schema, value, path, errors)
  local actual = type_of(value)
  if schema.type and actual ~= schema.type then
    table.insert(errors, path .. "expected " .. schema.type .. ", got " .. actual)
    return
  end
  if schema.type == "object" and type(value) == "table" then
    validate_properties(value, schema, path, errors)
  elseif schema.type == "array" and type(value) == "table" then
    if schema.items then
      for idx, item in ipairs(value) do
        validate_against(schema.items, item, path .. "[" .. idx .. "].", errors)
      end
    end
  end
end

function Schema.validate(schema_name, value)
  if SCHEMA_MODE ~= "embedded" then
    local ok, err = Schema.validate_python(schema_name, value)
    if ok ~= nil then
      return ok, err
    end -- nil means fallback to embedded
  end
  local schema = SCHEMAS[schema_name]
  if not schema then
    return true
  end
  local errors = {}
  validate_against(schema, value, "", errors)
  if #errors > 0 then
    return false, errors
  end
  return true
end

-- Validate against a schema table passed at runtime (same rules as embedded validator)
function Schema.validate_custom(schema_table, value)
  if not schema_table then
    return true
  end
  local errors = {}
  validate_against(schema_table, value, "", errors)
  if #errors > 0 then
    return false, errors
  end
  return true
end

-- Python/jsonschema validator (optional). Returns nil if not usable.
function Schema.validate_python(schema_name, value)
  local has_py = os.execute 'python3 -c "import jsonschema" >/dev/null 2>&1'
  if has_py ~= true and has_py ~= 0 then
    return nil, "python_jsonschema_missing"
  end
  local schema_path = "schemas/" .. schema_name .. ".schema.json"
  local f = io.open(schema_path, "r")
  if not f then
    return nil, "schema_not_found"
  end
  f:close()
  local tmp = os.tmpname() .. ".json"
  local jf = io.open(tmp, "w")
  if not jf then
    return nil, "tmp_write_failed"
  end
  local function json_encode(v)
    local t = type(v)
    if t == "nil" then
      return "null"
    end
    if t == "boolean" then
      return v and "true" or "false"
    end
    if t == "number" then
      return tostring(v)
    end
    if t == "string" then
      return string.format("%q", v)
    end
    if t == "table" then
      local is_array = true
      local i = 0
      for _, _ in pairs(v) do
        i = i + 1
        if v[i] == nil then
          is_array = false
        end
      end
      local parts = {}
      if is_array then
        for _, item in ipairs(v) do
          table.insert(parts, json_encode(item))
        end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        for k, item in pairs(v) do
          table.insert(parts, string.format("%q:%s", tostring(k), json_encode(item)))
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    end
    return '"<unsupported>"'
  end
  jf:write(json_encode(value))
  jf:close()
  local cmd = string.format(
    [[python3 - <<'PY'
import json,sys,jsonschema
with open(%q) as f: schema=json.load(f)
with open(%q) as f: inst=json.load(f)
try:
 jsonschema.validate(inst, schema)
 sys.exit(0)
except jsonschema.ValidationError:
 sys.exit(1)
PY]],
    schema_path,
    tmp
  )
  local ok = os.execute(cmd)
  os.remove(tmp)
  if ok == 0 or ok == true then
    return true
  end
  -- If validation fails, treat as schema error; otherwise fallback
  if ok == 256 or ok == false then
    return false, { "python_validator_failed" }
  end
  return nil, "python_validator_unavailable"
end

return Schema
]====], "ao.shared.schema")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.seo"] = function()
  local loaded, err = load([====[-- Minimal SEO helpers (JSON-LD generators). Not wired by default.

local cjson_ok, cjson = pcall(require, "cjson.safe")

local SEO = {}

local function encode(ld)
  if not cjson_ok then
    return nil
  end
  return cjson.encode(ld)
end

-- Products ---------------------------------------------------------------
function SEO.product_ld(product)
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "Product",
    name = product.name,
    description = product.description,
    sku = product.sku,
    image = product.image,
    brand = product.brand,
    category = product.category,
    offers = {
      ["@type"] = "Offer",
      price = product.price,
      priceCurrency = product.currency,
      availability = product.available and "https://schema.org/InStock"
        or "https://schema.org/OutOfStock",
      url = product.url,
      itemCondition = product.condition,
    },
  }
end

-- Articles / blog --------------------------------------------------------
function SEO.article_ld(article)
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "Article",
    headline = article.title,
    datePublished = article.publishedAt,
    dateModified = article.updatedAt or article.publishedAt,
    author = article.author and { ["@type"] = "Person", name = article.author } or nil,
    image = article.image,
    description = article.description,
    mainEntityOfPage = article.url,
  }
end

-- Breadcrumbs ------------------------------------------------------------
function SEO.breadcrumb_ld(crumbs)
  local item_list = {}
  for idx, crumb in ipairs(crumbs or {}) do
    table.insert(item_list, {
      ["@type"] = "ListItem",
      position = idx,
      name = crumb.name,
      item = crumb.url,
    })
  end
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "BreadcrumbList",
    itemListElement = item_list,
  }
end

-- FAQ --------------------------------------------------------------------
function SEO.faq_ld(items)
  local qas = {}
  for _, qa in ipairs(items or {}) do
    table.insert(qas, {
      ["@type"] = "Question",
      name = qa.question,
      acceptedAnswer = { ["@type"] = "Answer", text = qa.answer },
    })
  end
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "FAQPage",
    mainEntity = qas,
  }
end

-- Organization -----------------------------------------------------------
function SEO.organization_ld(org)
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "Organization",
    name = org.name,
    url = org.url,
    logo = org.logo,
    sameAs = org.sameAs,
    contactPoint = org.contact and {
      ["@type"] = "ContactPoint",
      telephone = org.contact.phone,
      contactType = org.contact.type or "customer support",
      areaServed = org.contact.areaServed,
      availableLanguage = org.contact.languages,
    } or nil,
  }
end

-- WebPage ----------------------------------------------------------------
function SEO.page_ld(page)
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "WebPage",
    name = page.title or page.name,
    description = page.description,
    url = page.url,
    inLanguage = page.locale,
  }
end

-- Canonical / hreflang helpers -------------------------------------------
function SEO.canonical(base_url, path)
  if not base_url or base_url == "" then
    return path
  end
  if base_url:sub(-1) == "/" then
    base_url = base_url:sub(1, -2)
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return base_url .. path
end

---Build hreflang link map.
-- @param base_url string e.g. https://example.com
-- @param path string normalized path without locale prefix
-- @param locales { supported = { "en", "de" }, default = "en" }
function SEO.hreflang_links(base_url, path, locales)
  if not locales or not locales.supported then
    return {}
  end
  local links = {}
  for _, loc in ipairs(locales.supported) do
    local href = SEO.canonical(base_url, "/" .. loc .. path)
    table.insert(links, { rel = "alternate", hreflang = loc:lower(), href = href })
  end
  -- x-default
  local default_href = SEO.canonical(base_url, "/" .. (locales.default or "en") .. path)
  table.insert(links, { rel = "alternate", hreflang = "x-default", href = default_href })
  return links
end

-- Sitemaps / robots.txt --------------------------------------------------
function SEO.sitemap(urls)
  local buffer = {
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
  }
  for _, u in ipairs(urls or {}) do
    table.insert(buffer, "<url>")
    table.insert(buffer, string.format("<loc>%s</loc>", u.loc))
    if u.lastmod then
      table.insert(buffer, string.format("<lastmod>%s</lastmod>", u.lastmod))
    end
    if u.changefreq then
      table.insert(buffer, string.format("<changefreq>%s</changefreq>", u.changefreq))
    end
    if u.priority then
      table.insert(buffer, string.format("<priority>%.1f</priority>", u.priority))
    end
    table.insert(buffer, "</url>")
  end
  table.insert(buffer, "</urlset>")
  return table.concat(buffer, "\n")
end

function SEO.robots_txt(opts)
  opts = opts or {}
  local lines = {
    "User-agent: *",
    string.format("Disallow: %s", opts.disallow or ""),
  }
  if opts.allow then
    table.insert(lines, string.format("Allow: %s", opts.allow))
  end
  if opts.sitemap then
    table.insert(lines, "Sitemap: " .. opts.sitemap)
  end
  return table.concat(lines, "\n")
end

return SEO
]====], "ao.shared.seo")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.timer"] = function()
  local loaded, err = load([====[-- Minimal timer abstraction using luv if available.
-- Returns no-op functions when luv is absent.

local ok, uv = pcall(require, "luv")

local Timer = {}
local started = false

function Timer.start(interval_sec, fn)
  if not ok or not uv or started then
    return
  end
  if not interval_sec or interval_sec <= 0 then
    return
  end
  local t = uv.new_timer()
  if not t then
    return
  end
  started = true
  t:start(interval_sec * 1000, interval_sec * 1000, function()
    pcall(fn)
  end)
end

function Timer.is_started()
  return started
end

return Timer
]====], "ao.shared.timer")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.validation"] = function()
  local loaded, err = load([====[-- Shared schema validation and payload guards (lightweight).
-- This keeps minimal synchronous guards in-process; deeper JSON schema checks
-- should be handled by the upstream bridge or a dedicated validator.

local Validation = {}

Validation.required_tags = {
  "Action",
  "Request-Id",
}

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function Validation.require_tags(msg, extra)
  local missing = {}
  for _, key in ipairs(Validation.required_tags) do
    if msg[key] == nil then
      table.insert(missing, key)
    end
  end
  if extra then
    for _, key in ipairs(extra) do
      if msg[key] == nil then
        table.insert(missing, key)
      end
    end
  end
  if #missing > 0 then
    return false, missing
  end
  return true
end

function Validation.require_action(msg, allowed)
  local action = msg.Action
  if not action then
    return false, "missing_action"
  end
  if allowed and not contains(allowed, action) then
    return false, "unknown_action"
  end
  return true
end

-- Convenience check for allowlist
function Validation.is_allowed_action(action, allowed)
  if not action then
    return false
  end
  if not allowed then
    return true
  end
  return contains(allowed, action)
end

-- Validate presence of required fields in a table payload.
function Validation.require_fields(tbl, fields)
  local missing = {}
  for _, f in ipairs(fields) do
    if tbl[f] == nil then
      table.insert(missing, f)
    end
  end
  if #missing > 0 then
    return false, missing
  end
  return true
end

-- Validate that no unexpected fields are present (shallow).
function Validation.require_no_extras(tbl, allowed_fields)
  if not allowed_fields then
    return true
  end
  local allowed = {
    -- Cross-cutting auth/telemetry fields that every handler should tolerate.
    Nonce = true,
    nonce = true,
    ts = true,
    timestamp = true,
    ["Timestamp"] = true,
    Signature = true,
    signature = true,
    ["Signature-Ref"] = true,
    Authorization = true,
    authorization = true,
    auth = true,
    JWT = true,
    jwt = true,
    -- AO envelope fields that can be present on incoming messages.
    From = true,
    from = true,
    Id = true,
    id = true,
    Owner = true,
    owner = true,
    Target = true,
    target = true,
    Anchor = true,
    anchor = true,
    Data = true,
    data = true,
    Body = true,
    body = true,
    Tags = true,
    tags = true,
  }
  for _, f in ipairs(allowed_fields) do
    allowed[f] = true
  end
  local extras = {}
  for k, _ in pairs(tbl) do
    if not allowed[k] then
      table.insert(extras, k)
    end
  end
  if #extras > 0 then
    return false, extras
  end
  return true
end

-- Optional payload size guard (bytes when serialized length provided).
function Validation.check_size(len, max_bytes, field)
  if not max_bytes or max_bytes <= 0 or not len then
    return true
  end
  if len > max_bytes then
    return false, ("too_large:%s"):format(field or "?")
  end
  return true
end

function Validation.assert_type(value, expected, field)
  if type(value) ~= expected then
    return false, ("invalid_type:%s"):format(field or "?")
  end
  return true
end

-- Check maximum string length.
function Validation.check_length(value, max_len, field)
  if not value or not max_len or max_len <= 0 then
    return true
  end
  if #tostring(value) > max_len then
    return false, ("too_long:%s"):format(field or "?")
  end
  return true
end

local function is_array(tbl)
  local i = 0
  for _ in pairs(tbl) do
    i = i + 1
    if tbl[i] == nil then
      return false
    end
  end
  return true
end

local function json_encoded_length(value)
  local t = type(value)
  if t == "nil" then
    return 4
  end -- null
  if t == "boolean" then
    return value and 4 or 5
  end -- true/false
  if t == "number" then
    return #tostring(value)
  end
  if t == "string" then
    return #string.format("%q", value)
  end
  if t == "table" then
    if is_array(value) then
      local sum = 2 -- []
      local first = true
      for _, v in ipairs(value) do
        if not first then
          sum = sum + 1
        end -- comma
        sum = sum + json_encoded_length(v)
        first = false
      end
      return sum
    else
      local sum = 2 -- {}
      local first = true
      for k, v in pairs(value) do
        if not first then
          sum = sum + 1
        end -- comma
        sum = sum + #string.format("%q", tostring(k)) + 1 + json_encoded_length(v) -- colon
        first = false
      end
      return sum
    end
  end
  return #tostring(value)
end

-- Rough estimate of JSON-encoded length (bytes) for payload size guards.
function Validation.estimate_json_length(value)
  return json_encoded_length(value)
end

-- Envelope/command validation used by both write and AO processes.
-- Normalizes common field names so downstream code can rely on canonical keys.
function Validation.validate_envelope(cmd)
  if not cmd then
    return false, { "missing_envelope" }
  end
  cmd.action = cmd.action or cmd.Action
  cmd.requestId = cmd.requestId or cmd["Request-Id"]
  cmd.payload = cmd.payload or cmd.Payload or {}
  cmd.actor = cmd.actor or cmd.Actor
  cmd.actorRole = cmd.actorRole or cmd["Actor-Role"] or cmd.role
  cmd.tenant = cmd.tenant or cmd.Tenant or cmd["Tenant-Id"]
  cmd.siteId = cmd.siteId or cmd["Site-Id"] or cmd.SiteId
  cmd.gatewayId = cmd.gatewayId or cmd["Gateway-Id"] or cmd.gateway

  local ok_tags, missing = Validation.require_tags {
    Action = cmd.action,
    ["Request-Id"] = cmd.requestId,
  }
  if not ok_tags then
    return false, missing
  end
  return true
end

-- Per-action payload validation stub (can be extended with schemas).
function Validation.validate_action(_action, _payload)
  return true
end

-- Optional payload size guard; falls back to estimate when length not provided.
function Validation.check_payload_size(payload, max_bytes)
  if not max_bytes or max_bytes <= 0 then
    return true
  end
  local est = Validation.estimate_json_length(payload)
  if est > max_bytes then
    return false, ("too_large:%s"):format(max_bytes)
  end
  return true
end

-- Nonce/timestamp helpers (no-ops by default; override in stricter builds).
function Validation.require_nonce_fields(_msg)
  return true
end

function Validation.require_timestamp(_msg)
  return true
end

return Validation
]====], "ao.shared.validation")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.resolver.process"] = function()
  local loaded, err = load([====[-- Resolver process scaffold: host -> decision contract for HB policy routing.
-- This v1 intentionally fails open and defaults to mode=off.

local codec = require "ao.shared.codec"
local validation = require "ao.shared.validation"
local auth = require "ao.shared.auth"
local idem = require "ao.shared.idempotency"
local metrics = require "ao.shared.metrics"
local persist = require "ao.shared.persist"

local handlers = {}
local map_count
local allowed_actions = {
  "ResolveHostForNode",
  "ResolveRouteForHost",
  "GetResolverState",
  "ApplyPolicyBundle",
  "ApplyHostPolicyFromProof",
  "InvalidateResolverCache",
  "GetResolverCacheStats",
  "GetDnsRefreshState",
  "ListHostsDueForDnsRefresh",
  "RunAutoDnsTick",
  "ApplyDnsRefreshResult",
  "ForceDnsRefreshHost",
  "IssueDnsRefreshChallenge",
  "SetAdmissionRule",
  "RemoveAdmissionRule",
  "GetAdmissionState",
}

local public_read_actions = {
  ResolveHostForNode = true,
  ResolveRouteForHost = true,
  GetResolverState = true, -- safe summary only
  GetResolverCacheStats = true, -- safe summary only
  GetDnsRefreshState = true, -- safe summary only
}

local role_policy = {
  ApplyPolicyBundle = { "admin", "registry-admin" },
  InvalidateResolverCache = { "admin", "registry-admin" },
  ListHostsDueForDnsRefresh = { "admin", "registry-admin" },
  RunAutoDnsTick = { "admin", "registry-admin" },
  ApplyDnsRefreshResult = { "admin", "registry-admin", "resolver-refresh" },
  ForceDnsRefreshHost = { "admin", "registry-admin", "resolver-refresh" },
  IssueDnsRefreshChallenge = { "admin", "registry-admin", "resolver-refresh" },
  ApplyHostPolicyFromProof = { "admin", "registry-admin", "resolver-refresh" },
  SetAdmissionRule = { "admin", "registry-admin" },
  RemoveAdmissionRule = { "admin", "registry-admin" },
}

local hmac_skip_actions = {
  ResolveHostForNode = true,
  ResolveRouteForHost = true,
  GetResolverState = true,
  GetResolverCacheStats = true,
  GetDnsRefreshState = true,
}

local VALID_POLICY_MODES = {
  off = true,
  observe = true,
  soft = true,
  enforce = true,
}

local PUBLIC_READ_REQUIRE_AUTH = (os.getenv "RESOLVER_PUBLIC_READ_REQUIRE_AUTH" or "0") == "1"
local MAX_HOST_BYTES = tonumber(os.getenv "RESOLVER_MAX_HOST_BYTES" or "") or 253
local MAX_PATH_BYTES = tonumber(os.getenv "RESOLVER_MAX_PATH_BYTES" or "") or 2048
local MAX_METHOD_BYTES = tonumber(os.getenv "RESOLVER_MAX_METHOD_BYTES" or "") or 16
local RESOLUTION_CACHE_MAX_ENTRIES = tonumber(os.getenv "RESOLVER_CACHE_MAX_ENTRIES" or "") or 20000
local REFRESH_META_MAX_HOSTS = tonumber(os.getenv "RESOLVER_REFRESH_META_MAX_HOSTS" or "") or 10000
local REFRESH_META_STALE_TTL_SEC = tonumber(os.getenv "RESOLVER_REFRESH_META_STALE_TTL_SEC" or "") or 86400
local RESOLVER_PERSIST_MIN_INTERVAL_SEC = tonumber(os.getenv "RESOLVER_PERSIST_MIN_INTERVAL_SEC" or "") or 5
local ALLOW_CENTRALIZED_BUNDLE_WRITES = (os.getenv "RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES" or "0") == "1"
local ALLOW_DIRECT_HOST_POLICY_APPLY = (os.getenv "RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY" or "0") == "1"
local ALLOW_PUBLIC_READ_REFRESH_QUEUE = (os.getenv "RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE" or "0") == "1"

local mutating_actions = {
  ApplyPolicyBundle = true,
  ApplyHostPolicyFromProof = true,
  InvalidateResolverCache = true,
  RunAutoDnsTick = true,
  ApplyDnsRefreshResult = true,
  ForceDnsRefreshHost = true,
  IssueDnsRefreshChallenge = true,
  SetAdmissionRule = true,
  RemoveAdmissionRule = true,
}
local last_persist_epoch = 0
local refresh_state_mutated = false
local request_allows_refresh_queue_mutation = false
local openssl_ok, openssl = pcall(require, "openssl")
local handler_strip_fields = {
  Nonce = true,
  nonce = true,
  ts = true,
  timestamp = true,
  Timestamp = true,
  ["X-Timestamp"] = true,
  Signature = true,
  signature = true,
  ["Signature-Ref"] = true,
  Authorization = true,
  authorization = true,
  auth = true,
  jwt = true,
  JWT = true,
  token = true,
  ["Device-Token"] = true,
  deviceToken = true,
  device_token = true,
  device = true,
  ["Actor-Id"] = true,
  Subject = true,
  Tenant = true,
  ["Tenant-Id"] = true,
  jwt_claims = true,
}

local state = persist.load("resolver_state", {
  policyMode = "off", -- off|observe|soft|enforce
  failOpen = true,
  cacheHints = {
    positiveTtlSec = 300,
    negativeTtlSec = 60,
    staleWhileRevalidateSec = 900,
    hardMaxStaleSec = 3600,
  },
  hostPolicies = {}, -- host -> { siteId, processId, moduleId, scheduler, routePrefix, status }
  sitePolicies = {}, -- siteId -> { processId, moduleId, scheduler, routePrefix, status }
  routePolicies = {}, -- host -> { defaultActionHint?, rules = { { pathPrefix, methods?, actionHint } } }
  dnsProofState = {}, -- host -> { state, checkedAt, validUntil, source, challengeRef, sequence }
  refreshMeta = {}, -- host -> { nextCheckAt, lastCheckAt, lastError, retryCount, pendingChallenge, challengeExpiresAt }
  autoDns = {
    enabled = false,
    refreshIntervalSec = 300,
    maxHostsPerRun = 100,
    staleGraceSec = 900,
    refreshOnStale = true,
    staleRefreshMinIntervalSec = 30,
    relayPath = "/~relay@1.0",
    cachePath = "/~cache@1.0",
    cronPath = "/~cron@1.0",
    dohEndpoint = "https://cloudflare-dns.com/dns-query",
    arweaveBase = "https://arweave.net",
    requireChallenge = false,
    challengeTtlSec = 300,
  },
  executionFlow = {
    mode = "slot_pinned_preflight",
    preflightSchedule = true,
    requireNumericSlot = true,
    singleFlightPerProcess = true,
    maxAttempts = 5,
    baseBackoffMs = 300,
    maxBackoffMs = 1000,
  },
  admission = {
    allowlistEnabled = false,
    allowHosts = {}, -- exact host -> { reason?, updatedAt? }
    denyHosts = {}, -- exact host -> { reason?, updatedAt? }
    updatedAt = nil,
  },
  resolutionCache = {}, -- host -> { host, siteId?, decision, reasonCode, mode, proofState, cachedAt, expiresAt, surface }
  bundleMeta = { -- latest applied bundle metadata
    snapshotId = nil,
    version = nil,
    generatedAt = nil,
    appliedAt = nil,
  },
  cacheMeta = {
    lastInvalidatedAt = nil,
  },
  lastResolvedAt = nil,
})

local function now_iso()
  return os.date "!%Y-%m-%dT%H:%M:%SZ"
end

local function plus_seconds_iso(seconds)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + math.max(0, tonumber(seconds) or 0))
end

local function sanitize_handler_message(msg)
  local out = {}
  for key, value in pairs(msg or {}) do
    if not handler_strip_fields[key] then
      out[key] = value
    end
  end
  return out
end

local function trim(text)
  if type(text) ~= "string" then
    return text
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_node_id(msg)
  local node_id = msg["Node-Id"] or msg.nodeId or msg["Resolver-Id"]
  if node_id == nil then
    return nil
  end
  local ok_len, err_len = validation.check_length(node_id, 128, "Node-Id")
  if not ok_len then
    return nil, err_len
  end
  return tostring(node_id)
end

local function read_request_id(msg)
  local request_id = msg["Request-Id"] or msg.requestId
  if type(request_id) ~= "string" then
    return ""
  end
  return trim(request_id) or ""
end

local function normalize_host(raw_host, field_name)
  local field = field_name or "Host"
  if type(raw_host) ~= "string" then
    return nil, ("invalid_type:%s"):format(field)
  end

  local host = trim(raw_host)
  if host == nil or host == "" then
    return nil, ("invalid_format:%s"):format(field)
  end

  -- Host header can contain a single ":<port>" suffix; strip it.
  local name, port = host:match("^([^:]+):(%d+)$")
  if name and port then
    host = name
  end

  host = string.lower(host)
  host = host:gsub("%.$", "")

  local ok_len, err_len = validation.check_length(host, MAX_HOST_BYTES, field)
  if not ok_len then
    return nil, err_len
  end

  if host == "" or host:find("%.%.", 1, true) then
    return nil, ("invalid_format:%s"):format(field)
  end
  if host:find("[/%?#@%[%] ]") then
    return nil, ("invalid_format:%s"):format(field)
  end
  if not host:match "^[a-z0-9%.%-]+$" then
    return nil, ("invalid_format:%s"):format(field)
  end

  for label in host:gmatch("[^.]+") do
    if #label == 0 or #label > 63 then
      return nil, ("invalid_format:%s"):format(field)
    end
    if label:sub(1, 1) == "-" or label:sub(-1) == "-" then
      return nil, ("invalid_format:%s"):format(field)
    end
  end

  return host
end

local function normalize_process_identifier(raw_value, field_name)
  if raw_value == nil then
    return nil
  end
  local value = trim(tostring(raw_value)) or ""
  if value == "" then
    return nil
  end
  local ok_len, err_len = validation.check_length(value, 128, field_name)
  if not ok_len then
    return nil, err_len
  end
  if #value < 20 or not value:match "^[A-Za-z0-9_-]+$" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  return value
end

local normalize_path

local function ensure_cache_hints()
  state.cacheHints = state.cacheHints or {}
  state.cacheHints.positiveTtlSec = tonumber(state.cacheHints.positiveTtlSec) or 300
  state.cacheHints.negativeTtlSec = tonumber(state.cacheHints.negativeTtlSec) or 60
  state.cacheHints.staleWhileRevalidateSec = tonumber(state.cacheHints.staleWhileRevalidateSec) or 900
  state.cacheHints.hardMaxStaleSec = tonumber(state.cacheHints.hardMaxStaleSec) or 3600
end

local function ensure_state_defaults()
  local mode = tostring(state.policyMode or "off"):lower()
  if not VALID_POLICY_MODES[mode] then
    mode = "off"
  end
  state.policyMode = mode
  state.failOpen = state.failOpen ~= false
  if type(state.hostPolicies) ~= "table" then
    state.hostPolicies = {}
  end
  if type(state.sitePolicies) ~= "table" then
    state.sitePolicies = {}
  end
  if type(state.routePolicies) ~= "table" then
    state.routePolicies = {}
  end
  if type(state.dnsProofState) ~= "table" then
    state.dnsProofState = {}
  end
  if type(state.refreshMeta) ~= "table" then
    state.refreshMeta = {}
  end
  if type(state.autoDns) ~= "table" then
    state.autoDns = {}
  end
  state.autoDns.enabled = state.autoDns.enabled == true
  state.autoDns.refreshIntervalSec = tonumber(state.autoDns.refreshIntervalSec) or 300
  if state.autoDns.refreshIntervalSec < 30 then
    state.autoDns.refreshIntervalSec = 30
  end
  if state.autoDns.refreshIntervalSec > 86400 then
    state.autoDns.refreshIntervalSec = 86400
  end
  state.autoDns.maxHostsPerRun = tonumber(state.autoDns.maxHostsPerRun) or 100
  if state.autoDns.maxHostsPerRun < 1 then
    state.autoDns.maxHostsPerRun = 1
  end
  if state.autoDns.maxHostsPerRun > 500 then
    state.autoDns.maxHostsPerRun = 500
  end
  state.autoDns.staleGraceSec = tonumber(state.autoDns.staleGraceSec) or 900
  if state.autoDns.staleGraceSec < 0 then
    state.autoDns.staleGraceSec = 0
  end
  if state.autoDns.staleGraceSec > 172800 then
    state.autoDns.staleGraceSec = 172800
  end
  state.autoDns.refreshOnStale = state.autoDns.refreshOnStale ~= false
  state.autoDns.staleRefreshMinIntervalSec = tonumber(state.autoDns.staleRefreshMinIntervalSec) or 30
  if state.autoDns.staleRefreshMinIntervalSec < 0 then
    state.autoDns.staleRefreshMinIntervalSec = 0
  end
  if state.autoDns.staleRefreshMinIntervalSec > 86400 then
    state.autoDns.staleRefreshMinIntervalSec = 86400
  end
  state.autoDns.requireChallenge = state.autoDns.requireChallenge == true
  state.autoDns.challengeTtlSec = tonumber(state.autoDns.challengeTtlSec) or 300
  if state.autoDns.challengeTtlSec < 30 then
    state.autoDns.challengeTtlSec = 30
  end
  if state.autoDns.challengeTtlSec > 7200 then
    state.autoDns.challengeTtlSec = 7200
  end
  state.autoDns.relayPath = state.autoDns.relayPath or "/~relay@1.0"
  state.autoDns.cachePath = state.autoDns.cachePath or "/~cache@1.0"
  state.autoDns.cronPath = state.autoDns.cronPath or "/~cron@1.0"
  state.autoDns.dohEndpoint = state.autoDns.dohEndpoint or "https://cloudflare-dns.com/dns-query"
  state.autoDns.arweaveBase = state.autoDns.arweaveBase or "https://arweave.net"
  if type(state.executionFlow) ~= "table" then
    state.executionFlow = {}
  end
  local flow_mode = tostring(state.executionFlow.mode or "slot_pinned_preflight"):lower()
  if flow_mode ~= "slot_pinned_preflight" then
    flow_mode = "slot_pinned_preflight"
  end
  state.executionFlow.mode = flow_mode
  state.executionFlow.preflightSchedule = state.executionFlow.preflightSchedule ~= false
  state.executionFlow.requireNumericSlot = state.executionFlow.requireNumericSlot ~= false
  state.executionFlow.singleFlightPerProcess = state.executionFlow.singleFlightPerProcess ~= false
  state.executionFlow.maxAttempts = tonumber(state.executionFlow.maxAttempts) or 5
  if state.executionFlow.maxAttempts < 1 then
    state.executionFlow.maxAttempts = 1
  end
  if state.executionFlow.maxAttempts > 10 then
    state.executionFlow.maxAttempts = 10
  end
  state.executionFlow.baseBackoffMs = tonumber(state.executionFlow.baseBackoffMs) or 300
  if state.executionFlow.baseBackoffMs < 50 then
    state.executionFlow.baseBackoffMs = 50
  end
  if state.executionFlow.baseBackoffMs > 5000 then
    state.executionFlow.baseBackoffMs = 5000
  end
  state.executionFlow.maxBackoffMs = tonumber(state.executionFlow.maxBackoffMs) or 1000
  if state.executionFlow.maxBackoffMs < state.executionFlow.baseBackoffMs then
    state.executionFlow.maxBackoffMs = state.executionFlow.baseBackoffMs
  end
  if state.executionFlow.maxBackoffMs > 10000 then
    state.executionFlow.maxBackoffMs = 10000
  end
  if type(state.admission) ~= "table" then
    state.admission = {}
  end
  state.admission.allowlistEnabled = state.admission.allowlistEnabled == true
  if type(state.admission.allowHosts) ~= "table" then
    state.admission.allowHosts = {}
  end
  if type(state.admission.denyHosts) ~= "table" then
    state.admission.denyHosts = {}
  end
  for host, entry in pairs(state.admission.allowHosts) do
    local normalized_host = normalize_host(host, "admission.allowHosts")
    if not normalized_host then
      state.admission.allowHosts[host] = nil
    else
      if normalized_host ~= host then
        state.admission.allowHosts[host] = nil
      end
      if type(entry) ~= "table" then
        entry = {}
      end
      state.admission.allowHosts[normalized_host] = {
        reason = entry.reason,
        updatedAt = entry.updatedAt,
      }
    end
  end
  for host, entry in pairs(state.admission.denyHosts) do
    local normalized_host = normalize_host(host, "admission.denyHosts")
    if not normalized_host then
      state.admission.denyHosts[host] = nil
    else
      if normalized_host ~= host then
        state.admission.denyHosts[host] = nil
      end
      if type(entry) ~= "table" then
        entry = {}
      end
      state.admission.denyHosts[normalized_host] = {
        reason = entry.reason,
        updatedAt = entry.updatedAt,
      }
    end
  end
  if type(state.resolutionCache) ~= "table" then
    state.resolutionCache = {}
  end
  if type(state.bundleMeta) ~= "table" then
    state.bundleMeta = { appliedAt = nil }
  end
  if type(state.cacheMeta) ~= "table" then
    state.cacheMeta = { lastInvalidatedAt = nil }
  end
  ensure_cache_hints()
end

ensure_state_defaults()

local function normalize_mode(mode)
  local normalized = tostring(mode or state.policyMode or "off"):lower()
  if VALID_POLICY_MODES[normalized] then
    return normalized, nil
  end
  return "off", "ERROR_INVALID_POLICY_MODE_FALLBACK"
end

local function parse_fail_open(value, current_value)
  if value == nil then
    return current_value
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    if value == 1 then
      return true
    end
    if value == 0 then
      return false
    end
  end
  if type(value) == "string" then
    local lower = string.lower(value)
    if lower == "1" or lower == "true" or lower == "yes" then
      return true
    end
    if lower == "0" or lower == "false" or lower == "no" then
      return false
    end
  end
  return nil, "invalid_boolean:Fail-Open"
end

local function parse_boolean_field(value, field_name, current_value)
  local parsed, parse_err = parse_fail_open(value, current_value)
  if parsed == nil then
    return nil, parse_err or ("invalid_boolean:%s"):format(field_name)
  end
  return parsed, nil
end

local function normalize_device_path(raw_value, field_name)
  if raw_value == nil then
    return nil
  end
  if type(raw_value) ~= "string" then
    return nil, ("invalid_type:%s"):format(field_name)
  end
  local normalized, path_err = normalize_path(raw_value, field_name)
  if not normalized then
    return nil, path_err
  end
  if not normalized:match "^/~[a-z0-9%-]+@[%d%.]+$" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  return normalized
end

local function normalize_https_url(raw_value, field_name)
  if raw_value == nil then
    return nil
  end
  if type(raw_value) ~= "string" then
    return nil, ("invalid_type:%s"):format(field_name)
  end
  local value = trim(raw_value) or ""
  if value == "" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  if not value:match "^https://[%w%-%._~:/%?#%[%]@!$&'()%*+,;=]+$" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  local ok_len, err_len = validation.check_length(value, 512, field_name)
  if not ok_len then
    return nil, err_len
  end
  return value
end

local function normalize_auto_dns(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:autoDns"
  end

  local out = {}
  local function parse_int(raw_value, field_name, min_value, max_value)
    local value = tonumber(raw_value)
    if not value or value % 1 ~= 0 then
      return nil, ("invalid_number:%s"):format(field_name)
    end
    if value < min_value or value > max_value then
      return nil, ("invalid_range:%s"):format(field_name)
    end
    return value, nil
  end
  if input.enabled ~= nil then
    local enabled, enabled_err = parse_boolean_field(input.enabled, "autoDns.enabled", state.autoDns.enabled == true)
    if enabled_err then
      return nil, enabled_err
    end
    out.enabled = enabled
  end
  if input.refreshOnStale ~= nil then
    local refresh_on_stale, refresh_on_stale_err =
      parse_boolean_field(input.refreshOnStale, "autoDns.refreshOnStale", state.autoDns.refreshOnStale ~= false)
    if refresh_on_stale_err then
      return nil, refresh_on_stale_err
    end
    out.refreshOnStale = refresh_on_stale
  end
  if input.requireChallenge ~= nil then
    local require_challenge, require_challenge_err = parse_boolean_field(
      input.requireChallenge,
      "autoDns.requireChallenge",
      state.autoDns.requireChallenge == true
    )
    if require_challenge_err then
      return nil, require_challenge_err
    end
    out.requireChallenge = require_challenge
  end
  if input.refreshIntervalSec ~= nil then
    local parsed, parsed_err = parse_int(input.refreshIntervalSec, "autoDns.refreshIntervalSec", 30, 86400)
    if parsed_err then
      return nil, parsed_err
    end
    out.refreshIntervalSec = parsed
  end
  if input.maxHostsPerRun ~= nil then
    local parsed, parsed_err = parse_int(input.maxHostsPerRun, "autoDns.maxHostsPerRun", 1, 500)
    if parsed_err then
      return nil, parsed_err
    end
    out.maxHostsPerRun = parsed
  end
  if input.staleGraceSec ~= nil then
    local parsed, parsed_err = parse_int(input.staleGraceSec, "autoDns.staleGraceSec", 0, 172800)
    if parsed_err then
      return nil, parsed_err
    end
    out.staleGraceSec = parsed
  end
  if input.staleRefreshMinIntervalSec ~= nil then
    local parsed, parsed_err = parse_int(
      input.staleRefreshMinIntervalSec,
      "autoDns.staleRefreshMinIntervalSec",
      0,
      86400
    )
    if parsed_err then
      return nil, parsed_err
    end
    out.staleRefreshMinIntervalSec = parsed
  end
  if input.challengeTtlSec ~= nil then
    local parsed, parsed_err = parse_int(input.challengeTtlSec, "autoDns.challengeTtlSec", 30, 7200)
    if parsed_err then
      return nil, parsed_err
    end
    out.challengeTtlSec = parsed
  end
  if input.relayPath ~= nil then
    local relay_path, relay_path_err = normalize_device_path(input.relayPath, "autoDns.relayPath")
    if relay_path_err then
      return nil, relay_path_err
    end
    out.relayPath = relay_path
  end
  if input.cachePath ~= nil then
    local cache_path, cache_path_err = normalize_device_path(input.cachePath, "autoDns.cachePath")
    if cache_path_err then
      return nil, cache_path_err
    end
    out.cachePath = cache_path
  end
  if input.cronPath ~= nil then
    local cron_path, cron_path_err = normalize_device_path(input.cronPath, "autoDns.cronPath")
    if cron_path_err then
      return nil, cron_path_err
    end
    out.cronPath = cron_path
  end
  if input.dohEndpoint ~= nil then
    local doh_endpoint, doh_endpoint_err = normalize_https_url(input.dohEndpoint, "autoDns.dohEndpoint")
    if doh_endpoint_err then
      return nil, doh_endpoint_err
    end
    out.dohEndpoint = doh_endpoint
  end
  if input.arweaveBase ~= nil then
    local arweave_base, arweave_base_err = normalize_https_url(input.arweaveBase, "autoDns.arweaveBase")
    if arweave_base_err then
      return nil, arweave_base_err
    end
    out.arweaveBase = arweave_base
  end
  return out
end

local function normalize_cache_hints(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:Cache-Hints"
  end
  local function parse_cache_hint_number(raw_value, hint_name, min_value, max_value)
    local value = tonumber(raw_value)
    if not value or value % 1 ~= 0 then
      return nil, ("invalid_number:%s"):format(hint_name)
    end
    if value < min_value or value > max_value then
      return nil, ("invalid_range:%s"):format(hint_name)
    end
    return value, nil
  end
  local out = {}
  if input.positiveTtlSec ~= nil then
    local parsed, parse_err = parse_cache_hint_number(input.positiveTtlSec, "positiveTtlSec", 1, 86400)
    if parse_err then
      return nil, parse_err
    end
    out.positiveTtlSec = parsed
  end
  if input.negativeTtlSec ~= nil then
    local parsed, parse_err = parse_cache_hint_number(input.negativeTtlSec, "negativeTtlSec", 1, 86400)
    if parse_err then
      return nil, parse_err
    end
    out.negativeTtlSec = parsed
  end
  if input.staleWhileRevalidateSec ~= nil then
    local parsed, parse_err =
      parse_cache_hint_number(input.staleWhileRevalidateSec, "staleWhileRevalidateSec", 0, 86400)
    if parse_err then
      return nil, parse_err
    end
    out.staleWhileRevalidateSec = parsed
  end
  if input.hardMaxStaleSec ~= nil then
    local parsed, parse_err = parse_cache_hint_number(input.hardMaxStaleSec, "hardMaxStaleSec", 0, 172800)
    if parse_err then
      return nil, parse_err
    end
    out.hardMaxStaleSec = parsed
  end
  return out
end

local function normalize_execution_flow(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:Execution-Flow"
  end
  local out = {}

  local function parse_int(raw_value, field_name, min_value, max_value)
    local value = tonumber(raw_value)
    if not value or value % 1 ~= 0 then
      return nil, ("invalid_number:%s"):format(field_name)
    end
    if value < min_value or value > max_value then
      return nil, ("invalid_range:%s"):format(field_name)
    end
    return value, nil
  end

  if input.mode ~= nil then
    local mode = tostring(input.mode):lower()
    if mode ~= "slot_pinned_preflight" then
      return nil, "invalid_format:Execution-Flow.mode"
    end
    out.mode = mode
  end
  if input.preflightSchedule ~= nil then
    local parsed, parsed_err = parse_boolean_field(
      input.preflightSchedule,
      "Execution-Flow.preflightSchedule",
      state.executionFlow.preflightSchedule ~= false
    )
    if parsed_err then
      return nil, parsed_err
    end
    out.preflightSchedule = parsed
  end
  if input.requireNumericSlot ~= nil then
    local parsed, parsed_err = parse_boolean_field(
      input.requireNumericSlot,
      "Execution-Flow.requireNumericSlot",
      state.executionFlow.requireNumericSlot ~= false
    )
    if parsed_err then
      return nil, parsed_err
    end
    out.requireNumericSlot = parsed
  end
  if input.singleFlightPerProcess ~= nil then
    local parsed, parsed_err = parse_boolean_field(
      input.singleFlightPerProcess,
      "Execution-Flow.singleFlightPerProcess",
      state.executionFlow.singleFlightPerProcess ~= false
    )
    if parsed_err then
      return nil, parsed_err
    end
    out.singleFlightPerProcess = parsed
  end
  if input.maxAttempts ~= nil then
    local parsed, parsed_err = parse_int(input.maxAttempts, "Execution-Flow.maxAttempts", 1, 10)
    if parsed_err then
      return nil, parsed_err
    end
    out.maxAttempts = parsed
  end
  if input.baseBackoffMs ~= nil then
    local parsed, parsed_err = parse_int(input.baseBackoffMs, "Execution-Flow.baseBackoffMs", 50, 5000)
    if parsed_err then
      return nil, parsed_err
    end
    out.baseBackoffMs = parsed
  end
  if input.maxBackoffMs ~= nil then
    local parsed, parsed_err = parse_int(input.maxBackoffMs, "Execution-Flow.maxBackoffMs", 50, 10000)
    if parsed_err then
      return nil, parsed_err
    end
    out.maxBackoffMs = parsed
  end
  if out.baseBackoffMs ~= nil and out.maxBackoffMs ~= nil and out.maxBackoffMs < out.baseBackoffMs then
    return nil, "invalid_relation:Execution-Flow.maxBackoffMs"
  end
  return out
end

local function normalize_host_policies(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:hostPolicies"
  end
  local out = {}
  for host_key, spec in pairs(input) do
    if type(spec) == "table" then
      local host, host_err = normalize_host(host_key, "hostPolicies")
      if not host then
        return nil, host_err
      end
      local site_id = spec.siteId or spec["Site-Id"] or spec.site_id
      if site_id == nil then
        return nil, ("missing_field:hostPolicies.siteId:%s"):format(host)
      end
      site_id = trim(tostring(site_id)) or ""
      local ok_site_len, site_len_err = validation.check_length(site_id, 128, "Site-Id")
      if not ok_site_len or site_id == "" then
        return nil, site_len_err or ("invalid_format:Site-Id:%s"):format(host)
      end

      local process_id, process_err =
        normalize_process_identifier(spec.processId or spec["Process-Id"] or spec.process_id, "Process-Id")
      if process_err then
        return nil, process_err
      end
      local module_id, module_err =
        normalize_process_identifier(spec.moduleId or spec["Module-Id"] or spec.module_id, "Module-Id")
      if module_err then
        return nil, module_err
      end
      local scheduler_id, scheduler_err =
        normalize_process_identifier(spec.scheduler or spec["Scheduler-Id"] or spec.scheduler_id, "Scheduler-Id")
      if scheduler_err then
        return nil, scheduler_err
      end

      local route_prefix = spec.routePrefix or spec["Route-Prefix"] or spec.route_prefix
      if route_prefix ~= nil then
        local normalized_route_prefix, route_prefix_err = normalize_path(tostring(route_prefix), "Route-Prefix")
        if not normalized_route_prefix then
          return nil, route_prefix_err
        end
        route_prefix = normalized_route_prefix
      end

      local status = spec.status
      if status ~= nil then
        status = trim(tostring(status)) or ""
        local ok_status_len, status_len_err = validation.check_length(status, 64, "status")
        if not ok_status_len or status == "" then
          return nil, status_len_err or ("invalid_format:status:%s"):format(host)
        end
      end
      local entry = {
        siteId = site_id,
        processId = process_id,
        moduleId = module_id,
        scheduler = scheduler_id,
        routePrefix = route_prefix,
        status = status,
      }
      out[host] = entry
    end
  end
  return out
end

local function normalize_site_policies(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:sitePolicies"
  end
  local out = {}
  for site_key, spec in pairs(input) do
    if type(spec) == "table" then
      local site_id = tostring(spec.siteId or spec["Site-Id"] or spec.site_id or site_key)
      local ok_len, err_len = validation.check_length(site_id, 128, "Site-Id")
      if not ok_len or site_id == "" then
        return nil, err_len or "invalid_format:Site-Id"
      end
      local process_id, process_err =
        normalize_process_identifier(spec.processId or spec["Process-Id"] or spec.process_id, "Process-Id")
      if process_err then
        return nil, process_err
      end
      local module_id, module_err =
        normalize_process_identifier(spec.moduleId or spec["Module-Id"] or spec.module_id, "Module-Id")
      if module_err then
        return nil, module_err
      end
      local scheduler_id, scheduler_err =
        normalize_process_identifier(spec.scheduler or spec["Scheduler-Id"] or spec.scheduler_id, "Scheduler-Id")
      if scheduler_err then
        return nil, scheduler_err
      end
      local route_prefix = spec.routePrefix or spec["Route-Prefix"] or spec.route_prefix
      if route_prefix ~= nil then
        local normalized_route_prefix, route_prefix_err = normalize_path(tostring(route_prefix), "Route-Prefix")
        if not normalized_route_prefix then
          return nil, route_prefix_err
        end
        route_prefix = normalized_route_prefix
      end
      local status = spec.status
      if status ~= nil then
        status = trim(tostring(status)) or ""
        local ok_status_len, status_len_err = validation.check_length(status, 64, "status")
        if not ok_status_len or status == "" then
          return nil, status_len_err or "invalid_format:status"
        end
      end
      out[site_id] = {
        processId = process_id,
        moduleId = module_id,
        scheduler = scheduler_id,
        routePrefix = route_prefix,
        status = status,
      }
    end
  end
  return out
end

local function normalize_dns_proof_state(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:dnsProofState"
  end
  local out = {}
  for host_key, spec in pairs(input) do
    if type(spec) == "table" then
      local host, host_err = normalize_host(host_key, "dnsProofState")
      if not host then
        return nil, host_err
      end
      local proof_state = tostring(spec.state or spec.dnsProofState or "unchecked"):lower()
      if proof_state ~= "valid" and proof_state ~= "expired" and proof_state ~= "missing" and proof_state ~= "unchecked" then
        proof_state = "unchecked"
      end
      local sequence = nil
      if spec.sequence ~= nil or spec.dnsProofSeq ~= nil then
        sequence = tonumber(spec.sequence or spec.dnsProofSeq)
        if not sequence or sequence % 1 ~= 0 or sequence < 0 or sequence > 2147483647 then
          return nil, ("invalid_range:dnsProofState.sequence:%s"):format(host)
        end
      end
      out[host] = {
        state = proof_state,
        checkedAt = spec.checkedAt or spec.dnsProofCheckedAt,
        validUntil = spec.validUntil or spec.dnsProofValidUntil,
        source = spec.source,
        challengeRef = spec.challengeRef,
        sequence = sequence,
      }
    end
  end
  return out
end

local function normalize_method(raw_method, field_name)
  local field = field_name or "Method"
  if type(raw_method) ~= "string" then
    return nil, ("invalid_type:%s"):format(field)
  end
  local method = string.upper(trim(raw_method) or "")
  if method == "" then
    return nil, ("invalid_format:%s"):format(field)
  end
  local ok_len, err_len = validation.check_length(method, MAX_METHOD_BYTES, field)
  if not ok_len then
    return nil, err_len
  end
  if not method:match "^[A-Z]+$" then
    return nil, ("invalid_format:%s"):format(field)
  end
  return method
end

normalize_path = function(raw_path, field_name)
  local field = field_name or "Path"
  if type(raw_path) ~= "string" then
    return nil, ("invalid_type:%s"):format(field)
  end
  local path = trim(raw_path) or ""
  if path == "" then
    path = "/"
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  local q_idx = path:find("?", 1, true)
  if q_idx then
    path = path:sub(1, q_idx - 1)
  end
  local h_idx = path:find("#", 1, true)
  if h_idx then
    path = path:sub(1, h_idx - 1)
  end
  if path == "" then
    path = "/"
  end
  local ok_len, err_len = validation.check_length(path, MAX_PATH_BYTES, field)
  if not ok_len then
    return nil, err_len
  end
  if path:find("%s") then
    return nil, ("invalid_format:%s"):format(field)
  end
  return path
end

local function normalize_site_id(raw_site_id, field_name)
  local field = field_name or "Site-Id"
  if type(raw_site_id) ~= "string" then
    return nil, ("invalid_type:%s"):format(field)
  end
  local site_id = trim(raw_site_id) or ""
  if site_id == "" then
    return nil, ("invalid_format:%s"):format(field)
  end
  local ok_len, err_len = validation.check_length(site_id, 128, field)
  if not ok_len then
    return nil, err_len
  end
  return site_id
end

local function normalize_method_set(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:methods"
  end
  local out = {}
  for _, method in ipairs(input) do
    local normalized_method, method_err = normalize_method(method, "methods")
    if not normalized_method then
      return nil, method_err
    end
    out[normalized_method] = true
  end
  return out
end

local function normalize_route_policies(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:routePolicies"
  end
  local out = {}
  for host_key, spec in pairs(input) do
    if type(spec) == "table" then
      local host, host_err = normalize_host(host_key, "routePolicies")
      if not host then
        return nil, host_err
      end
      local entry = {}
      if spec.defaultActionHint ~= nil then
        local ok_len_hint, err_len_hint =
          validation.check_length(spec.defaultActionHint, 128, "defaultActionHint")
        if not ok_len_hint then
          return nil, err_len_hint
        end
        entry.defaultActionHint = tostring(spec.defaultActionHint)
      end
      entry.rules = {}
      local rules = spec.rules or {}
      if type(rules) ~= "table" then
        return nil, "invalid_type:routePolicies.rules"
      end
      for _, rule in ipairs(rules) do
        if type(rule) == "table" then
          local prefix = rule.pathPrefix or rule.path or "/"
          local normalized_prefix, prefix_err = normalize_path(prefix, "pathPrefix")
          if not normalized_prefix then
            return nil, prefix_err
          end
          local methods, methods_err = normalize_method_set(rule.methods)
          if methods_err then
            return nil, methods_err
          end
          local action_hint = tostring(rule.actionHint or entry.defaultActionHint or "read")
          local ok_len_action, err_len_action = validation.check_length(action_hint, 128, "actionHint")
          if not ok_len_action then
            return nil, err_len_action
          end
          table.insert(entry.rules, {
            pathPrefix = normalized_prefix,
            methods = methods,
            actionHint = action_hint,
          })
        end
      end
      out[host] = entry
    end
  end
  return out
end

local function validate_policy_graph(host_policies, site_policies)
  for host, spec in pairs(host_policies or {}) do
    local site_id = spec and spec.siteId
    if type(site_id) ~= "string" or site_id == "" then
      return nil, ("missing_site_id:hostPolicies.%s"):format(host)
    end
    local site_spec = site_policies and site_policies[site_id] or nil
    local process_id = (spec and spec.processId) or (site_spec and site_spec.processId)
    if type(process_id) ~= "string" or process_id == "" then
      return nil, ("missing_process_mapping:hostPolicies.%s"):format(host)
    end
  end
  return true, nil
end

local function infer_site_process(host, host_policy)
  local site_id = host_policy and host_policy.siteId or nil
  local site_policy = site_id and state.sitePolicies[site_id] or nil

  local site_obj
  local process_obj

  if site_id then
    site_obj = {
      siteId = site_id,
      host = host,
      status = (host_policy and host_policy.status) or (site_policy and site_policy.status) or "unknown",
    }

    local process_id = (host_policy and host_policy.processId) or (site_policy and site_policy.processId)
    if process_id then
      process_obj = {
        processId = process_id,
        moduleId = (host_policy and host_policy.moduleId) or (site_policy and site_policy.moduleId),
        scheduler = (host_policy and host_policy.scheduler) or (site_policy and site_policy.scheduler),
        routePrefix = (host_policy and host_policy.routePrefix) or (site_policy and site_policy.routePrefix),
      }
    end
  end

  return site_obj, process_obj
end

local function default_site_id_from_host(host)
  local token = tostring(host or ""):lower():gsub("[^a-z0-9]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if token == "" then
    token = "host"
  end
  token = token:sub(1, 96)
  return "site-" .. token
end

local function upsert_host_policy_from_proof(host, msg)
  local site_id, site_err = normalize_site_id(msg["Site-Id"] or msg.SiteId or default_site_id_from_host(host), "Site-Id")
  if not site_id then
    return nil, site_err, "Site-Id"
  end
  local process_id, process_err = normalize_process_identifier(msg["Process-Id"] or msg.ProcessId, "Process-Id")
  if process_err then
    return nil, process_err, "Process-Id"
  end
  if process_id == nil then
    return nil, "missing_field:Process-Id", "Process-Id"
  end
  local module_id, module_err = normalize_process_identifier(msg["Module-Id"] or msg.ModuleId, "Module-Id")
  if module_err then
    return nil, module_err, "Module-Id"
  end
  local scheduler_id, scheduler_err =
    normalize_process_identifier(msg["Scheduler-Id"] or msg.SchedulerId, "Scheduler-Id")
  if scheduler_err then
    return nil, scheduler_err, "Scheduler-Id"
  end
  local route_prefix, route_prefix_err = normalize_path(tostring(msg["Route-Prefix"] or msg.RoutePrefix or "/"), "Route-Prefix")
  if not route_prefix then
    return nil, route_prefix_err, "Route-Prefix"
  end
  local status = trim(tostring(msg.Status or "active")) or "active"
  local ok_status_len, status_len_err = validation.check_length(status, 64, "Status")
  if not ok_status_len or status == "" then
    return nil, status_len_err or "invalid_format:Status", "Status"
  end

  state.hostPolicies[host] = {
    siteId = site_id,
    processId = process_id,
    moduleId = module_id,
    scheduler = scheduler_id,
    routePrefix = route_prefix,
    status = status,
  }

  local existing_site = state.sitePolicies[site_id] or {}
  state.sitePolicies[site_id] = {
    processId = process_id,
    moduleId = module_id or existing_site.moduleId,
    scheduler = scheduler_id or existing_site.scheduler,
    routePrefix = route_prefix or existing_site.routePrefix,
    status = status,
  }

  local default_action_hint = trim(tostring(msg["Action-Hint"] or msg.ActionHint or "")) or ""
  if default_action_hint ~= "" then
    local ok_hint_len, hint_len_err = validation.check_length(default_action_hint, 128, "Action-Hint")
    if not ok_hint_len then
      return nil, hint_len_err, "Action-Hint"
    end
    local route_policy = state.routePolicies[host] or {}
    route_policy.defaultActionHint = default_action_hint
    route_policy.rules = route_policy.rules or {}
    state.routePolicies[host] = route_policy
  end

  return {
    siteId = site_id,
    processId = process_id,
    moduleId = module_id,
    scheduler = scheduler_id,
    routePrefix = route_prefix,
    status = status,
  }, nil, nil
end

local function epoch_to_iso(epoch)
  if not epoch then
    return nil
  end
  return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function iso_to_epoch(value)
  if type(value) ~= "string" then
    return nil
  end
  local year, month, day, hour, min, sec =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not year then
    return nil
  end
  local local_epoch = os.time {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false,
  }
  if not local_epoch then
    return nil
  end
  local local_parts = os.date("*t", local_epoch)
  local utc_parts = os.date("!*t", local_epoch)
  local_parts.isdst = false
  utc_parts.isdst = false
  local offset = os.difftime(os.time(local_parts), os.time(utc_parts))
  return local_epoch + offset
end

local function normalize_proof_state(value)
  if value == nil then
    return nil
  end
  local proof_state = string.lower(trim(tostring(value)) or "")
  if proof_state == "valid" or proof_state == "expired" or proof_state == "missing" or proof_state == "unchecked" then
    return proof_state
  end
  return nil
end

local function build_cache_payload(host_known, proof_payload, surface_key, cache_state, cache_window)
  ensure_cache_hints()
  local ttl = host_known and state.cacheHints.positiveTtlSec or state.cacheHints.negativeTtlSec
  local now_epoch = os.time()
  local expires_epoch = cache_window and cache_window.expiresAtEpoch or (now_epoch + ttl)
  local hard_expire_epoch = cache_window and cache_window.hardExpireEpoch
    or (expires_epoch + state.cacheHints.hardMaxStaleSec)
  local stale_until_epoch = cache_window and cache_window.staleUntilEpoch
    or (expires_epoch + state.cacheHints.staleWhileRevalidateSec)
  if stale_until_epoch > hard_expire_epoch then
    stale_until_epoch = hard_expire_epoch
  end
  local expires_at = epoch_to_iso(expires_epoch)
  local dns_next_check_at = proof_payload.dnsProofValidUntil or epoch_to_iso(now_epoch + state.cacheHints.negativeTtlSec)
  local key_prefix = surface_key or "host"
  local state_value = cache_state or "miss"
  local stale = state_value == "stale"
  local hit = state_value == "hit" or state_value == "negative_hit" or stale
  local negative = state_value == "negative_hit"
  return {
    cacheable = true,
    key = host_known and ("resolver:" .. key_prefix .. ":hit") or ("resolver:" .. key_prefix .. ":miss"),
    cacheState = state_value,
    hit = hit,
    stale = stale,
    staleWhileRevalidate = stale,
    negative = negative,
    ttlSec = ttl,
    expiresAt = expires_at,
    staleUntilAt = epoch_to_iso(stale_until_epoch),
    hardExpiresAt = epoch_to_iso(hard_expire_epoch),
    revalidateAfterAt = expires_at,
    dnsNextCheckAt = dns_next_check_at,
    positiveTtlSec = state.cacheHints.positiveTtlSec,
    negativeTtlSec = state.cacheHints.negativeTtlSec,
    staleWhileRevalidateSec = state.cacheHints.staleWhileRevalidateSec,
    hardMaxStaleSec = state.cacheHints.hardMaxStaleSec,
  }
end

local function make_cache_key(surface, host, path, method, mode)
  local mode_part = mode or "off"
  if surface == "route" then
    return table.concat({ "route", mode_part, host or "", path or "/", method or "GET" }, "|")
  end
  return table.concat({ "host", mode_part, host or "" }, "|")
end

local function get_cached_resolution(cache_key)
  local entry = state.resolutionCache[cache_key]
  if not entry then
    return nil, "miss"
  end
  local now_epoch = os.time()
  local hard_expire_epoch = entry.hardExpireEpoch
  if hard_expire_epoch and now_epoch > hard_expire_epoch then
    state.resolutionCache[cache_key] = nil
    return nil, "miss"
  end
  if entry.expiresAtEpoch and now_epoch <= entry.expiresAtEpoch then
    if entry.negative then
      return entry, "negative_hit"
    end
    return entry, "hit"
  end
  if entry.staleUntilEpoch and now_epoch <= entry.staleUntilEpoch then
    return entry, "stale"
  end
  state.resolutionCache[cache_key] = nil
  return nil, "miss"
end

local function upsert_resolution_cache(cache_key, host, data)
  local now_epoch = os.time()
  local ttl = data.hostKnown and state.cacheHints.positiveTtlSec or state.cacheHints.negativeTtlSec
  local expires_epoch = now_epoch + ttl
  local stale_until_epoch = expires_epoch + state.cacheHints.staleWhileRevalidateSec
  local hard_expire_epoch = expires_epoch + state.cacheHints.hardMaxStaleSec
  if stale_until_epoch > hard_expire_epoch then
    stale_until_epoch = hard_expire_epoch
  end
  state.resolutionCache[cache_key] = {
    cacheKey = cache_key,
    host = host,
    siteId = data.siteId,
    decision = data.decision,
    reasonCode = data.reasonCode,
    mode = data.mode,
    proofState = data.proofState,
    cachedAt = now_iso(),
    expiresAt = epoch_to_iso(expires_epoch),
    expiresAtEpoch = expires_epoch,
    staleUntilAt = epoch_to_iso(stale_until_epoch),
    staleUntilEpoch = stale_until_epoch,
    hardExpireAt = epoch_to_iso(hard_expire_epoch),
    hardExpireEpoch = hard_expire_epoch,
    dnsNextCheckAt = data.dnsNextCheckAt,
    surface = data.surface,
    actionHint = data.actionHint,
    hostKnown = data.hostKnown,
    path = data.path,
    method = data.method,
    process = data.process,
    site = data.site,
    proof = data.proof,
    executionFlow = data.executionFlow,
    negative = data.hostKnown ~= true,
  }
end

local function invalidate_cache_by_host(host)
  local removed = 0
  for key, entry in pairs(state.resolutionCache) do
    if entry and entry.host == host then
      state.resolutionCache[key] = nil
      removed = removed + 1
    end
  end
  return removed
end

local function invalidate_cache_by_site(site_id)
  local removed = 0
  for host, entry in pairs(state.resolutionCache) do
    if entry and entry.siteId == site_id then
      state.resolutionCache[host] = nil
      removed = removed + 1
    end
  end
  return removed
end

local function invalidate_cache_all()
  local removed = 0
  for host, _ in pairs(state.resolutionCache) do
    state.resolutionCache[host] = nil
    removed = removed + 1
  end
  return removed
end

local function prune_resolution_cache()
  local now_epoch = os.time()
  local removed = 0
  local survivors = {}
  local remaining = 0

  for key, entry in pairs(state.resolutionCache) do
    local stale_until_epoch = entry and entry.staleUntilEpoch
    if stale_until_epoch and now_epoch > stale_until_epoch then
      state.resolutionCache[key] = nil
      removed = removed + 1
    else
      remaining = remaining + 1
      table.insert(survivors, { key = key, expiresAtEpoch = entry and entry.expiresAtEpoch or 0 })
    end
  end

  if remaining > RESOLUTION_CACHE_MAX_ENTRIES then
    table.sort(survivors, function(a, b)
      return (a.expiresAtEpoch or 0) < (b.expiresAtEpoch or 0)
    end)
    local overflow = remaining - RESOLUTION_CACHE_MAX_ENTRIES
    for i = 1, overflow do
      local victim = survivors[i]
      if victim and state.resolutionCache[victim.key] ~= nil then
        state.resolutionCache[victim.key] = nil
        removed = removed + 1
      end
    end
  end

  return removed
end

local function refresh_meta_activity_epoch(meta)
  if type(meta) ~= "table" then
    return 0
  end
  local candidates = {
    iso_to_epoch(meta.lastCheckAt),
    iso_to_epoch(meta.nextCheckAt),
    iso_to_epoch(meta.refreshRequestedAt),
    iso_to_epoch(meta.challengeIssuedAt),
    iso_to_epoch(meta.challengeExpiresAt),
  }
  local latest = 0
  for _, epoch in ipairs(candidates) do
    if epoch and epoch > latest then
      latest = epoch
    end
  end
  return latest
end

local function prune_refresh_meta()
  if type(state.refreshMeta) ~= "table" then
    return 0
  end

  local now_epoch = os.time()
  local removed = 0

  if REFRESH_META_STALE_TTL_SEC > 0 then
    for host, meta in pairs(state.refreshMeta) do
      local mapped = state.hostPolicies[host] ~= nil
      local pending_challenge = type(meta.pendingChallenge) == "string" and meta.pendingChallenge ~= ""
      local last_activity = refresh_meta_activity_epoch(meta)
      if not mapped and not pending_challenge and last_activity > 0 and (now_epoch - last_activity) >= REFRESH_META_STALE_TTL_SEC then
        state.refreshMeta[host] = nil
        removed = removed + 1
      end
    end
  end

  if REFRESH_META_MAX_HOSTS <= 0 then
    if removed > 0 then
      refresh_state_mutated = true
    end
    return removed
  end

  local count = 0
  local entries = {}
  for host, meta in pairs(state.refreshMeta) do
    count = count + 1
    local mapped = state.hostPolicies[host] ~= nil
    local pending_challenge = type(meta.pendingChallenge) == "string" and meta.pendingChallenge ~= ""
    local priority = 0
    if mapped then
      priority = priority + 2
    end
    if pending_challenge then
      priority = priority + 1
    end
    entries[#entries + 1] = {
      host = host,
      priority = priority,
      activity = refresh_meta_activity_epoch(meta),
    }
  end

  if count > REFRESH_META_MAX_HOSTS then
    local overflow = count - REFRESH_META_MAX_HOSTS
    table.sort(entries, function(a, b)
      if a.priority ~= b.priority then
        return a.priority < b.priority
      end
      if a.activity ~= b.activity then
        return a.activity < b.activity
      end
      return a.host < b.host
    end)

    for i = 1, overflow do
      local victim = entries[i]
      if victim and state.refreshMeta[victim.host] ~= nil then
        state.refreshMeta[victim.host] = nil
        removed = removed + 1
      end
    end
  end

  if removed > 0 then
    refresh_state_mutated = true
  end
  return removed
end

local function maybe_persist_state(force)
  local now_epoch = os.time()
  local min_interval = math.max(0, RESOLVER_PERSIST_MIN_INTERVAL_SEC)
  if force or min_interval == 0 or (now_epoch - last_persist_epoch) >= min_interval then
    persist.save("resolver_state", state)
    last_persist_epoch = now_epoch
  end
end

local function build_proof_payload(host)
  local proof = state.dnsProofState[host]
  if not proof then
    return {
      dnsProofState = "unchecked",
      dnsProofCheckedAt = nil,
      dnsProofValidUntil = nil,
      source = "resolver-cache",
    }
  end
  return {
    dnsProofState = proof.state or "unchecked",
    dnsProofCheckedAt = proof.checkedAt,
    dnsProofValidUntil = proof.validUntil,
    source = proof.source or "resolver-cache",
    challengeRef = proof.challengeRef,
    dnsProofSeq = proof.sequence,
  }
end

local function evaluate_dns_proof_decision(mode, host_known, proof_state)
  local decision = "allow"
  local reason

  if not host_known then
    return decision, nil
  end

  if proof_state == "valid" then
    return decision, "ALLOW_DNS_PROOF_VALID"
  end

  if proof_state == "expired" then
    if mode == "off" then
      return decision, "ALLOW_DNS_PROOF_EXPIRED_MODE_OFF"
    end
    if mode == "observe" then
      return decision, "ALLOW_DNS_PROOF_EXPIRED_MODE_OBSERVE"
    end
    reason = "DENY_READY_DNS_PROOF_EXPIRED"
  elseif proof_state == "missing" then
    if mode == "off" then
      return decision, "ALLOW_DNS_PROOF_MISSING_MODE_OFF"
    end
    if mode == "observe" then
      return decision, "ALLOW_DNS_PROOF_MISSING_MODE_OBSERVE"
    end
    reason = "DENY_READY_DNS_PROOF_MISSING"
  elseif proof_state == "unchecked" then
    if mode == "off" then
      return decision, "ALLOW_DNS_PROOF_UNCHECKED_MODE_OFF"
    end
    if mode == "observe" then
      return decision, "ALLOW_DNS_PROOF_UNCHECKED_MODE_OBSERVE"
    end
    reason = "DENY_READY_DNS_PROOF_UNCHECKED"
  else
    return decision, nil
  end

  if state.failOpen == false then
    decision = "deny"
  end
  return decision, reason
end

local function evaluate_route_decision(mode, host_known, proof_state)
  if not host_known then
    if mode == "off" then
      return "allow", "ALLOW_ROUTE_HOST_UNMAPPED_MODE_OFF"
    end
    if mode == "observe" then
      return "allow", "ALLOW_ROUTE_HOST_UNMAPPED_MODE_OBSERVE"
    end
    if state.failOpen == false then
      return "deny", "DENY_READY_ROUTE_HOST_UNMAPPED"
    end
    return "allow", "DENY_READY_ROUTE_HOST_UNMAPPED"
  end

  local decision, reason = evaluate_dns_proof_decision(mode, true, proof_state)
  if reason then
    return decision, reason
  end
  return "allow", "ALLOW_ROUTE_HOST_BOUND"
end

local function evaluate_host_decision(mode, host_known, proof_state)
  if not host_known then
    if mode == "off" then
      return "allow", "ALLOW_HOST_UNMAPPED_MODE_OFF"
    end
    if mode == "observe" then
      return "allow", "ALLOW_HOST_UNMAPPED_MODE_OBSERVE"
    end
    if state.failOpen == false then
      return "deny", "DENY_READY_HOST_UNMAPPED"
    end
    return "allow", "DENY_READY_HOST_UNMAPPED"
  end

  local decision, reason = evaluate_dns_proof_decision(mode, true, proof_state)
  if reason then
    return decision, reason
  end
  return "allow", "ALLOW_HOST_BOUND"
end

local function starts_with(text, prefix)
  return text:sub(1, #prefix) == prefix
end

local function infer_action_hint(path, method)
  if method == "GET" or method == "HEAD" then
    if starts_with(path, "/~process@1.0/")
      or starts_with(path, "/~scheduler@1.0/")
      or starts_with(path, "/~meta@1.0/")
      or starts_with(path, "/~relay@1.0/")
    then
      return "control_plane"
    end
    return "read"
  end
  if method == "OPTIONS" then
    return "preflight"
  end
  return "write"
end

local function resolve_action_hint(host, path, method, host_policy)
  local hint_source = "inferred"
  local site_id = host_policy and host_policy.siteId or nil
  local site_policy = site_id and state.sitePolicies[site_id] or nil
  local route_policy = state.routePolicies[host]

  if route_policy and type(route_policy.rules) == "table" then
    for _, rule in ipairs(route_policy.rules) do
      if starts_with(path, rule.pathPrefix) then
        local methods = rule.methods
        if methods == nil or methods[method] then
          return rule.actionHint or infer_action_hint(path, method), "route_policy_rule"
        end
      end
    end
    if route_policy.defaultActionHint then
      return route_policy.defaultActionHint, "route_policy_default"
    end
  end

  if host_policy and host_policy.actionHint then
    return tostring(host_policy.actionHint), "host_policy"
  end
  if site_policy and site_policy.defaultActionHint then
    return tostring(site_policy.defaultActionHint), "site_policy"
  end
  return infer_action_hint(path, method), hint_source
end

local function deny_ready(reason_code)
  return type(reason_code) == "string" and reason_code:match("^DENY_READY_") ~= nil
end

local function with_result_envelope(payload)
  payload.result = {
    decision = payload.decision,
    reasonCode = payload.reasonCode,
    status = payload.decision == "deny" and "DENY" or "ALLOW",
  }
  payload.reason = payload.reasonCode
  payload.policy = {
    mode = payload.mode,
    failOpen = state.failOpen ~= false,
    enforceMode = payload.mode == "enforce",
    denyReady = deny_ready(payload.reasonCode),
  }
  return payload
end

local function payload_from_cached_entry(entry, request_id, node_id, cache_state, refresh_payload)
  local proof_payload = entry.proof
    or {
      dnsProofState = entry.proofState or "unchecked",
      dnsProofCheckedAt = nil,
      dnsProofValidUntil = nil,
      source = "resolver-cache",
    }
  local cache_window = {
    expiresAtEpoch = entry.expiresAtEpoch,
    staleUntilEpoch = entry.staleUntilEpoch,
    hardExpireEpoch = entry.hardExpireEpoch,
  }
  local payload = {
    schemaVersion = "1.0",
    requestId = request_id,
    decision = entry.decision,
    reasonCode = entry.reasonCode,
    mode = entry.mode,
    host = entry.host,
    nodeId = node_id,
    cache = build_cache_payload(entry.hostKnown == true, proof_payload, entry.surface, cache_state, cache_window),
    proof = proof_payload,
  }
  if entry.path then
    payload.path = entry.path
  end
  if entry.method then
    payload.method = entry.method
  end
  if entry.site then
    payload.site = entry.site
  elseif entry.siteId then
    payload.site = { siteId = entry.siteId, host = entry.host, status = "unknown" }
  end
  if entry.process then
    payload.process = entry.process
  end
  if entry.actionHint ~= nil then
    payload.routeHint = {
      source = "cache",
    }
    payload.routeHint.actionHint = entry.actionHint
    if entry.executionFlow ~= nil then
      payload.routeHint.executionFlow = entry.executionFlow
    end
  elseif entry.executionFlow ~= nil and entry.surface == "route" then
    payload.routeHint = {
      source = "cache",
      executionFlow = entry.executionFlow,
    }
  elseif entry.executionFlow ~= nil then
    payload.executionFlow = entry.executionFlow
  end
  if refresh_payload ~= nil then
    payload.refresh = refresh_payload
  end
  return with_result_envelope(payload)
end

local function parse_int_field(raw_value, field_name, min_value, max_value)
  local value = tonumber(raw_value)
  if not value or value % 1 ~= 0 then
    return nil, ("invalid_number:%s"):format(field_name)
  end
  if value < min_value or value > max_value then
    return nil, ("invalid_range:%s"):format(field_name)
  end
  return value, nil
end

local function build_refresh_meta(host, now_epoch)
  local meta = state.refreshMeta[host]
  local proof = state.dnsProofState[host]
  local next_check_epoch = nil

  if meta and type(meta.nextCheckAt) == "string" then
    next_check_epoch = iso_to_epoch(meta.nextCheckAt)
  end
  if next_check_epoch == nil and proof and type(proof.validUntil) == "string" then
    next_check_epoch = iso_to_epoch(proof.validUntil)
  end
  if next_check_epoch == nil then
    next_check_epoch = now_epoch
  end

  return {
    host = host,
    dnsProofState = proof and proof.state or "unchecked",
    lastCheckAt = meta and meta.lastCheckAt or nil,
    nextCheckAt = epoch_to_iso(next_check_epoch),
    nextCheckEpoch = next_check_epoch,
    retryCount = meta and tonumber(meta.retryCount or 0) or 0,
    lastError = meta and meta.lastError or nil,
    refreshRequestedAt = meta and meta.refreshRequestedAt or nil,
    lastRequestedReason = meta and meta.lastRequestedReason or nil,
    requestCount = meta and tonumber(meta.requestCount or 0) or 0,
    pendingChallenge = meta and meta.pendingChallenge or nil,
    challengeExpiresAt = meta and meta.challengeExpiresAt or nil,
  }
end

local function refresh_paths_snapshot()
  return {
    relayPath = state.autoDns.relayPath,
    cachePath = state.autoDns.cachePath,
    cronPath = state.autoDns.cronPath,
  }
end

local function refresh_endpoints_snapshot()
  return {
    dohEndpoint = state.autoDns.dohEndpoint,
    arweaveBase = state.autoDns.arweaveBase,
  }
end

local function execution_flow_snapshot()
  return {
    mode = state.executionFlow.mode,
    preflightSchedule = state.executionFlow.preflightSchedule ~= false,
    requireNumericSlot = state.executionFlow.requireNumericSlot ~= false,
    singleFlightPerProcess = state.executionFlow.singleFlightPerProcess ~= false,
    maxAttempts = tonumber(state.executionFlow.maxAttempts) or 5,
    baseBackoffMs = tonumber(state.executionFlow.baseBackoffMs) or 300,
    maxBackoffMs = tonumber(state.executionFlow.maxBackoffMs) or 1000,
  }
end

local function build_execution_flow_hint(process_obj)
  local snapshot = execution_flow_snapshot()
  local hint = {
    mode = snapshot.mode,
    preflightSchedule = snapshot.preflightSchedule,
    requireNumericSlot = snapshot.requireNumericSlot,
    singleFlightPerProcess = snapshot.singleFlightPerProcess,
    strategy = "slot_pinned_scheduler_preflight",
    retry = {
      maxAttempts = snapshot.maxAttempts,
      baseBackoffMs = snapshot.baseBackoffMs,
      maxBackoffMs = snapshot.maxBackoffMs,
    },
    templates = {
      schedulerPreflight = "/~scheduler@1.0/schedule?target=<PROCESS_ID>",
      slotPinnedCompute = "/~process@1.0/compute?target=<PROCESS_ID>&slot=<SLOT>",
      slotPinnedRead = "/~process@1.0/read?target=<PROCESS_ID>&slot=<SLOT>",
    },
  }
  if type(process_obj) == "table" then
    if type(process_obj.processId) == "string" and process_obj.processId ~= "" then
      hint.targetProcessId = process_obj.processId
    end
    if type(process_obj.scheduler) == "string" and process_obj.scheduler ~= "" then
      hint.scheduler = process_obj.scheduler
    end
  end
  return hint
end

local function list_tracked_hosts()
  local tracked = {}
  for host, _ in pairs(state.hostPolicies or {}) do
    tracked[host] = true
  end
  for host, _ in pairs(state.refreshMeta or {}) do
    tracked[host] = true
  end
  return tracked
end

local function evaluate_admission(host)
  if type(host) ~= "string" or host == "" then
    return "deny", "DENY_ADMISSION_INVALID_HOST"
  end
  local admission = state.admission or {}
  local deny_hosts = admission.denyHosts or {}
  local deny_entry = deny_hosts[host]
  if deny_entry ~= nil then
    local reason = type(deny_entry) == "table" and deny_entry.reason or nil
    return "deny", reason or "DENY_ADMISSION_BLOCKLIST"
  end
  if admission.allowlistEnabled == true then
    local allow_hosts = admission.allowHosts or {}
    if allow_hosts[host] == nil then
      return "deny", "DENY_ADMISSION_ALLOWLIST_MISS"
    end
  end
  return "allow", "ALLOW_ADMISSION_OK"
end

local function normalize_challenge_ref(raw_value, field_name)
  if raw_value == nil then
    return nil
  end
  if type(raw_value) ~= "string" then
    return nil, ("invalid_type:%s"):format(field_name)
  end
  local value = trim(raw_value) or ""
  if value == "" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  local ok_len, err_len = validation.check_length(value, 256, field_name)
  if not ok_len then
    return nil, err_len
  end
  if not value:match "^[A-Za-z0-9%._:%-]+$" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  return value
end

local challenge_nonce_counter = 0

local function bytes_to_hex(bytes)
  if type(bytes) ~= "string" then
    return nil
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function secure_nonce_hex(byte_len)
  local n = tonumber(byte_len) or 16
  if n < 8 then
    n = 8
  end
  if n > 64 then
    n = 64
  end

  if openssl_ok and openssl and openssl.rand and type(openssl.rand.bytes) == "function" then
    local ok_rand, raw = pcall(openssl.rand.bytes, n)
    if ok_rand and type(raw) == "string" and #raw > 0 then
      return bytes_to_hex(raw)
    end
  end

  challenge_nonce_counter = challenge_nonce_counter + 1
  local fallback =
    string.format("%x%x%x", os.time(), challenge_nonce_counter, math.floor((os.clock() or 0) * 1000000000))
  fallback = fallback:gsub("[^a-f0-9]", "")
  if fallback == "" then
    fallback = tostring(os.time()) .. tostring(challenge_nonce_counter)
  end
  return fallback
end

local function mint_challenge_ref(host, reason, now_epoch)
  local host_token = (host or "host"):gsub("[^a-z0-9]+", "-")
  if host_token == "" then
    host_token = "host"
  end
  host_token = host_token:sub(1, 48)
  local reason_token = (reason or "refresh"):gsub("[^a-z0-9]+", "-")
  if reason_token == "" then
    reason_token = "refresh"
  end
  reason_token = reason_token:sub(1, 32)
  local nonce = secure_nonce_hex(16) or tostring(now_epoch or os.time())
  return string.format("dm1:%s:%s:%s", host_token, reason_token, nonce)
end

local function issue_refresh_challenge(host, reason, ttl_sec, explicit_challenge_ref)
  local now_epoch = os.time()
  local now_iso_value = epoch_to_iso(now_epoch)
  local ttl = tonumber(ttl_sec) or tonumber(state.autoDns.challengeTtlSec) or 300
  if ttl < 30 then
    ttl = 30
  end
  if ttl > 7200 then
    ttl = 7200
  end
  local challenge_ref = explicit_challenge_ref or mint_challenge_ref(host, reason, now_epoch)
  local expires_at = epoch_to_iso(now_epoch + ttl)
  local meta = state.refreshMeta[host] or {}
  meta.pendingChallenge = challenge_ref
  meta.challengeIssuedAt = now_iso_value
  meta.challengeExpiresAt = expires_at
  meta.lastRequestedReason = reason or meta.lastRequestedReason
  state.refreshMeta[host] = meta
  refresh_state_mutated = true
  return challenge_ref, expires_at, ttl
end

local function validate_refresh_challenge(host, challenge_ref, now_epoch)
  if state.autoDns.requireChallenge ~= true then
    return true
  end
  if challenge_ref == nil or challenge_ref == "" then
    return false, "missing_field:Challenge-Ref"
  end
  local meta = state.refreshMeta[host]
  local expected = meta and meta.pendingChallenge
  if type(expected) ~= "string" or expected == "" then
    return false, "challenge_not_issued"
  end
  if expected ~= challenge_ref then
    return false, "challenge_mismatch"
  end
  local expires_epoch = iso_to_epoch(meta and meta.challengeExpiresAt)
  if expires_epoch ~= nil and expires_epoch < (now_epoch or os.time()) then
    return false, "challenge_expired"
  end
  return true
end

local function clear_refresh_challenge(host)
  local meta = state.refreshMeta[host]
  if not meta then
    return
  end
  meta.pendingChallenge = nil
  meta.challengeIssuedAt = nil
  meta.challengeExpiresAt = nil
  state.refreshMeta[host] = meta
end

local function maybe_queue_refresh_from_access(host, proof_payload, host_known, cache_state)
  if state.autoDns.enabled ~= true then
    return nil
  end

  local reason = nil
  if host_known ~= true then
    reason = "host_unmapped"
  end
  if cache_state == "stale" and state.autoDns.refreshOnStale == true then
    reason = "cache_stale"
  elseif reason == nil then
    local proof_state = proof_payload and proof_payload.dnsProofState or "unchecked"
    if proof_state ~= "valid" then
      reason = "proof_" .. proof_state
    else
      local valid_until_epoch = iso_to_epoch(proof_payload and proof_payload.dnsProofValidUntil)
      if valid_until_epoch and valid_until_epoch <= os.time() then
        reason = "proof_due"
      end
    end
  end

  if reason == nil then
    return nil
  end

  local now_epoch = os.time()
  local now_iso_value = epoch_to_iso(now_epoch)
  local min_interval = state.autoDns.staleRefreshMinIntervalSec or 0
  local meta = state.refreshMeta[host] or {}
  local effective_next = meta.nextCheckAt

  if not request_allows_refresh_queue_mutation then
    return {
      enabled = true,
      requested = false,
      reason = reason,
      source = "read_only",
      nextCheckAt = effective_next,
      refreshRequestedAt = meta.refreshRequestedAt,
      retryCount = tonumber(meta.retryCount) or 0,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeRef = meta.pendingChallenge,
      challengeExpiresAt = meta.challengeExpiresAt,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    }
  end

  local last_requested_epoch = iso_to_epoch(meta.refreshRequestedAt)
  local should_request = last_requested_epoch == nil or (now_epoch - last_requested_epoch) >= min_interval

  if should_request then
    meta.refreshRequestedAt = now_iso_value
    meta.lastRequestedReason = reason
    meta.requestCount = (tonumber(meta.requestCount) or 0) + 1
    local next_check_epoch = iso_to_epoch(meta.nextCheckAt)
    if next_check_epoch == nil or next_check_epoch > now_epoch then
      meta.nextCheckAt = now_iso_value
    end
    state.refreshMeta[host] = meta
    refresh_state_mutated = true
    if state.autoDns.requireChallenge == true then
      local issued_ref, issued_expires_at =
        issue_refresh_challenge(host, reason, state.autoDns.challengeTtlSec)
      meta = state.refreshMeta[host] or meta
      meta.pendingChallenge = issued_ref
      meta.challengeExpiresAt = issued_expires_at
      state.refreshMeta[host] = meta
    end
  end

  if effective_next == nil then
    effective_next = plus_seconds_iso(state.autoDns.refreshIntervalSec)
    state.refreshMeta[host] = meta
    state.refreshMeta[host].nextCheckAt = effective_next
    refresh_state_mutated = true
  end

  return {
    enabled = true,
    requested = should_request,
    reason = reason,
    source = should_request and "on_access" or "cooldown",
    nextCheckAt = effective_next,
    refreshRequestedAt = meta.refreshRequestedAt,
    retryCount = tonumber(meta.retryCount) or 0,
    staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
    requireChallenge = state.autoDns.requireChallenge == true,
    challengeRef = meta.pendingChallenge,
    challengeExpiresAt = meta.challengeExpiresAt,
    paths = refresh_paths_snapshot(),
    endpoints = refresh_endpoints_snapshot(),
  }
end

function handlers.ApplyPolicyBundle(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Bundle",
    "bundle",
    "Policy-Mode",
    "PolicyMode",
    "Fail-Open",
    "FailOpen",
    "Cache-Hints",
    "CacheHints",
    "Execution-Flow",
    "ExecutionFlow",
    "Auto-Dns",
    "AutoDns",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local bundle = msg.Bundle or msg.bundle
  if bundle ~= nil and type(bundle) ~= "table" then
    return codec.error("INVALID_INPUT", "Bundle must be an object", { field = "Bundle" })
  end
  bundle = bundle or {}

  local mode_source = bundle.policyMode or bundle.mode or msg["Policy-Mode"] or msg.PolicyMode
  local mode, mode_fallback_reason = normalize_mode(mode_source)
  if mode_fallback_reason and mode_source ~= nil then
    return codec.error("INVALID_INPUT", "Invalid policy mode", { field = "Policy-Mode" })
  end

  local fail_open_source = bundle.failOpen
  if fail_open_source == nil then
    fail_open_source = msg["Fail-Open"] or msg.FailOpen
  end
  local fail_open, fail_open_err = parse_fail_open(fail_open_source, state.failOpen ~= false)
  if fail_open == nil then
    return codec.error("INVALID_INPUT", fail_open_err, { field = "Fail-Open" })
  end

  local cache_hints_source = bundle.cacheHints or msg["Cache-Hints"] or msg.CacheHints
  local cache_hints_update, cache_err = normalize_cache_hints(cache_hints_source)
  if cache_err then
    return codec.error("INVALID_INPUT", cache_err, { field = "Cache-Hints" })
  end

  local execution_flow_source = bundle.executionFlow or bundle["Execution-Flow"] or msg["Execution-Flow"] or msg.ExecutionFlow
  local execution_flow_update, execution_flow_err = normalize_execution_flow(execution_flow_source)
  if execution_flow_err then
    return codec.error("INVALID_INPUT", execution_flow_err, { field = "Execution-Flow" })
  end

  local auto_dns_source = bundle.autoDns or msg["Auto-Dns"] or msg.AutoDns
  local auto_dns_update, auto_dns_err = normalize_auto_dns(auto_dns_source)
  if auto_dns_err then
    return codec.error("INVALID_INPUT", auto_dns_err, { field = "Auto-Dns" })
  end

  local host_input = bundle.hostPolicies or bundle.hosts or msg["Host-Policies"] or msg.HostPolicies
  local site_input = bundle.sitePolicies or bundle.sites or msg["Site-Policies"] or msg.SitePolicies
  local route_input = bundle.routePolicies or bundle.routes or msg["Route-Policies"] or msg.RoutePolicies
  local dns_input = bundle.dnsProofState or bundle.dnsProof or msg["DNS-Proof-State"] or msg.DnsProofState

  local normalized_hosts, hosts_err = normalize_host_policies(host_input)
  if hosts_err then
    return codec.error("INVALID_INPUT", hosts_err, { field = "hostPolicies" })
  end
  local normalized_sites, sites_err = normalize_site_policies(site_input)
  if sites_err then
    return codec.error("INVALID_INPUT", sites_err, { field = "sitePolicies" })
  end
  local normalized_dns, dns_err = normalize_dns_proof_state(dns_input)
  if dns_err then
    return codec.error("INVALID_INPUT", dns_err, { field = "dnsProofState" })
  end
  local normalized_routes, routes_err = normalize_route_policies(route_input)
  if routes_err then
    return codec.error("INVALID_INPUT", routes_err, { field = "routePolicies" })
  end

  if not ALLOW_CENTRALIZED_BUNDLE_WRITES then
    local blocked_fields = {}
    if normalized_hosts ~= nil then
      table.insert(blocked_fields, "hostPolicies")
    end
    if normalized_sites ~= nil then
      table.insert(blocked_fields, "sitePolicies")
    end
    if normalized_routes ~= nil then
      table.insert(blocked_fields, "routePolicies")
    end
    if normalized_dns ~= nil then
      table.insert(blocked_fields, "dnsProofState")
    end

    if #blocked_fields > 0 then
      return codec.error(
        "FORBIDDEN",
        "centralized_bundle_writes_disabled",
        {
          fields = blocked_fields,
          hint = "Use DNS TXT + AR config + proof refresh flow (or set RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=1).",
        }
      )
    end
  end

  local candidate_hosts = normalized_hosts or state.hostPolicies
  local candidate_sites = normalized_sites or state.sitePolicies
  local graph_ok, graph_err = validate_policy_graph(candidate_hosts, candidate_sites)
  if not graph_ok then
    return codec.error("INVALID_INPUT", graph_err, { field = "hostPolicies" })
  end

  if normalized_hosts ~= nil then
    state.hostPolicies = normalized_hosts
  end
  if normalized_sites ~= nil then
    state.sitePolicies = normalized_sites
  end
  if normalized_routes ~= nil then
    state.routePolicies = normalized_routes
  end
  if normalized_dns ~= nil then
    state.dnsProofState = normalized_dns
  end

  state.policyMode = mode
  state.failOpen = fail_open
  ensure_cache_hints()
  local next_cache_hints = {
    positiveTtlSec = state.cacheHints.positiveTtlSec,
    negativeTtlSec = state.cacheHints.negativeTtlSec,
    staleWhileRevalidateSec = state.cacheHints.staleWhileRevalidateSec,
    hardMaxStaleSec = state.cacheHints.hardMaxStaleSec,
  }
  if cache_hints_update then
    for key, value in pairs(cache_hints_update) do
      next_cache_hints[key] = value
    end
  end
  if next_cache_hints.hardMaxStaleSec < next_cache_hints.staleWhileRevalidateSec then
    return codec.error("INVALID_INPUT", "invalid_relation:hardMaxStaleSec", { field = "Cache-Hints" })
  end
  state.cacheHints = next_cache_hints
  local next_execution_flow = execution_flow_snapshot()
  if execution_flow_update then
    for key, value in pairs(execution_flow_update) do
      next_execution_flow[key] = value
    end
  end
  if next_execution_flow.maxBackoffMs < next_execution_flow.baseBackoffMs then
    return codec.error("INVALID_INPUT", "invalid_relation:Execution-Flow.maxBackoffMs", { field = "Execution-Flow" })
  end
  state.executionFlow = next_execution_flow
  if auto_dns_update then
    local next_auto_dns = {}
    for key, value in pairs(state.autoDns) do
      next_auto_dns[key] = value
    end
    for key, value in pairs(auto_dns_update) do
      next_auto_dns[key] = value
    end
    state.autoDns = next_auto_dns
  end

  local snapshot_id = bundle.snapshotId or msg["Snapshot-Id"] or msg.SnapshotId
  local version = bundle.version or msg.Version
  local generated_at = bundle.generatedAt or msg["Generated-At"] or msg.GeneratedAt

  state.bundleMeta = state.bundleMeta or {}
  state.bundleMeta.snapshotId = snapshot_id or state.bundleMeta.snapshotId
  state.bundleMeta.version = version or state.bundleMeta.version
  state.bundleMeta.generatedAt = generated_at or state.bundleMeta.generatedAt
  state.bundleMeta.appliedAt = now_iso()
  local purged_entries = invalidate_cache_all()
  state.cacheMeta.lastInvalidatedAt = state.bundleMeta.appliedAt

  return codec.ok {
    schemaVersion = "1.0",
    applied = true,
    appliedAt = state.bundleMeta.appliedAt,
    policyMode = state.policyMode,
    failOpen = state.failOpen,
    bundleMeta = state.bundleMeta,
    cacheInvalidation = {
      scope = "all",
      purgedEntries = purged_entries,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
    counts = {
      hostPolicies = map_count(state.hostPolicies),
      sitePolicies = map_count(state.sitePolicies),
      routePolicies = map_count(state.routePolicies),
      dnsProofState = map_count(state.dnsProofState),
    },
    cacheHints = {
      positiveTtlSec = state.cacheHints.positiveTtlSec,
      negativeTtlSec = state.cacheHints.negativeTtlSec,
      staleWhileRevalidateSec = state.cacheHints.staleWhileRevalidateSec,
      hardMaxStaleSec = state.cacheHints.hardMaxStaleSec,
    },
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
    executionFlow = execution_flow_snapshot(),
  }
end

function handlers.InvalidateResolverCache(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Scope",
    "Host",
    "Site-Id",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local scope = string.lower(tostring(msg.Scope or "all"))
  local removed = 0
  local target = nil

  if scope == "all" then
    removed = invalidate_cache_all()
  elseif scope == "host" then
    local ok_fields, missing = validation.require_fields(msg, { "Host" })
    if not ok_fields then
      return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
    end
    local host, host_err = normalize_host(msg.Host, "Host")
    if not host then
      return codec.error("INVALID_INPUT", host_err, { field = "Host" })
    end
    target = host
    removed = invalidate_cache_by_host(host)
  elseif scope == "site" then
    local ok_fields, missing = validation.require_fields(msg, { "Site-Id" })
    if not ok_fields then
      return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
    end
    local site_id, site_err = normalize_site_id(msg["Site-Id"], "Site-Id")
    if not site_id then
      return codec.error("INVALID_INPUT", site_err, { field = "Site-Id" })
    end
    target = site_id
    removed = invalidate_cache_by_site(site_id)
  else
    return codec.error("INVALID_INPUT", "Invalid scope", { field = "Scope", allowed = { "all", "host", "site" } })
  end

  state.cacheMeta.lastInvalidatedAt = now_iso()

  return codec.ok {
    schemaVersion = "1.0",
    invalidated = true,
    scope = scope,
    target = target,
    removedEntries = removed,
    remainingEntries = map_count(state.resolutionCache),
    lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
  }
end

function handlers.GetResolverCacheStats(_msg)
  local mapped = 0
  local unmapped = 0
  local by_proof = {
    valid = 0,
    expired = 0,
    missing = 0,
    unchecked = 0,
    other = 0,
  }
  for _, entry in pairs(state.resolutionCache) do
    if entry and entry.siteId and entry.siteId ~= "" then
      mapped = mapped + 1
    else
      unmapped = unmapped + 1
    end
    local proof_state = (entry and entry.proofState) or "unchecked"
    if by_proof[proof_state] ~= nil then
      by_proof[proof_state] = by_proof[proof_state] + 1
    else
      by_proof.other = by_proof.other + 1
    end
  end

  return codec.ok {
    schemaVersion = "1.0",
    counts = {
      entriesTotal = map_count(state.resolutionCache),
      mappedHosts = mapped,
      unmappedHosts = unmapped,
    },
    byProofState = by_proof,
    lastAppliedAt = state.bundleMeta and state.bundleMeta.appliedAt or nil,
    lastResolvedAt = state.lastResolvedAt,
    lastInvalidatedAt = state.cacheMeta and state.cacheMeta.lastInvalidatedAt or nil,
  }
end

function handlers.GetDnsRefreshState(_msg)
  local now_epoch = os.time()
  local tracked_hosts = 0
  local due_now = 0
  local with_errors = 0
  local with_pending_request = 0
  local with_pending_challenge = 0

  for host, _ in pairs(list_tracked_hosts()) do
    tracked_hosts = tracked_hosts + 1
    local meta = build_refresh_meta(host, now_epoch)
    if meta.nextCheckEpoch <= now_epoch then
      due_now = due_now + 1
    end
    if meta.lastError ~= nil and meta.lastError ~= "" then
      with_errors = with_errors + 1
    end
    if meta.refreshRequestedAt ~= nil then
      with_pending_request = with_pending_request + 1
    end
    if meta.pendingChallenge ~= nil and meta.pendingChallenge ~= "" then
      with_pending_challenge = with_pending_challenge + 1
    end
  end

  return codec.ok {
    schemaVersion = "1.0",
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
    counts = {
      trackedHosts = tracked_hosts,
      dueNow = due_now,
      withErrors = with_errors,
      withPendingRequest = with_pending_request,
      withPendingChallenge = with_pending_challenge,
    },
    generatedAt = now_iso(),
  }
end

function handlers.ListHostsDueForDnsRefresh(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Limit",
    "Now-Epoch",
    "NowEpoch",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local now_epoch = os.time()
  local now_override = msg["Now-Epoch"] or msg.NowEpoch
  if now_override ~= nil then
    local parsed_now, parsed_now_err = parse_int_field(now_override, "Now-Epoch", 0, 4102444800)
    if parsed_now_err then
      return codec.error("INVALID_INPUT", parsed_now_err, { field = "Now-Epoch" })
    end
    now_epoch = parsed_now
  end

  local limit = state.autoDns.maxHostsPerRun
  local limit_raw = msg.Limit
  if limit_raw ~= nil then
    local parsed_limit, parsed_limit_err = parse_int_field(limit_raw, "Limit", 1, 500)
    if parsed_limit_err then
      return codec.error("INVALID_INPUT", parsed_limit_err, { field = "Limit" })
    end
    limit = parsed_limit
  end

  local due = {}
  local tracked_hosts = 0
  for host, _ in pairs(list_tracked_hosts()) do
    tracked_hosts = tracked_hosts + 1
    local host_policy = state.hostPolicies[host]
    local meta = build_refresh_meta(host, now_epoch)
    if meta.nextCheckEpoch <= now_epoch then
      table.insert(due, {
        host = host,
        siteId = host_policy and host_policy.siteId or nil,
        dnsProofState = meta.dnsProofState,
        nextCheckAt = meta.nextCheckAt,
        lastCheckAt = meta.lastCheckAt,
        retryCount = meta.retryCount,
        lastError = meta.lastError,
        refreshRequestedAt = meta.refreshRequestedAt,
        lastRequestedReason = meta.lastRequestedReason,
        requestCount = meta.requestCount,
        challengeRef = meta.pendingChallenge,
        challengeExpiresAt = meta.challengeExpiresAt,
      })
    end
  end

  table.sort(due, function(a, b)
    local left_epoch = iso_to_epoch(a.nextCheckAt) or 0
    local right_epoch = iso_to_epoch(b.nextCheckAt) or 0
    if left_epoch == right_epoch then
      return (a.host or "") < (b.host or "")
    end
    return left_epoch < right_epoch
  end)

  if #due > limit then
    local limited = {}
    for i = 1, limit do
      limited[i] = due[i]
    end
    due = limited
  end

  return codec.ok {
    schemaVersion = "1.0",
    generatedAt = now_iso(),
    nowEpoch = now_epoch,
    limit = limit,
    counts = {
      trackedHosts = tracked_hosts,
      returned = #due,
    },
    dueHosts = due,
  }
end

function handlers.RunAutoDnsTick(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Limit",
    "Now-Epoch",
    "NowEpoch",
    "Reason",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local now_epoch = os.time()
  local now_override = msg["Now-Epoch"] or msg.NowEpoch
  if now_override ~= nil then
    local parsed_now, parsed_now_err = parse_int_field(now_override, "Now-Epoch", 0, 4102444800)
    if parsed_now_err then
      return codec.error("INVALID_INPUT", parsed_now_err, { field = "Now-Epoch" })
    end
    now_epoch = parsed_now
  end

  local reason = trim(tostring(msg.Reason or "cron_tick")) or "cron_tick"
  local ok_reason_len, reason_len_err = validation.check_length(reason, 128, "Reason")
  if not ok_reason_len or reason == "" then
    return codec.error("INVALID_INPUT", reason_len_err or "invalid_format:Reason", { field = "Reason" })
  end

  local limit = state.autoDns.maxHostsPerRun
  local limit_raw = msg.Limit
  if limit_raw ~= nil then
    local parsed_limit, parsed_limit_err = parse_int_field(limit_raw, "Limit", 1, 500)
    if parsed_limit_err then
      return codec.error("INVALID_INPUT", parsed_limit_err, { field = "Limit" })
    end
    limit = parsed_limit
  end

  local due = {}
  local tracked_hosts = 0
  local due_now = 0
  local queued_now = 0
  local now_iso_value = epoch_to_iso(now_epoch)
  local min_interval = state.autoDns.staleRefreshMinIntervalSec or 0

  for host, _ in pairs(list_tracked_hosts()) do
    tracked_hosts = tracked_hosts + 1
    local host_policy = state.hostPolicies[host]
    local meta = build_refresh_meta(host, now_epoch)
    if meta.nextCheckEpoch <= now_epoch then
      due_now = due_now + 1
      local queued = false
      if state.autoDns.enabled == true then
        local requested_at_epoch = iso_to_epoch(meta.refreshRequestedAt)
        local can_queue = requested_at_epoch == nil or (now_epoch - requested_at_epoch) >= min_interval
        if can_queue then
          local current_meta = state.refreshMeta[host] or {}
          current_meta.refreshRequestedAt = now_iso_value
          current_meta.lastRequestedReason = reason
          current_meta.requestCount = (tonumber(current_meta.requestCount) or 0) + 1
          local current_next_epoch = iso_to_epoch(current_meta.nextCheckAt)
          if current_next_epoch == nil or current_next_epoch > now_epoch then
            current_meta.nextCheckAt = now_iso_value
          end
          state.refreshMeta[host] = current_meta
          if state.autoDns.requireChallenge == true then
            local issued_ref, issued_expires_at =
              issue_refresh_challenge(host, reason, state.autoDns.challengeTtlSec)
            current_meta = state.refreshMeta[host] or current_meta
            current_meta.pendingChallenge = issued_ref
            current_meta.challengeExpiresAt = issued_expires_at
            state.refreshMeta[host] = current_meta
          end
          queued = true
          queued_now = queued_now + 1
        end
      end
      table.insert(due, {
        host = host,
        siteId = host_policy and host_policy.siteId or nil,
        dnsProofState = meta.dnsProofState,
        nextCheckAt = meta.nextCheckAt,
        lastCheckAt = meta.lastCheckAt,
        retryCount = meta.retryCount,
        lastError = meta.lastError,
        refreshRequestedAt = state.refreshMeta[host] and state.refreshMeta[host].refreshRequestedAt or meta.refreshRequestedAt,
        lastRequestedReason = state.refreshMeta[host] and state.refreshMeta[host].lastRequestedReason or meta.lastRequestedReason,
        requestCount = state.refreshMeta[host] and tonumber(state.refreshMeta[host].requestCount or 0) or meta.requestCount,
        challengeRef = state.refreshMeta[host] and state.refreshMeta[host].pendingChallenge or meta.pendingChallenge,
        challengeExpiresAt = state.refreshMeta[host] and state.refreshMeta[host].challengeExpiresAt
          or meta.challengeExpiresAt,
        queued = queued,
      })
    end
  end

  table.sort(due, function(a, b)
    local left_epoch = iso_to_epoch(a.nextCheckAt) or 0
    local right_epoch = iso_to_epoch(b.nextCheckAt) or 0
    if left_epoch == right_epoch then
      return (a.host or "") < (b.host or "")
    end
    return left_epoch < right_epoch
  end)

  if #due > limit then
    local limited = {}
    for i = 1, limit do
      limited[i] = due[i]
    end
    due = limited
  end

  return codec.ok {
    schemaVersion = "1.0",
    generatedAt = now_iso(),
    nowEpoch = now_epoch,
    runReason = reason,
    limit = limit,
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
    relayPlan = {
      mode = "hb_native",
      fetchOrder = { "cache", "relay" },
      txtRecordTemplate = "_darkmesh.%s",
      expectedTxtVersion = "dm1",
      applyAction = "ApplyDnsRefreshResult",
      challenge = {
        required = state.autoDns.requireChallenge == true,
        issueAction = "IssueDnsRefreshChallenge",
        ttlSec = state.autoDns.challengeTtlSec,
      },
    },
    counts = {
      trackedHosts = tracked_hosts,
      dueNow = due_now,
      queuedNow = queued_now,
      returned = #due,
    },
    dueHosts = due,
  }
end

function handlers.ApplyDnsRefreshResult(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Dns-Proof-State",
    "DnsProofState",
    "Dns-Proof-Valid-Until",
    "DnsProofValidUntil",
    "Dns-Proof-Source",
    "DnsProofSource",
    "Dns-Proof-Seq",
    "DnsProofSeq",
    "Site-Id",
    "SiteId",
    "Process-Id",
    "ProcessId",
    "Module-Id",
    "ModuleId",
    "Scheduler-Id",
    "SchedulerId",
    "Route-Prefix",
    "RoutePrefix",
    "Status",
    "Action-Hint",
    "ActionHint",
    "Challenge-Ref",
    "ChallengeRef",
    "Checked-At",
    "CheckedAt",
    "Next-Check-At",
    "NextCheckAt",
    "Retry-Count",
    "RetryCount",
    "Error",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local proof_state = normalize_proof_state(msg["Dns-Proof-State"] or msg.DnsProofState)
  local last_error = msg.Error ~= nil and trim(tostring(msg.Error)) or nil
  if last_error == "" then
    last_error = nil
  end
  if proof_state == nil and last_error == nil then
    return codec.error(
      "INVALID_INPUT",
      "missing_field:Dns-Proof-State-or-Error",
      { field = "Dns-Proof-State" }
    )
  end

  local checked_at = msg["Checked-At"] or msg.CheckedAt or now_iso()
  if type(checked_at) ~= "string" or iso_to_epoch(checked_at) == nil then
    return codec.error("INVALID_INPUT", "invalid_format:Checked-At", { field = "Checked-At" })
  end

  local valid_until = msg["Dns-Proof-Valid-Until"] or msg.DnsProofValidUntil
  if valid_until ~= nil then
    valid_until = tostring(valid_until)
    if iso_to_epoch(valid_until) == nil then
      return codec.error(
        "INVALID_INPUT",
        "invalid_format:Dns-Proof-Valid-Until",
        { field = "Dns-Proof-Valid-Until" }
      )
    end
  end

  local next_check_at = msg["Next-Check-At"] or msg.NextCheckAt
  if next_check_at ~= nil then
    next_check_at = tostring(next_check_at)
    if iso_to_epoch(next_check_at) == nil then
      return codec.error("INVALID_INPUT", "invalid_format:Next-Check-At", { field = "Next-Check-At" })
    end
  end

  local retry_count = nil
  if msg["Retry-Count"] ~= nil or msg.RetryCount ~= nil then
    local retry_err
    retry_count, retry_err = parse_int_field(msg["Retry-Count"] or msg.RetryCount, "Retry-Count", 0, 1000)
    if retry_err then
      return codec.error("INVALID_INPUT", retry_err, { field = "Retry-Count" })
    end
  end

  local proof_source = msg["Dns-Proof-Source"] or msg.DnsProofSource
  if proof_source ~= nil then
    proof_source = trim(tostring(proof_source)) or ""
    local ok_source_len, source_len_err = validation.check_length(proof_source, 128, "Dns-Proof-Source")
    if not ok_source_len or proof_source == "" then
      return codec.error("INVALID_INPUT", source_len_err or "invalid_format:Dns-Proof-Source", { field = "Dns-Proof-Source" })
    end
  end

  local challenge_ref, challenge_ref_err =
    normalize_challenge_ref(msg["Challenge-Ref"] or msg.ChallengeRef, "Challenge-Ref")
  if challenge_ref_err then
    return codec.error("INVALID_INPUT", challenge_ref_err, { field = "Challenge-Ref" })
  end

  local proof_sequence = nil
  if msg["Dns-Proof-Seq"] ~= nil or msg.DnsProofSeq ~= nil then
    local parsed_sequence, parsed_sequence_err =
      parse_int_field(msg["Dns-Proof-Seq"] or msg.DnsProofSeq, "Dns-Proof-Seq", 0, 2147483647)
    if parsed_sequence_err then
      return codec.error("INVALID_INPUT", parsed_sequence_err, { field = "Dns-Proof-Seq" })
    end
    proof_sequence = parsed_sequence
  end

  local now_epoch = os.time()
  local challenge_ok, challenge_err = validate_refresh_challenge(host, challenge_ref, now_epoch)
  if not challenge_ok then
    return codec.error("INVALID_INPUT", challenge_err, {
      field = "Challenge-Ref",
      challengeRequired = state.autoDns.requireChallenge == true,
    })
  end

  local existing_proof = state.dnsProofState[host] or {}
  local existing_sequence = tonumber(existing_proof.sequence)
  if proof_sequence ~= nil and existing_sequence ~= nil and proof_sequence < existing_sequence then
    return codec.error("INVALID_INPUT", "stale_sequence:Dns-Proof-Seq", {
      field = "Dns-Proof-Seq",
      existing = existing_sequence,
      received = proof_sequence,
    })
  end

  if proof_state ~= nil then
    state.dnsProofState[host] = {
      state = proof_state,
      checkedAt = checked_at,
      validUntil = valid_until,
      source = proof_source or "autonomous-refresh",
      challengeRef = challenge_ref,
      sequence = proof_sequence ~= nil and proof_sequence or existing_sequence,
    }
  end

  local applied_mapping = nil
  if proof_state == "valid" and last_error == nil then
    local mapped, map_err, map_field = upsert_host_policy_from_proof(host, msg)
    if map_err then
      return codec.error("INVALID_INPUT", map_err, { field = map_field or "Process-Id" })
    end
    applied_mapping = mapped
  end

  local existing_meta = state.refreshMeta[host] or {}
  local retry_value = retry_count
  if retry_value == nil then
    if last_error then
      retry_value = (tonumber(existing_meta.retryCount) or 0) + 1
    else
      retry_value = 0
    end
  end

  local computed_next_check = next_check_at
  if computed_next_check == nil then
    if valid_until ~= nil then
      computed_next_check = valid_until
    else
      computed_next_check = plus_seconds_iso(state.autoDns.refreshIntervalSec)
    end
  end

  state.refreshMeta[host] = {
    nextCheckAt = computed_next_check,
    lastCheckAt = checked_at,
    lastError = last_error,
    retryCount = retry_value,
    refreshRequestedAt = nil,
    lastRequestedReason = nil,
    requestCount = tonumber(existing_meta.requestCount) or 0,
  }
  clear_refresh_challenge(host)

  local removed = invalidate_cache_by_host(host)
  state.cacheMeta.lastInvalidatedAt = now_iso()

  return codec.ok {
    schemaVersion = "1.0",
    host = host,
    applied = true,
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
    dnsProofState = state.dnsProofState[host],
    refreshMeta = state.refreshMeta[host],
    hostPolicy = state.hostPolicies[host],
    sitePolicy = state.hostPolicies[host] and state.sitePolicies[state.hostPolicies[host].siteId] or nil,
    mapping = {
      applied = applied_mapping ~= nil,
      value = applied_mapping,
    },
  }
end

function handlers.ApplyHostPolicyFromProof(msg)
  if not ALLOW_DIRECT_HOST_POLICY_APPLY then
    return codec.error(
      "FORBIDDEN",
      "direct_host_policy_apply_disabled",
      { hint = "Use DNS TXT + AR config flow via ApplyDnsRefreshResult." }
    )
  end

  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Site-Id",
    "SiteId",
    "Process-Id",
    "ProcessId",
    "Module-Id",
    "ModuleId",
    "Scheduler-Id",
    "SchedulerId",
    "Route-Prefix",
    "RoutePrefix",
    "Status",
    "Action-Hint",
    "ActionHint",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host", "Process-Id" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local mapped, map_err, map_field = upsert_host_policy_from_proof(host, msg)
  if map_err then
    return codec.error("INVALID_INPUT", map_err, { field = map_field or "Process-Id" })
  end

  local removed = invalidate_cache_by_host(host)
  state.cacheMeta.lastInvalidatedAt = now_iso()

  return codec.ok {
    schemaVersion = "1.0",
    applied = true,
    host = host,
    mapping = mapped,
    hostPolicy = state.hostPolicies[host],
    sitePolicy = state.hostPolicies[host] and state.sitePolicies[state.hostPolicies[host].siteId] or nil,
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
  }
end

function handlers.ForceDnsRefreshHost(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Reason",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local reason = trim(tostring(msg.Reason or "manual_force")) or "manual_force"
  local ok_reason_len, reason_len_err = validation.check_length(reason, 128, "Reason")
  if not ok_reason_len or reason == "" then
    return codec.error("INVALID_INPUT", reason_len_err or "invalid_format:Reason", { field = "Reason" })
  end

  local now_value = now_iso()
  local meta = state.refreshMeta[host] or {}
  meta.nextCheckAt = now_value
  meta.refreshRequestedAt = now_value
  meta.lastRequestedReason = reason
  meta.requestCount = (tonumber(meta.requestCount) or 0) + 1
  state.refreshMeta[host] = meta
  if state.autoDns.requireChallenge == true then
    local issued_ref, issued_expires_at = issue_refresh_challenge(host, reason, state.autoDns.challengeTtlSec)
    meta = state.refreshMeta[host] or meta
    meta.pendingChallenge = issued_ref
    meta.challengeExpiresAt = issued_expires_at
    state.refreshMeta[host] = meta
  end

  local removed = invalidate_cache_by_host(host)
  state.cacheMeta.lastInvalidatedAt = now_iso()

  return codec.ok {
    schemaVersion = "1.0",
    forced = true,
    host = host,
    reason = reason,
    refreshMeta = state.refreshMeta[host],
    challenge = {
      required = state.autoDns.requireChallenge == true,
      challengeRef = state.refreshMeta[host] and state.refreshMeta[host].pendingChallenge or nil,
      challengeExpiresAt = state.refreshMeta[host] and state.refreshMeta[host].challengeExpiresAt or nil,
    },
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
  }
end

function handlers.IssueDnsRefreshChallenge(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Reason",
    "Challenge-Ttl-Sec",
    "ChallengeTtlSec",
    "Challenge-Ref",
    "ChallengeRef",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local reason = trim(tostring(msg.Reason or "manual_issue")) or "manual_issue"
  local ok_reason_len, reason_len_err = validation.check_length(reason, 128, "Reason")
  if not ok_reason_len or reason == "" then
    return codec.error("INVALID_INPUT", reason_len_err or "invalid_format:Reason", { field = "Reason" })
  end

  local ttl = state.autoDns.challengeTtlSec
  if msg["Challenge-Ttl-Sec"] ~= nil or msg.ChallengeTtlSec ~= nil then
    local parsed_ttl, parsed_ttl_err = parse_int_field(
      msg["Challenge-Ttl-Sec"] or msg.ChallengeTtlSec,
      "Challenge-Ttl-Sec",
      30,
      7200
    )
    if parsed_ttl_err then
      return codec.error("INVALID_INPUT", parsed_ttl_err, { field = "Challenge-Ttl-Sec" })
    end
    ttl = parsed_ttl
  end

  local explicit_ref, explicit_ref_err =
    normalize_challenge_ref(msg["Challenge-Ref"] or msg.ChallengeRef, "Challenge-Ref")
  if explicit_ref_err then
    return codec.error("INVALID_INPUT", explicit_ref_err, { field = "Challenge-Ref" })
  end

  local challenge_ref, challenge_expires_at, challenge_ttl = issue_refresh_challenge(host, reason, ttl, explicit_ref)
  return codec.ok {
    schemaVersion = "1.0",
    host = host,
    challenge = {
      required = state.autoDns.requireChallenge == true,
      challengeRef = challenge_ref,
      challengeExpiresAt = challenge_expires_at,
      challengeTtlSec = challenge_ttl,
      reason = reason,
    },
    refreshMeta = state.refreshMeta[host],
  }
end

function handlers.SetAdmissionRule(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Rule",
    "Reason",
    "Allowlist-Enabled",
    "AllowlistEnabled",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host", "Rule" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local rule = string.lower(trim(tostring(msg.Rule)) or "")
  if rule ~= "deny" and rule ~= "allow" then
    return codec.error("INVALID_INPUT", "invalid_format:Rule", { field = "Rule", allowed = { "deny", "allow" } })
  end

  local reason = trim(tostring(msg.Reason or "")) or ""
  if reason ~= "" then
    local ok_reason_len, reason_len_err = validation.check_length(reason, 128, "Reason")
    if not ok_reason_len then
      return codec.error("INVALID_INPUT", reason_len_err, { field = "Reason" })
    end
  end

  local allowlist_enabled = msg["Allowlist-Enabled"]
  if allowlist_enabled == nil then
    allowlist_enabled = msg.AllowlistEnabled
  end
  local previous_allowlist_enabled = state.admission.allowlistEnabled == true
  local allowlist_changed = false
  if allowlist_enabled ~= nil then
    local parsed_allowlist, parsed_allowlist_err =
      parse_boolean_field(allowlist_enabled, "Allowlist-Enabled", state.admission.allowlistEnabled == true)
    if parsed_allowlist_err then
      return codec.error("INVALID_INPUT", parsed_allowlist_err, { field = "Allowlist-Enabled" })
    end
    state.admission.allowlistEnabled = parsed_allowlist
    allowlist_changed = previous_allowlist_enabled ~= parsed_allowlist
  end

  local now_value = now_iso()
  if rule == "deny" then
    state.admission.denyHosts[host] = {
      reason = reason ~= "" and reason or "DENY_ADMISSION_BLOCKLIST",
      updatedAt = now_value,
    }
    state.admission.allowHosts[host] = nil
  else
    state.admission.allowHosts[host] = {
      reason = reason ~= "" and reason or "ALLOW_ADMISSION_ALLOWLIST",
      updatedAt = now_value,
    }
    state.admission.denyHosts[host] = nil
  end
  state.admission.updatedAt = now_value

  local removed = invalidate_cache_by_host(host)
  if allowlist_changed then
    removed = removed + invalidate_cache_all()
  end
  state.cacheMeta.lastInvalidatedAt = now_value

  return codec.ok {
    schemaVersion = "1.0",
    updated = true,
    host = host,
    rule = rule,
    admission = {
      allowlistEnabled = state.admission.allowlistEnabled == true,
      allowCount = map_count(state.admission.allowHosts),
      denyCount = map_count(state.admission.denyHosts),
      updatedAt = state.admission.updatedAt,
    },
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
  }
end

function handlers.RemoveAdmissionRule(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Rule",
    "Allowlist-Enabled",
    "AllowlistEnabled",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local rule = string.lower(trim(tostring(msg.Rule or "both")) or "both")
  if rule ~= "deny" and rule ~= "allow" and rule ~= "both" then
    return codec.error("INVALID_INPUT", "invalid_format:Rule", { field = "Rule", allowed = { "deny", "allow", "both" } })
  end

  if rule == "deny" or rule == "both" then
    state.admission.denyHosts[host] = nil
  end
  if rule == "allow" or rule == "both" then
    state.admission.allowHosts[host] = nil
  end

  local allowlist_enabled = msg["Allowlist-Enabled"]
  if allowlist_enabled == nil then
    allowlist_enabled = msg.AllowlistEnabled
  end
  local previous_allowlist_enabled = state.admission.allowlistEnabled == true
  local allowlist_changed = false
  if allowlist_enabled ~= nil then
    local parsed_allowlist, parsed_allowlist_err =
      parse_boolean_field(allowlist_enabled, "Allowlist-Enabled", state.admission.allowlistEnabled == true)
    if parsed_allowlist_err then
      return codec.error("INVALID_INPUT", parsed_allowlist_err, { field = "Allowlist-Enabled" })
    end
    state.admission.allowlistEnabled = parsed_allowlist
    allowlist_changed = previous_allowlist_enabled ~= parsed_allowlist
  end

  state.admission.updatedAt = now_iso()
  local removed = invalidate_cache_by_host(host)
  if allowlist_changed then
    removed = removed + invalidate_cache_all()
  end
  state.cacheMeta.lastInvalidatedAt = state.admission.updatedAt

  return codec.ok {
    schemaVersion = "1.0",
    removed = true,
    host = host,
    rule = rule,
    admission = {
      allowlistEnabled = state.admission.allowlistEnabled == true,
      allowCount = map_count(state.admission.allowHosts),
      denyCount = map_count(state.admission.denyHosts),
      updatedAt = state.admission.updatedAt,
    },
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
  }
end

function handlers.GetAdmissionState(_msg)
  return codec.ok {
    schemaVersion = "1.0",
    admission = {
      allowlistEnabled = state.admission.allowlistEnabled == true,
      allowHosts = state.admission.allowHosts,
      denyHosts = state.admission.denyHosts,
      allowCount = map_count(state.admission.allowHosts),
      denyCount = map_count(state.admission.denyHosts),
      updatedAt = state.admission.updatedAt,
    },
  }
end

function handlers.ResolveRouteForHost(msg)
  local ok, missing = validation.require_fields(msg, { "Host", "Path", "Method" })
  if not ok then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Path",
    "Method",
    "Node-Id",
    "nodeId",
    "Resolver-Id",
    "Policy-Mode",
    "PolicyMode",
    "Schema-Version",
    "Query",
    "Actor-Role",
    "X-Caller",
    "Site-Id",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end
  local path, path_err = normalize_path(msg.Path, "Path")
  if not path then
    return codec.error("INVALID_INPUT", path_err, { field = "Path" })
  end
  local method, method_err = normalize_method(msg.Method, "Method")
  if not method then
    return codec.error("INVALID_INPUT", method_err, { field = "Method" })
  end

  local node_id, node_err = parse_node_id(msg)
  if node_err then
    return codec.error("INVALID_INPUT", node_err, { field = "Node-Id" })
  end

  local admission_decision, admission_reason = evaluate_admission(host)
  if admission_decision == "deny" then
    local request_id = read_request_id(msg)
    local payload = {
      schemaVersion = "1.0",
      requestId = request_id,
      decision = "deny",
      reasonCode = admission_reason,
      mode = normalize_mode(msg["Policy-Mode"] or msg.PolicyMode),
      host = host,
      path = path,
      method = method,
      nodeId = node_id,
      routeHint = {
        actionHint = infer_action_hint(path, method),
        source = "inferred",
      },
      cache = build_cache_payload(false, build_proof_payload(host), "route", "miss"),
      proof = build_proof_payload(host),
      admission = {
        decision = admission_decision,
        reasonCode = admission_reason,
      },
    }
    return codec.ok(with_result_envelope(payload))
  end

  local requested_mode = msg["Policy-Mode"] or msg.PolicyMode
  local mode, mode_fallback_reason = normalize_mode(requested_mode)
  local request_id = read_request_id(msg)
  local cache_key = make_cache_key("route", host, path, method, mode)
  local cached_entry, cache_state = get_cached_resolution(cache_key)
  if cached_entry then
    local cached_refresh = maybe_queue_refresh_from_access(
      host,
      cached_entry.proof,
      cached_entry.hostKnown == true,
      cache_state
    )
    return codec.ok(payload_from_cached_entry(cached_entry, request_id, node_id, cache_state, cached_refresh))
  end

  local host_policy = state.hostPolicies[host]
  local host_known = host_policy ~= nil
  local proof_payload = build_proof_payload(host)
  local decision, reason_code = evaluate_route_decision(mode, host_known, proof_payload.dnsProofState)
  if mode_fallback_reason then
    reason_code = mode_fallback_reason
  end

  local site_obj, process_obj = infer_site_process(host, host_policy)
  local action_hint, hint_source = resolve_action_hint(host, path, method, host_policy)
  local execution_flow_hint = build_execution_flow_hint(process_obj)
  state.lastResolvedAt = now_iso()

  local payload = {
    schemaVersion = "1.0",
    requestId = request_id,
    decision = decision,
    reasonCode = reason_code,
    mode = mode,
    host = host,
    path = path,
    method = method,
    nodeId = node_id,
    routeHint = {
      actionHint = action_hint,
      source = hint_source,
      executionFlow = execution_flow_hint,
    },
    cache = build_cache_payload(host_known, proof_payload, "route", "miss"),
    proof = proof_payload,
  }

  if site_obj then
    payload.site = site_obj
  end
  if process_obj then
    payload.process = process_obj
  end
  local refresh_payload = maybe_queue_refresh_from_access(host, proof_payload, host_known, "miss")
  if refresh_payload ~= nil then
    payload.refresh = refresh_payload
  end

  upsert_resolution_cache(cache_key, host, {
    siteId = site_obj and site_obj.siteId or nil,
    decision = payload.decision,
    reasonCode = payload.reasonCode,
    mode = payload.mode,
    proofState = proof_payload.dnsProofState,
    dnsNextCheckAt = payload.cache.dnsNextCheckAt,
    surface = "route",
    actionHint = payload.routeHint.actionHint,
    hostKnown = host_known,
    path = path,
    method = method,
    process = process_obj,
    site = site_obj,
    proof = proof_payload,
    executionFlow = execution_flow_hint,
  })
  return codec.ok(with_result_envelope(payload))
end

function handlers.ResolveHostForNode(msg)
  local host_input = msg.Host or msg.host
  if host_input == nil then
    return codec.error("INVALID_INPUT", "Missing field", { missing = { "Host" } })
  end

  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "host",
    "Node-Id",
    "nodeId",
    "Resolver-Id",
    "Policy-Mode",
    "PolicyMode",
    "Schema-Version",
    "Method",
    "Path",
    "Query",
    "Actor-Role",
    "X-Caller",
    "Site-Id",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local host, host_err = normalize_host(host_input, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local node_id, node_err = parse_node_id(msg)
  if node_err then
    return codec.error("INVALID_INPUT", node_err, { field = "Node-Id" })
  end

  local admission_decision, admission_reason = evaluate_admission(host)
  if admission_decision == "deny" then
    local request_id = read_request_id(msg)
    local payload = {
      schemaVersion = "1.0",
      requestId = request_id,
      decision = "deny",
      reasonCode = admission_reason,
      mode = normalize_mode(msg["Policy-Mode"] or msg.PolicyMode),
      host = host,
      nodeId = node_id,
      cache = build_cache_payload(false, build_proof_payload(host), "host", "miss"),
      proof = build_proof_payload(host),
      admission = {
        decision = admission_decision,
        reasonCode = admission_reason,
      },
    }
    return codec.ok(with_result_envelope(payload))
  end

  local requested_mode = msg["Policy-Mode"] or msg.PolicyMode
  local mode, mode_fallback_reason = normalize_mode(requested_mode)
  local request_id = read_request_id(msg)
  local cache_key = make_cache_key("host", host, nil, nil, mode)
  local cached_entry, cache_state = get_cached_resolution(cache_key)
  if cached_entry then
    local cached_refresh = maybe_queue_refresh_from_access(
      host,
      cached_entry.proof,
      cached_entry.hostKnown == true,
      cache_state
    )
    return codec.ok(payload_from_cached_entry(cached_entry, request_id, node_id, cache_state, cached_refresh))
  end

  local host_policy = state.hostPolicies[host]
  local host_known = host_policy ~= nil
  local site_obj, process_obj = infer_site_process(host, host_policy)
  local execution_flow_hint = build_execution_flow_hint(process_obj)
  local proof_payload = build_proof_payload(host)
  local decision, reason_code = evaluate_host_decision(mode, host_known, proof_payload.dnsProofState)
  if mode_fallback_reason then
    reason_code = mode_fallback_reason
  end

  state.lastResolvedAt = now_iso()

  local payload = {
    schemaVersion = "1.0",
    requestId = request_id,
    decision = decision,
    reasonCode = reason_code,
    mode = mode,
    host = host,
    nodeId = node_id,
    cache = build_cache_payload(host_known, proof_payload, "host", "miss"),
    proof = proof_payload,
    executionFlow = execution_flow_hint,
  }

  if site_obj then
    payload.site = site_obj
  end
  if process_obj then
    payload.process = process_obj
  end
  local refresh_payload = maybe_queue_refresh_from_access(host, proof_payload, host_known, "miss")
  if refresh_payload ~= nil then
    payload.refresh = refresh_payload
  end

  upsert_resolution_cache(cache_key, host, {
    siteId = site_obj and site_obj.siteId or nil,
    decision = payload.decision,
    reasonCode = payload.reasonCode,
    mode = payload.mode,
    proofState = proof_payload.dnsProofState,
    dnsNextCheckAt = payload.cache.dnsNextCheckAt,
    surface = "host",
    actionHint = nil,
    hostKnown = host_known,
    path = nil,
    method = nil,
    process = process_obj,
    site = site_obj,
    proof = proof_payload,
    executionFlow = execution_flow_hint,
  })

  return codec.ok(with_result_envelope(payload))
end

map_count = function(tbl)
  local count = 0
  for _ in pairs(tbl or {}) do
    count = count + 1
  end
  return count
end

function handlers.GetResolverState(_msg)
  ensure_cache_hints()
  local pending_challenges = 0
  for _, meta in pairs(state.refreshMeta or {}) do
    if meta and type(meta.pendingChallenge) == "string" and meta.pendingChallenge ~= "" then
      pending_challenges = pending_challenges + 1
    end
  end
  return codec.ok {
    schemaVersion = "1.0",
    policyMode = normalize_mode(state.policyMode),
    failOpen = state.failOpen ~= false,
    cacheHints = {
      positiveTtlSec = state.cacheHints.positiveTtlSec,
      negativeTtlSec = state.cacheHints.negativeTtlSec,
      staleWhileRevalidateSec = state.cacheHints.staleWhileRevalidateSec,
      hardMaxStaleSec = state.cacheHints.hardMaxStaleSec,
    },
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
    executionFlow = execution_flow_snapshot(),
    counts = {
      hostPolicies = map_count(state.hostPolicies),
      sitePolicies = map_count(state.sitePolicies),
      routePolicies = map_count(state.routePolicies),
      dnsProofState = map_count(state.dnsProofState),
      refreshMeta = map_count(state.refreshMeta),
      refreshChallengesPending = pending_challenges,
      resolutionCache = map_count(state.resolutionCache),
      admissionAllow = map_count(state.admission and state.admission.allowHosts or {}),
      admissionDeny = map_count(state.admission and state.admission.denyHosts or {}),
    },
    admission = {
      allowlistEnabled = state.admission.allowlistEnabled == true,
      updatedAt = state.admission.updatedAt,
    },
    bundleMeta = state.bundleMeta,
    cacheMeta = state.cacheMeta,
    lastResolvedAt = state.lastResolvedAt,
    debugLevel = "safe",
  }
end

local function route(msg)
  local ok, missing = validation.require_tags(msg, { "Action" })
  if not ok then
    return codec.missing_tags(missing)
  end

  local ok_action, err = validation.require_action(msg, allowed_actions)
  if not ok_action then
    if err == "unknown_action" then
      return codec.unknown_action(msg.Action)
    end
    return codec.error("MISSING_ACTION", "Action is required")
  end

  prune_resolution_cache()
  prune_refresh_meta()

  local requires_auth = PUBLIC_READ_REQUIRE_AUTH or not public_read_actions[msg.Action]
  if requires_auth then
    local ok_sec, sec_err = auth.enforce(msg)
    if not ok_sec then
      return codec.error("FORBIDDEN", sec_err)
    end
  else
    local ok_rl, rl_err = auth.check_rate_limit(msg)
    if not ok_rl then
      return codec.error("FORBIDDEN", rl_err)
    end
  end

  local ok_hmac, hmac_err =
    auth.verify_outbox_hmac_for_action(msg, { skip_for = hmac_skip_actions })
  if not ok_hmac then
    return codec.error("FORBIDDEN", hmac_err)
  end

  local ok_role, role_err = auth.require_role_for_action(msg, role_policy)
  if not ok_role then
    return codec.error("FORBIDDEN", role_err)
  end

  -- Auth/transport metadata is needed for enforcement, but handlers should not
  -- have to whitelist it explicitly in every require_no_extras() contract.
  local handler_msg = sanitize_handler_message(msg)

  local request_id = read_request_id(handler_msg)
  local scope_host = tostring(handler_msg.Host or handler_msg.host or "")
  local scope_path = tostring(handler_msg.Path or handler_msg.path or "")
  local scope_method = string.upper(tostring(handler_msg.Method or handler_msg.method or ""))
  local idem_key = nil
  if request_id ~= "" then
    idem_key =
      table.concat({ request_id, tostring(handler_msg.Action), scope_host, scope_path, scope_method }, "|")
    local seen = idem.check(idem_key)
    if seen then
      return seen
    end
  end

  local handler = handlers[handler_msg.Action]
  if not handler then
    return codec.unknown_action(handler_msg.Action)
  end

  refresh_state_mutated = false
  local previous_refresh_mutation_flag = request_allows_refresh_queue_mutation
  request_allows_refresh_queue_mutation = requires_auth or ALLOW_PUBLIC_READ_REFRESH_QUEUE
  local resp = handler(handler_msg)
  request_allows_refresh_queue_mutation = previous_refresh_mutation_flag
  metrics.inc("resolver." .. handler_msg.Action .. ".count")
  metrics.tick()
  if idem_key ~= nil then
    idem.record(idem_key, resp)
  end
  maybe_persist_state(mutating_actions[handler_msg.Action] == true or refresh_state_mutated)
  return resp
end

local cjson_ok, cjson = pcall(require, "cjson.safe")

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local i = 0
  for _ in pairs(value) do
    i = i + 1
    if value[i] == nil then
      return false
    end
  end
  return true
end

local function fallback_json_encode(value)
  local value_type = type(value)
  if value_type == "nil" then
    return "null"
  end
  if value_type == "boolean" then
    return value and "true" or "false"
  end
  if value_type == "number" then
    return tostring(value)
  end
  if value_type == "string" then
    return string.format("%q", value)
  end
  if value_type == "table" then
    if is_array(value) then
      local parts = {}
      for _, item in ipairs(value) do
        parts[#parts + 1] = fallback_json_encode(item)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for key, item in pairs(value) do
      parts[#parts + 1] = string.format("%q:%s", tostring(key), fallback_json_encode(item))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return '"<unsupported>"'
end

local function encode_json(value)
  if cjson_ok and type(cjson) == "table" and type(cjson.encode) == "function" then
    local ok_encoded, encoded = pcall(cjson.encode, value)
    if ok_encoded and type(encoded) == "string" then
      return encoded
    end
  end
  return fallback_json_encode(value)
end

local function emit_response_json(json_text)
  local bridge = type(_G) == "table" and _G.__dm_emit_output or nil
  if type(bridge) == "function" then
    local ok_bridge, bridge_result = pcall(bridge, json_text)
    if ok_bridge and type(bridge_result) == "string" then
      return bridge_result
    end
  end
  pcall(function()
    if type(print) == "function" then
      print(json_text)
    end
  end)
  return json_text
end

local function resolve_reply_target(msg, tags)
  local target =
    msg.From or
    msg.from or
    msg["Reply-To"] or
    msg["ReplyTo"] or
    msg.replyTo or
    tag_value(tags, "Reply-To") or
    tag_value(tags, "ReplyTo")
  if type(target) == "string" and target ~= "" then
    return target
  end
  return nil
end

local function safe_send(payload)
  if type(Send) ~= "function" then
    return false
  end
  local ok = pcall(function()
    Send(payload)
  end)
  return ok
end

local function structured_output_result(json_text)
  if type(ao) == "table" and type(ao.result) == "function" then
    return ao.result({
      Output = {
        data = json_text,
        prompt = type(Prompt) == "function" and Prompt() or nil,
        print = true,
      },
      Messages = {},
      Spawns = {},
      Assignments = {},
    })
  end
  return json_text
end

local function trace_resolver_route(label, msg)
  if type(_G) ~= "table" or not _G.__dm_trace_resolver_route then
    return
  end
  local action = nil
  pcall(function()
    local normalized = enrich_message(msg or {})
    action = normalized.Action
  end)
  local line = "__DM_TRACE_RESOLVER_ROUTE__ " .. tostring(label) .. " action=" .. tostring(action)
  pcall(function()
    if type(io) == "table" and type(io.stderr) == "table" and type(io.stderr.write) == "function" then
      io.stderr:write(line .. "\n")
    end
  end)
  pcall(function()
    if type(print) == "function" then
      print(line)
    end
  end)
end

local function tag_value(tags, name)
  if type(tags) ~= "table" then
    return nil
  end
  -- array-style tags: { { name = "...", value = "..." }, ... }
  for _, entry in ipairs(tags) do
    if type(entry) == "table" then
      local entry_name = entry.name or entry.Name
      if entry_name == name then
        local value = entry.value
        if value == nil then
          value = entry.Value
        end
        return value
      end
    end
  end
  -- map-style tags: { Action = "...", Host = "..." }
  if tags[name] ~= nil then
    return tags[name]
  end
  -- mixed/object-style tags: { ["Action"] = { value = "..." } }
  local boxed = tags[name]
  if type(boxed) == "table" then
    return boxed.value or boxed.Value
  end
  for key, value in pairs(tags) do
    if key == name then
      if type(value) == "table" then
        return value.value or value.Value
      end
      return value
    end
  end
  return nil
end

local function parse_json_object(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local trimmed = trim(raw)
  if trimmed == nil or trimmed == "" then
    return nil
  end
  if not (trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}") then
    return nil
  end
  if not (cjson_ok and type(cjson) == "table" and type(cjson.decode) == "function") then
    return nil
  end
  local ok_decoded, decoded = pcall(cjson.decode, trimmed)
  if ok_decoded and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function merge_string_keys(dst, src)
  if type(dst) ~= "table" or type(src) ~= "table" then
    return
  end
  for key, value in pairs(src) do
    if type(key) == "string" and dst[key] == nil then
      dst[key] = value
    end
  end
end

local function merge_tag_keys(dst, tags)
  if type(dst) ~= "table" or type(tags) ~= "table" then
    return
  end
  -- array-style tags: { { name = "...", value = "..." }, ... }
  for _, entry in ipairs(tags) do
    if type(entry) == "table" then
      local name = entry.name or entry.Name
      local value = entry.value or entry.Value
      if type(name) == "string" and dst[name] == nil and value ~= nil then
        dst[name] = value
      end
    end
  end
  -- map-style tags: { Action = "...", Host = "..." }
  for key, value in pairs(tags) do
    if type(key) == "string" and dst[key] == nil then
      if type(value) == "table" then
        local boxed = value.value or value.Value
        if boxed ~= nil then
          dst[key] = boxed
        end
      elseif value ~= nil then
        dst[key] = value
      end
    end
  end
end

local function url_decode_component(raw)
  if type(raw) ~= "string" then
    return raw
  end
  local replaced = raw:gsub("+", " ")
  return (replaced:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function parse_query_string(raw)
  if type(raw) ~= "string" then
    return {}
  end
  local query = trim(raw)
  if query == nil or query == "" then
    return {}
  end
  if query:sub(1, 1) == "?" then
    query = query:sub(2)
  end
  local out = {}
  for pair in query:gmatch("([^&]+)") do
    local key, value = pair:match("^([^=]+)=(.*)$")
    if key == nil then
      key = pair
      value = ""
    end
    key = url_decode_component(key or "")
    value = url_decode_component(value or "")
    if key ~= "" and out[key] == nil then
      out[key] = value
    end
  end
  return out
end

local function query_from_path(raw_path)
  if type(raw_path) ~= "string" then
    return {}
  end
  local query = raw_path:match("%?(.*)$")
  if not query then
    return {}
  end
  return parse_query_string(query)
end

local function merge_query_keys(dst, query)
  if type(dst) ~= "table" or type(query) ~= "table" then
    return
  end
  for key, value in pairs(query) do
    if type(key) == "string" and value ~= nil then
      if dst[key] == nil then
        dst[key] = value
      end
      local lower = string.lower(key)
      if lower == "action" and dst.Action == nil then
        dst.Action = value
      elseif lower == "host" and dst.Host == nil then
        dst.Host = value
      elseif lower == "path" and dst.Path == nil then
        dst.Path = value
      elseif lower == "method" and dst.Method == nil then
        dst.Method = value
      elseif lower == "request-id" and dst["Request-Id"] == nil then
        dst["Request-Id"] = value
      elseif lower == "node-id" and dst["Node-Id"] == nil then
        dst["Node-Id"] = value
      end
    end
  end
end

local function infer_action_from_http_path(path_like)
  if type(path_like) ~= "string" then
    return nil
  end
  local candidate = trim(path_like)
  if candidate == nil or candidate == "" then
    return nil
  end
  candidate = candidate:gsub("^https?://[^/]+", "")
  local base = candidate:match("^[^?]+") or candidate
  local action = base:match("/([A-Za-z][A-Za-z0-9_-]+)$")
  if type(action) == "string" and handlers[action] ~= nil then
    return action
  end
  return nil
end

local function enrich_message(msg)
  local envelope = (type(msg) == "table" and (msg.Body or msg.body)) or {}
  local tags = msg.Tags or msg.tags or envelope.Tags or envelope.tags or {}
  local data_obj = parse_json_object(msg.Data or msg.data)
    or parse_json_object(envelope.Data or envelope.data)
    or {}

  local out = {}
  merge_string_keys(out, data_obj)
  merge_string_keys(out, envelope)
  merge_string_keys(out, msg)
  merge_tag_keys(out, tags)
  merge_query_keys(out, parse_query_string(msg.Query or msg.query))
  merge_query_keys(out, parse_query_string(envelope.Query or envelope.query))
  merge_query_keys(out, parse_query_string(tag_value(tags, "Query") or tag_value(tags, "query")))

  local path_candidates = {
    out.Path,
    out.path,
    out.Uri,
    out.uri,
    out.URL,
    out.url,
    out["Request-Path"],
    out.request_path,
    msg.Path,
    msg.path,
    msg.Uri,
    msg.uri,
    msg.URL,
    msg.url,
  }
  for _, candidate in ipairs(path_candidates) do
    if type(candidate) == "string" and candidate ~= "" then
      merge_query_keys(out, query_from_path(candidate))
    end
  end

  out.Action = out.Action or out.action or tag_value(tags, "Action")
  if out.Action == nil then
    for _, candidate in ipairs(path_candidates) do
      local inferred = infer_action_from_http_path(candidate)
      if inferred ~= nil then
        out.Action = inferred
        break
      end
    end
  end
  out.Host = out.Host or out.host
  out.Path = out.Path or out.path
  out.Method = out.Method or out.method
  out["Request-Id"] = out["Request-Id"] or out.requestId or tag_value(tags, "Request-Id")
  out["Actor-Role"] = out["Actor-Role"] or out.actorRole or tag_value(tags, "Actor-Role")
  out["Schema-Version"] = out["Schema-Version"]
    or out.schemaVersion
    or tag_value(tags, "Schema-Version")
  out.Signature = out.Signature or out.signature or tag_value(tags, "Signature")
  out.Nonce = out.Nonce or out.nonce or tag_value(tags, "Nonce")
  out.ts = out.ts or out.timestamp or tag_value(tags, "ts")
  out.From = msg.From or msg.from
  out.Tags = tags
  return out
end

local function handle_resolver_action(msg)
  local normalized = enrich_message(msg or {})
  trace_resolver_route("handle_resolver_action", normalized)
  local ok_route, route_result = pcall(route, normalized)
  local resp = ok_route and route_result
    or codec.error("HANDLER_CRASH", tostring(route_result or "resolver_handler_crash"))
  local json_text = encode_json(resp)
  local reply_target = resolve_reply_target(msg or {}, normalized.Tags)
  if reply_target then
    safe_send {
      Target = reply_target,
      Action = "Resolver-Command-Result",
      ["Resolver-Action"] = normalized.Action,
      ["Request-Id"] = normalized["Request-Id"],
      ["Read-Contract-Version"] = "resolver-reply-message.v1",
      ["Content-Type"] = "application/json",
      Data = json_text,
    }
  end
  emit_response_json(json_text)
  return structured_output_result(json_text)
end

local function is_resolver_action(msg)
  if type(msg) ~= "table" then
    return false
  end
  local normalized = enrich_message(msg)
  local action = normalized.Action
  return type(action) == "string" and handlers[action] ~= nil
end

local resolver_handler_registered = false
local resolver_evaluate_wrapped = false
local original_handlers_evaluate = nil
local function resolve_handlers_api()
  if type(_G) == "table" and type(_G.Handlers) == "table" then
    return _G.Handlers
  end
  local env = _ENV
  if type(env) == "table" and type(env.Handlers) == "table" then
    return env.Handlers
  end
  return nil
end

local function ensure_resolver_evaluate_wrapped(handlers_api)
  local api = handlers_api
  if type(api) ~= "table" then
    api = resolve_handlers_api()
  end
  if type(api) ~= "table" or type(api.evaluate) ~= "function" then
    return false
  end
  if not resolver_evaluate_wrapped then
    original_handlers_evaluate = api.evaluate
    api.evaluate = function(msg, env)
      if is_resolver_action(msg) then
        trace_resolver_route("wrapped_evaluate", msg)
        return handle_resolver_action(msg)
      end
      return original_handlers_evaluate(msg, env)
    end
    resolver_evaluate_wrapped = true
  end
  return true
end

local function ensure_resolver_handler_registered()
  local handlers_api = resolve_handlers_api()
  if type(handlers_api) ~= "table" or type(handlers_api.add) ~= "function" then
    local ok_handlers, resolved_handlers = pcall(require, ".handlers")
    if
      ok_handlers
      and type(resolved_handlers) == "table"
      and type(resolved_handlers.add) == "function"
    then
      handlers_api = resolved_handlers
    else
      return false
    end
  end

  if not resolver_handler_registered then
    handlers_api.add("Resolver-Action", is_resolver_action, handle_resolver_action)
    resolver_handler_registered = true
  end
  ensure_resolver_evaluate_wrapped(handlers_api)
  return true
end

-- Default to eager wrapper registration so resolver actions are wired on
-- runtime profiles that invoke global Handle/handle or Handlers.handle paths.
-- Keep an explicit opt-out for lab experiments.
local eager_resolver_wrappers_enabled = true
if type(_G) == "table" and _G.__dm_disable_eager_resolver_wrappers == true then
  eager_resolver_wrappers_enabled = false
end

-- Late process.handle rebinding has proven replay-sensitive on the current
-- AO runtime path. Keep it opt-in for focused lab experiments only.
local eager_resolver_process_handle_wrap_enabled = false
if type(_G) == "table" and _G.__dm_enable_resolver_process_handle_wrap == true then
  eager_resolver_process_handle_wrap_enabled = true
end

local function fallback_handle(msg)
  ensure_resolver_handler_registered()
  trace_resolver_route("fallback_handle_pre", msg)
  if is_resolver_action(msg) then
    trace_resolver_route("fallback_handle", msg)
    return handle_resolver_action(msg)
  end
  return nil
end

if type(_G) == "table" then
  _G.__dm_bootstrap_resolver_evaluate_wrapper = function()
    local handlers_api = resolve_handlers_api()
    if type(handlers_api) ~= "table" or type(handlers_api.evaluate) ~= "function" then
      return false
    end
    return ensure_resolver_evaluate_wrapped(handlers_api)
  end
  _G.__dm_resolver_handle_action = function(msg)
    if not is_resolver_action(msg) then
      return nil
    end
    trace_resolver_route("external_handle_action", msg)
    return handle_resolver_action(msg)
  end
  _G.__dm_resolver_inline_route = function(msg)
    ensure_resolver_handler_registered()
    if is_resolver_action(msg) then
      trace_resolver_route("inline_route", msg)
      return handle_resolver_action(msg)
    end
    return nil
  end
end

local resolver_process_handle_wrapped = false
local original_process_handle = nil

local function ensure_resolver_process_handle_wrapped()
  if resolver_process_handle_wrapped then
    return true
  end
  if type(process) ~= "table" or type(process.handle) ~= "function" then
    return false
  end
  original_process_handle = process.handle
  process.handle = function(msg, env)
    local routed = fallback_handle(msg)
    if routed ~= nil then
      trace_resolver_route("process_handle_wrapper", msg)
      return routed
    end
    return original_process_handle(msg, env)
  end
  resolver_process_handle_wrapped = true
  return true
end

if eager_resolver_wrappers_enabled then
  ensure_resolver_handler_registered()
  if eager_resolver_process_handle_wrap_enabled then
    ensure_resolver_process_handle_wrapped()
  end
end

local previous_Handle = nil
local previous_handle = nil
if eager_resolver_wrappers_enabled then
  previous_Handle = _G.Handle
  previous_handle = _G.handle
end

local function emit_handler_error(code, message, meta)
  return emit_response_json(encode_json(codec.error(code, message, meta)))
end

local function merged_global_handle(original, msg)
  local routed = fallback_handle(msg)
  if routed ~= nil then
    return routed
  end
  if type(original) == "function" then
    local ok_original, original_result = pcall(original, msg)
    if ok_original then
      return original_result
    else
      return emit_handler_error(
        "HANDLER_CRASH",
        tostring(original_result or "resolver_original_handle_crash")
      )
    end
  end
  return nil
end

if eager_resolver_wrappers_enabled then
  _G.Handle = function(msg)
    return merged_global_handle(previous_Handle, msg)
  end

  _G.handle = function(msg)
    local original = previous_handle
    if type(original) ~= "function" then
      original = previous_Handle
    end
    return merged_global_handle(original, msg)
  end
end

-- Some runtime wrappers invoke `Handlers.handle(msg)` instead of global
-- `Handle/handle`. Keep this alias in sync so wasm-lua wrappers do not fail
-- with "attempt to call a nil value (field 'handle')".
local function ensure_handlers_handle_alias()
  -- Keep a hard fallback on the global namespace, because some wasm-lua
  -- wrappers call `Handlers.handle(msg)` directly even when `.handlers`
  -- is unavailable.
  if type(_G) == "table" then
    if type(_G.Handlers) ~= "table" then
      _G.Handlers = {}
    end
    -- Force bridge even when handle already exists; some runtimes bypass
    -- global Handle/handle and call Handlers.handle directly.
    _G.Handlers.handle = function(msg)
      return _G.handle(msg)
    end
  end

  local handlers_api = resolve_handlers_api()
  if type(handlers_api) ~= "table" then
    return
  end
  -- Same bridge on resolved handlers table so both namespaces stay in sync.
  handlers_api.handle = function(msg)
    return _G.handle(msg)
  end
end

if eager_resolver_wrappers_enabled then
  ensure_handlers_handle_alias()
end

return {
  route = route,
  _state = state,
}
]====], "ao.resolver.process")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end

return require("ao.resolver.process")
