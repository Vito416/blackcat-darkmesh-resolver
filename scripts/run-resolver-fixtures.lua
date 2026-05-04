-- Fixture runner for darkmesh-resolver@1.0 addon.
-- Usage:
--   lua scripts/run-resolver-fixtures.lua \
--     [ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua] \
--     [ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua]

local resolver_path = arg[1] or "ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua"
local fixtures_path = arg[2] or "ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua"
local FIXTURE_COMPAT_ALLOW_BUNDLE_WRITES =
  (os.getenv("RESOLVER_FIXTURE_COMPAT_ALLOW_BUNDLE_WRITES") or "1") == "1"
local FIXTURE_COMPAT_ALLOW_DIRECT_PROOF_APPLY =
  (os.getenv("RESOLVER_FIXTURE_COMPAT_ALLOW_DIRECT_PROOF_APPLY") or "1") == "1"
local FIXTURE_COMPAT_ALLOW_PUBLIC_REFRESH_QUEUE =
  (os.getenv("RESOLVER_FIXTURE_COMPAT_ALLOW_PUBLIC_REFRESH_QUEUE") or "1") == "1"
local FIXTURE_COMPAT_BYPASS_ROLE_GATES =
  (os.getenv("RESOLVER_FIXTURE_COMPAT_BYPASS_ROLE_GATES") or "1") == "1"

local function file_exists(path)
  local handle = io.open(path, "r")
  if handle ~= nil then
    handle:close()
    return true
  end
  return false
end

local function shallow_contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] ~= nil then
    return seen[value]
  end
  local out = {}
  seen[value] = out
  for key, item in pairs(value) do
    out[deep_copy(key, seen)] = deep_copy(item, seen)
  end
  return out
end

local function deep_equal(left, right, seen)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end

  seen = seen or {}
  local pair_key = tostring(left) .. "|" .. tostring(right)
  if seen[pair_key] then
    return true
  end
  seen[pair_key] = true

  for key, value in pairs(left) do
    if not deep_equal(value, right[key], seen) then
      return false
    end
  end
  for key, _ in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function dump(value, depth)
  depth = depth or 0
  local value_type = type(value)
  if value_type == "string" then
    return string.format("%q", value)
  end
  if value_type ~= "table" then
    return tostring(value)
  end
  if depth > 3 then
    return "{...}"
  end

  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = "[" .. dump(key, depth + 1) .. "]=" .. dump(item, depth + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function get_path(value, dotted_path)
  local current = value
  for token in string.gmatch(dotted_path, "[^.]+") do
    if type(current) ~= "table" then
      return nil
    end
    local numeric_token = tonumber(token)
    if numeric_token ~= nil and current[numeric_token] ~= nil then
      current = current[numeric_token]
    else
      current = current[token]
    end
  end
  return current
end

local function fail(message)
  error(message, 0)
end

local function clear_loaded_modules()
  package.loaded["ao.shared.codec"] = nil
  package.loaded["ao.shared.validation"] = nil
  package.loaded["ao.shared.auth"] = nil
  package.loaded["ao.shared.idempotency"] = nil
  package.loaded["ao.shared.metrics"] = nil
  package.loaded["ao.shared.persist"] = nil
end

local function install_preloads(runtime)
  package.preload["ao.shared.codec"] = function()
    local codec = {}

    function codec.ok(payload)
      return { status = "OK", payload = payload }
    end

    function codec.error(code, message, payload)
      return {
        status = "ERROR",
        code = code,
        message = message,
        payload = payload,
      }
    end

    function codec.missing_tags(missing)
      return codec.error("MISSING_TAGS", "Missing tags", { missing = missing })
    end

    function codec.unknown_action(action)
      return codec.error("UNKNOWN_ACTION", "Unknown action", { action = action })
    end

    return codec
  end

  package.preload["ao.shared.validation"] = function()
    local validation = {}

    local function required_from(msg, fields)
      local missing = {}
      for _, field in ipairs(fields or {}) do
        local value = msg[field]
        if value == nil or value == "" then
          missing[#missing + 1] = field
        end
      end
      if #missing > 0 then
        return false, missing
      end
      return true
    end

    function validation.require_tags(msg, tags)
      return required_from(msg, tags)
    end

    function validation.require_fields(msg, fields)
      return required_from(msg, fields)
    end

    function validation.require_no_extras(msg, allowed)
      local allow = {}
      for _, key in ipairs(allowed or {}) do
        allow[key] = true
      end
      local extras = {}
      for key, _ in pairs(msg or {}) do
        if not allow[key] then
          extras[#extras + 1] = key
        end
      end
      table.sort(extras)
      if #extras > 0 then
        return false, extras
      end
      return true
    end

    function validation.require_action(msg, allowed_actions)
      if msg.Action == nil or msg.Action == "" then
        return false, "missing_action"
      end
      if shallow_contains(allowed_actions, msg.Action) then
        return true
      end
      return false, "unknown_action"
    end

    function validation.check_length(value, max_length, field_name)
      local text = tostring(value or "")
      if #text > tonumber(max_length or 0) then
        return false, "too_long:" .. tostring(field_name or "field")
      end
      return true
    end

    return validation
  end

  package.preload["ao.shared.auth"] = function()
    local auth = {}

    function auth.enforce(_msg)
      return true
    end

    function auth.check_rate_limit(_msg)
      return true
    end

    function auth.verify_outbox_hmac_for_action(_msg, _opts)
      return true
    end

    function auth.require_role_for_action(msg, role_policy)
      local allowed = role_policy and role_policy[msg.Action]
      if allowed == nil then
        return true
      end
      local actor_role = msg["Actor-Role"] or msg.actorRole
      if (actor_role == nil or actor_role == "") and FIXTURE_COMPAT_BYPASS_ROLE_GATES then
        return true
      end
      if actor_role == nil then
        return false, "missing_actor_role"
      end
      if shallow_contains(allowed, actor_role) then
        return true
      end
      return false, "forbidden_actor_role"
    end

    return auth
  end

  package.preload["ao.shared.idempotency"] = function()
    local idempotency = {}

    function idempotency.check(key)
      return runtime.idempotency_store[key]
    end

    function idempotency.record(key, response)
      runtime.idempotency_store[key] = response
      return true
    end

    return idempotency
  end

  package.preload["ao.shared.metrics"] = function()
    local metrics = {}

    function metrics.inc(_name)
      return true
    end

    function metrics.tick()
      return true
    end

    function metrics.gauge(_name, _value)
      return true
    end

    return metrics
  end

  package.preload["ao.shared.persist"] = function()
    local persist = {}

    function persist.load(namespace, default_value)
      if runtime.persist_store[namespace] == nil then
        runtime.persist_store[namespace] = deep_copy(default_value)
      end
      return runtime.persist_store[namespace]
    end

    function persist.save(namespace, value)
      runtime.persist_store[namespace] = deep_copy(value)
      return true
    end

    return persist
  end
end

local function new_resolver_instance(scenario_env)
  local runtime = {
    persist_store = {},
    idempotency_store = {},
  }
  install_preloads(runtime)
  clear_loaded_modules()
  local original_getenv = os.getenv
  if FIXTURE_COMPAT_ALLOW_BUNDLE_WRITES or type(scenario_env) == "table" then
    os.getenv = function(name)
      if type(scenario_env) == "table" and scenario_env[name] ~= nil then
        return tostring(scenario_env[name])
      end
      if name == "RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES" then
        return "1"
      end
      if name == "RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY" and FIXTURE_COMPAT_ALLOW_DIRECT_PROOF_APPLY then
        return "1"
      end
      if name == "RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE" and FIXTURE_COMPAT_ALLOW_PUBLIC_REFRESH_QUEUE then
        return "1"
      end
      return original_getenv(name)
    end
  end

  local ok, resolver_or_err = pcall(dofile, resolver_path)
  os.getenv = original_getenv
  if not ok then
    fail("resolver file load failed: " .. tostring(resolver_or_err))
  end
  local resolver = resolver_or_err
  if type(resolver) ~= "table" or type(resolver.route) ~= "function" then
    fail("resolver module did not return a route handler")
  end
  return resolver
end

local function assert_expectation(actual, expected, scenario_name, step_index, key)
  if not deep_equal(actual, expected) then
    fail(
      string.format(
        "fixture failed: scenario=%s step=%d key=%s expected=%s actual=%s",
        scenario_name,
        step_index,
        key,
        dump(expected),
        dump(actual)
      )
    )
  end
end

local function run_fixtures()
  if not file_exists(resolver_path) then
    fail("resolver file not found: " .. resolver_path)
  end
  if not file_exists(fixtures_path) then
    fail("fixtures file not found: " .. fixtures_path)
  end

  local fixtures = dofile(fixtures_path)
  if type(fixtures) ~= "table" then
    fail("fixtures file did not return a table")
  end

  local scenario_count = 0
  local step_count = 0

  for _, scenario in ipairs(fixtures) do
    scenario_count = scenario_count + 1
    local name = scenario.name or ("scenario-" .. tostring(scenario_count))
    local resolver = new_resolver_instance(scenario.env)

    if type(scenario.steps) ~= "table" then
      fail("fixture scenario missing steps: " .. tostring(name))
    end

    for step_index, step in ipairs(scenario.steps) do
      step_count = step_count + 1
      if type(step.msg) ~= "table" then
        fail(string.format("fixture step missing msg: scenario=%s step=%d", name, step_index))
      end
      local response = resolver.route(deep_copy(step.msg))
      if type(step.expect) == "table" then
        for key, expected in pairs(step.expect) do
          local actual
          if string.find(key, ".", 1, true) then
            actual = get_path(response, key)
          else
            actual = response[key]
          end
          assert_expectation(actual, expected, name, step_index, key)
        end
      end
    end
  end

  print(string.format("resolver-fixtures: OK (%d scenarios, %d steps)", scenario_count, step_count))
end

local ok, err = pcall(run_fixtures)
if not ok then
  io.stderr:write("resolver-fixtures: FAIL\n")
  io.stderr:write(tostring(err) .. "\n")
  os.exit(1)
end
