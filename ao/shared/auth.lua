-- Shared auth utilities: signature verification and role checks.
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
