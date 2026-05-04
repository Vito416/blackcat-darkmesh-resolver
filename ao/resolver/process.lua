-- Resolver process scaffold: host -> decision contract for HB policy routing.
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
