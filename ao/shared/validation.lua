-- Shared schema validation and payload guards (lightweight).
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
