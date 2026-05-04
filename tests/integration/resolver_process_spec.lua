package.path = table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

-- Use a small auth stub so integration checks can exercise admin ApplyPolicyBundle
-- semantics without relying on external signature/nonce environment wiring.
package.loaded["ao.shared.auth"] = {
  check_rate_limit = function()
    return true
  end,
  enforce = function()
    return true
  end,
  verify_outbox_hmac_for_action = function()
    return true
  end,
  require_role_for_action = function(msg, policy)
    local roles = policy and policy[msg.Action]
    if not roles then
      return true
    end
    local role = msg["Actor-Role"] or msg.actorRole or msg.role
    if not role then
      return false, "missing_role"
    end
    for _, allowed in ipairs(roles) do
      if allowed == role then
        return true
      end
    end
    return false, "forbidden_role"
  end,
}

local resolver = require "ao.resolver.process"
local CENTRALIZED_BUNDLE_WRITES_ALLOWED =
  (os.getenv("RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES") or "0") == "1"
local VALID_PROCESS_ID = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q"
local VALID_PROCESS_ID_ALT = "_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM"
local VALID_MODULE_ID = "TrNj8CSFaevoYSAsnxuQ97SkdDuPvpkgxR-L6i3QCzY"
local VALID_SCHEDULER_ID = "_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM"

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[deep_copy(key)] = deep_copy(item)
  end
  return out
end

local function normalize_fixture_host(host)
  local value = tostring(host or ""):lower()
  local colon = value:find(":", 1, true)
  if colon ~= nil then
    value = value:sub(1, colon - 1)
  end
  return value
end

local function normalize_fixture_methods(input)
  if input == nil then
    return nil
  end
  local out = {}
  for _, method in ipairs(input) do
    out[string.upper(tostring(method))] = true
  end
  return out
end

local function normalize_fixture_route_policies(input)
  if input == nil then
    return nil
  end
  local out = {}
  for host, spec in pairs(input) do
    local entry = {}
    if spec.defaultActionHint ~= nil then
      entry.defaultActionHint = tostring(spec.defaultActionHint)
    end
    entry.rules = {}
    for _, rule in ipairs(spec.rules or {}) do
      entry.rules[#entry.rules + 1] = {
        pathPrefix = tostring(rule.pathPrefix or rule.path or "/"),
        methods = normalize_fixture_methods(rule.methods),
        actionHint = tostring(rule.actionHint or spec.defaultActionHint or "read"),
      }
    end
    out[normalize_fixture_host(host)] = entry
  end
  return out
end

local function normalize_fixture_host_map(input)
  if input == nil then
    return nil
  end
  local out = {}
  for host, spec in pairs(input) do
    out[normalize_fixture_host(host)] = deep_copy(spec)
  end
  return out
end

local function resolve(req_id, host, mode)
  return resolver.route {
    Action = "ResolveHostForNode",
    ["Request-Id"] = req_id,
    Host = host,
    ["Policy-Mode"] = mode,
    ["Node-Id"] = "node-eu-1",
  }
end

local function resolve_route(req_id, host, path, method, mode)
  return resolver.route {
    Action = "ResolveRouteForHost",
    ["Request-Id"] = req_id,
    Host = host,
    Path = path,
    Method = method,
    ["Policy-Mode"] = mode,
    ["Node-Id"] = "node-eu-1",
  }
end

local function apply_bundle(req_id, role, bundle)
  return resolver.route {
    Action = "ApplyPolicyBundle",
    ["Request-Id"] = req_id,
    ["Actor-Role"] = role,
    Bundle = bundle,
  }
end

local function invalidate_cache(req_id, role, scope, host, site_id)
  local msg = {
    Action = "InvalidateResolverCache",
    ["Request-Id"] = req_id,
    ["Actor-Role"] = role,
    Scope = scope,
  }
  if host ~= nil then
    msg.Host = host
  end
  if site_id ~= nil then
    msg["Site-Id"] = site_id
  end
  return resolver.route(msg)
end

local function get_cache_stats(req_id)
  return resolver.route {
    Action = "GetResolverCacheStats",
    ["Request-Id"] = req_id,
  }
end

local function list_due_hosts(req_id, role, extra)
  local msg = {
    Action = "ListHostsDueForDnsRefresh",
    ["Request-Id"] = req_id,
    ["Actor-Role"] = role,
  }
  for key, value in pairs(extra or {}) do
    msg[key] = value
  end
  return resolver.route(msg)
end

local function force_refresh_host(req_id, role, host, extra)
  local msg = {
    Action = "ForceDnsRefreshHost",
    ["Request-Id"] = req_id,
    ["Actor-Role"] = role,
    Host = host,
  }
  for key, value in pairs(extra or {}) do
    msg[key] = value
  end
  return resolver.route(msg)
end

local function reset_state()
  resolver._state.policyMode = "off"
  resolver._state.failOpen = true
  resolver._state.hostPolicies = {}
  resolver._state.sitePolicies = {}
  resolver._state.routePolicies = {}
  resolver._state.dnsProofState = {}
  resolver._state.refreshMeta = {}
  resolver._state.resolutionCache = {}
  resolver._state.cacheHints = {
    positiveTtlSec = 300,
    negativeTtlSec = 60,
    staleWhileRevalidateSec = 900,
    hardMaxStaleSec = 3600,
  }
  resolver._state.bundleMeta = {}
  resolver._state.cacheMeta = {}
  resolver._state.lastResolvedAt = nil
end

local function apply_bundle_fixture_direct(bundle, req_id)
  local applied_at = bundle.generatedAt or ("fixture-seeded:" .. tostring(req_id))

  if bundle.hostPolicies ~= nil then
    resolver._state.hostPolicies = normalize_fixture_host_map(bundle.hostPolicies)
  end
  if bundle.sitePolicies ~= nil then
    resolver._state.sitePolicies = deep_copy(bundle.sitePolicies)
  end
  if bundle.routePolicies ~= nil then
    resolver._state.routePolicies = normalize_fixture_route_policies(bundle.routePolicies)
  end
  if bundle.dnsProofState ~= nil then
    resolver._state.dnsProofState = normalize_fixture_host_map(bundle.dnsProofState)
  end
  if bundle.cacheHints ~= nil then
    resolver._state.cacheHints = deep_copy(bundle.cacheHints)
  end
  if bundle.policyMode ~= nil then
    resolver._state.policyMode = tostring(bundle.policyMode):lower()
  end
  if bundle.failOpen ~= nil then
    resolver._state.failOpen = bundle.failOpen ~= false
  end

  resolver._state.resolutionCache = {}
  resolver._state.lastResolvedAt = nil
  resolver._state.bundleMeta = {
    snapshotId = bundle.snapshotId,
    version = bundle.version,
    generatedAt = bundle.generatedAt,
    appliedAt = applied_at,
  }
  resolver._state.cacheMeta = resolver._state.cacheMeta or {}
  resolver._state.cacheMeta.lastInvalidatedAt = applied_at
end

local function assert_blocked_bundle_write(response, expected_fields)
  assert(response.status == "ERROR", "default bundle write should be blocked")
  assert(response.code == "FORBIDDEN", "blocked bundle write should return FORBIDDEN")
  assert(response.message == "centralized_bundle_writes_disabled", "blocked write reason mismatch")
  local detail = response.payload or response.meta or {}
  local fields = detail.fields or {}
  assert(#fields == #expected_fields, "blocked fields count mismatch")
  local seen = {}
  for _, field in ipairs(fields) do
    seen[field] = true
  end
  for _, field in ipairs(expected_fields) do
    assert(seen[field] == true, "missing blocked field: " .. tostring(field))
  end
end

local function apply_bundle_or_seed(req_id, bundle, expected_fields)
  local response = apply_bundle(req_id, "admin", bundle)
  if CENTRALIZED_BUNDLE_WRITES_ALLOWED then
    assert(response.status == "OK", "expected ApplyPolicyBundle success when opt-in env is enabled")
    return response
  end

  assert_blocked_bundle_write(response, expected_fields)
  apply_bundle_fixture_direct(bundle, req_id)
  return response
end

-- Reset mutable state for deterministic output.
reset_state()

local forbidden_apply = apply_bundle("resolver-it-apply-forbidden", "viewer", {})
assert(forbidden_apply.status == "ERROR", "ApplyPolicyBundle must be role-gated")
assert(forbidden_apply.code == "FORBIDDEN", "non-admin apply should be forbidden")

local initial_bundle = {
  snapshotId = "snap-test-1",
  version = 1,
  generatedAt = "2026-04-22T11:00:00Z",
  policyMode = "observe",
  failOpen = true,
  cacheHints = {
    positiveTtlSec = 240,
    negativeTtlSec = 30,
    staleWhileRevalidateSec = 600,
    hardMaxStaleSec = 1200,
  },
  hostPolicies = {
    ["jdwt.fun"] = {
      siteId = "site-jdwt",
      processId = VALID_PROCESS_ID,
      scheduler = VALID_SCHEDULER_ID,
    },
    ["vddl.fun"] = {
      siteId = "site-vddl",
      processId = VALID_PROCESS_ID_ALT,
    },
  },
  routePolicies = {
    ["jdwt.fun"] = {
      defaultActionHint = "read",
      rules = {
        { pathPrefix = "/checkout", methods = { "POST" }, actionHint = "checkout_write" },
        { pathPrefix = "/api", methods = { "GET" }, actionHint = "api_read" },
      },
    },
    ["vddl.fun"] = {
      defaultActionHint = "catalog_read",
      rules = {
        { pathPrefix = "/orders", methods = { "POST" }, actionHint = "orders_write" },
      },
    },
  },
  sitePolicies = {
    ["site-jdwt"] = {
      moduleId = VALID_MODULE_ID,
      routePrefix = "/~relay@1.0",
    },
    ["site-vddl"] = {
      moduleId = VALID_MODULE_ID,
      routePrefix = "/~relay@1.0",
    },
  },
  dnsProofState = {
    ["jdwt.fun"] = {
      state = "valid",
      checkedAt = "2026-04-22T11:00:00Z",
      validUntil = "2026-04-22T17:00:00Z",
    },
    ["vddl.fun"] = {
      state = "expired",
      checkedAt = "2026-04-22T11:00:00Z",
      validUntil = "2026-04-22T11:30:00Z",
    },
  },
}

local applied = apply_bundle_or_seed(
  "resolver-it-apply-1",
  initial_bundle,
  { "hostPolicies", "sitePolicies", "routePolicies", "dnsProofState" }
)

if CENTRALIZED_BUNDLE_WRITES_ALLOWED then
  assert(applied.status == "OK", "expected ApplyPolicyBundle success")
  assert(applied.payload.applied == true, "expected applied flag")
  assert(applied.payload.policyMode == "observe", "bundle mode should be persisted")
  assert(applied.payload.counts.hostPolicies == 2, "expected 2 host policies")
  assert(applied.payload.counts.sitePolicies == 2, "expected 2 site policies")
  assert(applied.payload.counts.routePolicies == 2, "expected 2 route policies")
  assert(applied.payload.counts.dnsProofState == 2, "expected 2 dns proof entries")
else
  assert(resolver._state.policyMode == "observe", "fixture seed should persist bundle mode")
  assert(resolver._state.failOpen == true, "fixture seed should persist failOpen")
end

local forbidden_invalidate = invalidate_cache("resolver-it-invalidate-forbidden", "viewer", "all")
assert(forbidden_invalidate.status == "ERROR", "InvalidateResolverCache must be role-gated")
assert(forbidden_invalidate.code == "FORBIDDEN", "non-admin invalidation should be forbidden")

local due_hosts_with_auth_meta = list_due_hosts("resolver-it-due-auth-meta", "admin", {
  Nonce = "nonce-due-auth-meta",
  ts = os.time(),
  Signature = "deadbeef",
  Authorization = "Bearer ignored-by-stub",
})
assert(due_hosts_with_auth_meta.status == "OK", "protected due-hosts read should ignore auth envelope extras")

local force_refresh_with_auth_meta = force_refresh_host("resolver-it-force-auth-meta", "admin", "jdwt.fun", {
  Nonce = "nonce-force-auth-meta",
  ts = os.time(),
  Signature = "deadbeef",
  ["Device-Token"] = "ignored-by-stub",
})
assert(force_refresh_with_auth_meta.status == "OK", "protected force refresh should ignore auth envelope extras")
assert(force_refresh_with_auth_meta.payload.host == "jdwt.fun", "force refresh host mismatch")

local valid_observe = resolve("resolver-it-valid-observe", "JDWT.FUN:443", "observe")
assert(valid_observe.status == "OK", "valid observe resolve must succeed")
assert(valid_observe.payload.decision == "allow", "valid proof should allow")
assert(valid_observe.payload.reasonCode == "ALLOW_DNS_PROOF_VALID", "valid proof reason mismatch")
assert(valid_observe.payload.cache.cacheState == "miss", "first resolve should be miss")
assert(valid_observe.payload.cache.expiresAt, "cache expiresAt must be present")
assert(valid_observe.payload.cache.dnsNextCheckAt == "2026-04-22T17:00:00Z", "dnsNextCheckAt should honor proof validity")
assert(valid_observe.payload.policy.mode == "observe", "policy envelope mode mismatch")
assert(valid_observe.payload.result.status == "ALLOW", "result envelope status mismatch")

local valid_observe_cached = resolve("resolver-it-valid-observe-cached", "jdwt.fun", "observe")
assert(valid_observe_cached.status == "OK", "cached valid resolve should succeed")
assert(valid_observe_cached.payload.cache.cacheState == "hit", "second resolve should be cache hit")

local route_mapped_off = resolve_route("resolver-it-route-mapped-off", "JDWT.FUN", "/checkout", "POST", "off")
assert(route_mapped_off.status == "OK", "mapped route resolve must succeed")
assert(route_mapped_off.payload.decision == "allow", "mapped/off route should allow")
assert(route_mapped_off.payload.reasonCode == "ALLOW_DNS_PROOF_VALID", "mapped/off route reason mismatch")
assert(route_mapped_off.payload.cache.cacheState == "miss", "first mapped route should be miss")
assert(route_mapped_off.payload.routeHint.actionHint == "checkout_write", "route action hint should come from policy rule")
assert(route_mapped_off.payload.routeHint.source == "route_policy_rule", "route hint source mismatch")
assert(route_mapped_off.payload.cache.expiresAt ~= nil, "route cache expiresAt missing")
assert(route_mapped_off.payload.cache.dnsNextCheckAt == "2026-04-22T17:00:00Z", "route dnsNextCheckAt mismatch")

local route_mapped_off_cached =
  resolve_route("resolver-it-route-mapped-off-cached", "jdwt.fun", "/checkout", "POST", "off")
assert(route_mapped_off_cached.status == "OK", "cached mapped route resolve must succeed")
assert(route_mapped_off_cached.payload.cache.cacheState == "hit", "cached mapped route should be hit")

local route_unmapped_off = resolve_route("resolver-it-route-unmapped-off", "unknown.fun", "/index", "GET", "off")
assert(route_unmapped_off.status == "OK", "unmapped/off route resolve must succeed")
assert(route_unmapped_off.payload.decision == "allow", "unmapped/off route should allow")
assert(route_unmapped_off.payload.cache.cacheState == "miss", "first unmapped route should be miss")
assert(
  route_unmapped_off.payload.reasonCode == "ALLOW_ROUTE_HOST_UNMAPPED_MODE_OFF",
  "unmapped/off route reason mismatch"
)

local route_unmapped_off_cached =
  resolve_route("resolver-it-route-unmapped-off-cached", "unknown.fun", "/index", "GET", "off")
assert(route_unmapped_off_cached.status == "OK", "cached unmapped route resolve must succeed")
assert(route_unmapped_off_cached.payload.cache.cacheState == "negative_hit", "second unmapped route should be negative hit")

local stale_key = "route|off|unknown.fun|/index|GET"
if resolver._state.resolutionCache[stale_key] then
  resolver._state.resolutionCache[stale_key].expiresAtEpoch = os.time() - 1
  resolver._state.resolutionCache[stale_key].staleUntilEpoch = os.time() + 30
end
local route_unmapped_off_stale = resolve_route("resolver-it-route-unmapped-off-stale", "unknown.fun", "/index", "GET", "off")
assert(route_unmapped_off_stale.status == "OK", "stale unmapped route resolve must succeed")
assert(route_unmapped_off_stale.payload.cache.cacheState == "stale", "stale route should return stale cache state")
assert(route_unmapped_off_stale.payload.cache.staleWhileRevalidate == true, "stale marker should be true")

local cache_stats_before = get_cache_stats("resolver-it-cache-stats-before")
assert(cache_stats_before.status == "OK", "cache stats should be readable")
assert(cache_stats_before.payload.counts.entriesTotal >= 2, "expected cache entries after warm-up")
assert(cache_stats_before.payload.lastAppliedAt ~= nil, "stats should include lastAppliedAt")
assert(cache_stats_before.payload.lastResolvedAt ~= nil, "stats should include lastResolvedAt")

local invalidate_host = invalidate_cache("resolver-it-invalidate-host", "admin", "host", "JDWT.FUN:443")
assert(invalidate_host.status == "OK", "host invalidation should succeed")
assert(invalidate_host.payload.scope == "host", "host invalidation scope mismatch")
assert(invalidate_host.payload.removedEntries >= 1, "host invalidation should remove at least one entry")

local vddl_observe_for_site_invalidation = resolve("resolver-it-vddl-observe-for-site-invalid", "vddl.fun", "observe")
assert(vddl_observe_for_site_invalidation.status == "OK", "vddl warm-up for site invalidation should succeed")

local invalidate_site = invalidate_cache("resolver-it-invalidate-site", "admin", "site", nil, "site-vddl")
assert(invalidate_site.status == "OK", "site invalidation should succeed")
assert(invalidate_site.payload.scope == "site", "site invalidation scope mismatch")
assert(invalidate_site.payload.removedEntries >= 1, "site invalidation should remove vddl entry")

local cache_stats_mid = get_cache_stats("resolver-it-cache-stats-mid")
assert(cache_stats_mid.status == "OK", "mid cache stats should be readable")
assert(cache_stats_mid.payload.lastInvalidatedAt ~= nil, "stats should include lastInvalidatedAt")

local invalidate_all = invalidate_cache("resolver-it-invalidate-all", "admin", "all")
assert(invalidate_all.status == "OK", "all invalidation should succeed")
assert(invalidate_all.payload.scope == "all", "all invalidation scope mismatch")
assert(invalidate_all.payload.remainingEntries == 0, "all invalidation should empty cache")

local cache_stats_after = get_cache_stats("resolver-it-cache-stats-after")
assert(cache_stats_after.status == "OK", "post invalidation stats should be readable")
assert(cache_stats_after.payload.counts.entriesTotal == 0, "cache should be empty after all invalidation")

local expired_off = resolve("resolver-it-expired-off", "vddl.fun", "off")
assert(expired_off.status == "OK", "expired/off resolve must succeed")
assert(expired_off.payload.decision == "allow", "expired/off should allow")
assert(expired_off.payload.reasonCode == "ALLOW_DNS_PROOF_EXPIRED_MODE_OFF", "expired/off reason mismatch")

local expired_observe = resolve("resolver-it-expired-observe", "vddl.fun", "observe")
assert(expired_observe.status == "OK", "expired/observe resolve must succeed")
assert(expired_observe.payload.decision == "allow", "expired/observe should allow")
assert(expired_observe.payload.reasonCode == "ALLOW_DNS_PROOF_EXPIRED_MODE_OBSERVE", "expired/observe reason mismatch")

local expired_soft_fail_open = resolve("resolver-it-expired-soft-open", "vddl.fun", "soft")
assert(expired_soft_fail_open.status == "OK", "expired/soft resolve must succeed")
assert(expired_soft_fail_open.payload.decision == "allow", "fail-open true should keep allow")
assert(
  expired_soft_fail_open.payload.reasonCode == "DENY_READY_DNS_PROOF_EXPIRED",
  "soft/enforce should emit deny-ready reason when proof expired"
)

local route_expired_soft_fail_open = resolve_route(
  "resolver-it-route-expired-soft-open",
  "vddl.fun",
  "/orders",
  "POST",
  "soft"
)
assert(route_expired_soft_fail_open.status == "OK", "expired/soft route resolve must succeed")
assert(route_expired_soft_fail_open.payload.decision == "allow", "fail-open true keeps route allow")
assert(
  route_expired_soft_fail_open.payload.reasonCode == "DENY_READY_DNS_PROOF_EXPIRED",
  "expired/soft route should emit deny-ready reason"
)
assert(
  route_expired_soft_fail_open.payload.routeHint.actionHint == "orders_write",
  "route hint should still be resolved under fail-open"
)

local fail_closed_bundle = {
  policyMode = "soft",
  failOpen = false,
  dnsProofState = {
    ["vddl.fun"] = {
      state = "expired",
      checkedAt = "2026-04-22T11:00:00Z",
      validUntil = "2026-04-22T11:30:00Z",
    },
    ["blgateway.fun"] = {
      state = "missing",
      checkedAt = "2026-04-22T11:00:00Z",
      validUntil = nil,
    },
  },
  hostPolicies = {
    ["vddl.fun"] = {
      siteId = "site-vddl",
      processId = VALID_PROCESS_ID_ALT,
    },
    ["blgateway.fun"] = {
      siteId = "site-blgateway",
      processId = VALID_PROCESS_ID,
    },
  },
}
local applied_fail_closed =
  apply_bundle_or_seed("resolver-it-apply-2", fail_closed_bundle, { "hostPolicies", "dnsProofState" })
if CENTRALIZED_BUNDLE_WRITES_ALLOWED then
  assert(applied_fail_closed.status == "OK", "second apply should succeed")
  assert(applied_fail_closed.payload.failOpen == false, "failOpen should now be false")
else
  assert(resolver._state.failOpen == false, "fixture seed should set failOpen false")
end

local expired_off_still_allow = resolve("resolver-it-expired-off-after-fail-closed", "vddl.fun", "off")
assert(expired_off_still_allow.status == "OK", "off mode should remain functional after failOpen=false")
assert(expired_off_still_allow.payload.decision == "allow", "off mode must remain fail-open by contract")
assert(
  expired_off_still_allow.payload.reasonCode == "ALLOW_DNS_PROOF_EXPIRED_MODE_OFF",
  "off mode reason must remain ALLOW_*"
)

local expired_soft_fail_closed = resolve("resolver-it-expired-soft-closed", "vddl.fun", "soft")
assert(expired_soft_fail_closed.status == "OK", "expired/soft fail-closed resolve must succeed")
assert(expired_soft_fail_closed.payload.decision == "deny", "fail-open false should deny in soft/enforce")
assert(
  expired_soft_fail_closed.payload.reasonCode == "DENY_READY_DNS_PROOF_EXPIRED",
  "expired soft fail-closed reason mismatch"
)

local missing_enforce_fail_closed = resolve("resolver-it-missing-enforce-closed", "blgateway.fun", "enforce")
assert(missing_enforce_fail_closed.status == "OK", "missing/enforce fail-closed resolve must succeed")
assert(missing_enforce_fail_closed.payload.decision == "deny", "missing/enforce should deny when fail-open false")
assert(
  missing_enforce_fail_closed.payload.reasonCode == "DENY_READY_DNS_PROOF_MISSING",
  "missing/enforce reason mismatch"
)
assert(
  missing_enforce_fail_closed.payload.cache.dnsNextCheckAt ~= nil,
  "dnsNextCheckAt must be present even without valid proof"
)

local route_expired_enforce_closed = resolve_route(
  "resolver-it-route-expired-enforce-closed",
  "vddl.fun",
  "/orders",
  "POST",
  "enforce"
)
assert(route_expired_enforce_closed.status == "OK", "expired/enforce route resolve must succeed")
assert(route_expired_enforce_closed.payload.decision == "deny", "expired/enforce route should deny when fail-open false")
assert(
  route_expired_enforce_closed.payload.reasonCode == "DENY_READY_DNS_PROOF_EXPIRED",
  "expired/enforce route reason mismatch"
)

local route_unmapped_enforce_closed =
  resolve_route("resolver-it-route-unmapped-enforce-closed", "unknown.fun", "/shop", "GET", "enforce")
assert(route_unmapped_enforce_closed.status == "OK", "unmapped/enforce route resolve must succeed")
assert(route_unmapped_enforce_closed.payload.decision == "deny", "unmapped/enforce route should deny when fail-open false")
assert(
  route_unmapped_enforce_closed.payload.reasonCode == "DENY_READY_ROUTE_HOST_UNMAPPED",
  "unmapped/enforce route reason mismatch"
)

local debug_state = resolver.route {
  Action = "GetResolverState",
  ["Request-Id"] = "resolver-it-debug-1",
}

assert(debug_state.status == "OK", "debug state should return OK")
assert(debug_state.payload.policyMode == "soft", "policy mode should reflect latest bundle")
assert(debug_state.payload.bundleMeta ~= nil, "bundle meta should be visible in debug summary")
assert(debug_state.payload.counts.routePolicies >= 1, "route policy count should be visible")

if type(ao) == "table" and type(ao.clearOutbox) == "function" then
  ao.clearOutbox()
end

local previous_send = _G.Send
local sent_payloads = {}
_G.Send = function(payload)
  sent_payloads[#sent_payloads + 1] = deep_copy(payload)
  return { output = "Message added to outbox" }
end

local routed_result = _G.handle {
  Action = "GetResolverState",
  ["Request-Id"] = "resolver-it-reply-contract-1",
  ["Reply-To"] = "reply-target-pid",
  Tags = {},
}

_G.Send = previous_send

assert(type(routed_result) == "string", "global handle should still return the emitted JSON string in source-only tests")
assert(routed_result:find('"status"') ~= nil, "global handle result should contain serialized resolver JSON")
assert(#sent_payloads == 1, "resolver handler should emit one reply message when Reply-To is present")
assert(sent_payloads[1].Target == "reply-target-pid", "resolver reply target mismatch")
assert(sent_payloads[1].Action == "Resolver-Command-Result", "resolver reply action mismatch")
assert(sent_payloads[1]["Resolver-Action"] == "GetResolverState", "resolver reply source action mismatch")
assert(sent_payloads[1]["Request-Id"] == "resolver-it-reply-contract-1", "resolver reply request id mismatch")
assert(sent_payloads[1]["Read-Contract-Version"] == "resolver-reply-message.v1", "resolver reply contract version mismatch")
assert(sent_payloads[1]["Content-Type"] == "application/json", "resolver reply content type mismatch")
assert(type(sent_payloads[1].Data) == "string" and sent_payloads[1].Data:find('"status"') ~= nil, "resolver reply data should contain JSON envelope")

print "resolver_process_spec: ok"
