-- Persistence adapter with three tiers:
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
