#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKER_IMAGE="${DOCKER_IMAGE:-p3rmaw3b/ao:0.1.5}"
RUNTIME_TEMPLATE="${RUNTIME_TEMPLATE:-registry}"
MIN_INITIAL_MEMORY="${MIN_INITIAL_MEMORY:-8388608}"
MAIN_CHUNK_SENTINEL_ACTION="${MAIN_CHUNK_SENTINEL_ACTION:-}"

docker_bind_path() {
  local path="$1"
  if [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v wslpath >/dev/null 2>&1 && command -v docker.exe >/dev/null 2>&1; then
    wslpath -w "${path}"
  else
    printf '%s' "${path}"
  fi
}

cd "${ROOT_DIR}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

if [[ ! -d "dist/${RUNTIME_TEMPLATE}" ]]; then
  echo "missing dist/${RUNTIME_TEMPLATE}; build baseline runtime first (or set RUNTIME_TEMPLATE)" >&2
  exit 1
fi

if [[ ! -f "dist/${RUNTIME_TEMPLATE}/config.yml" ]]; then
  echo "missing dist/${RUNTIME_TEMPLATE}/config.yml" >&2
  exit 1
fi

echo "[1/4] Building resolver Lua bundle"
node scripts/build-ao-bundles.mjs --target resolver

echo "[2/4] Preparing dist/resolver runtime scaffold from dist/${RUNTIME_TEMPLATE}"
rm -rf dist/resolver
cp -a "dist/${RUNTIME_TEMPLATE}" dist/resolver

echo "[2.1/4] Composing runtime wrapper + resolver bundle"
python3 - <<'PY'
from pathlib import Path
import re
import sys
import os

runtime = Path("dist/resolver/process.lua")
bundle = Path("dist/resolver-bundle.lua")
sentinel_action = os.environ.get("MAIN_CHUNK_SENTINEL_ACTION", "").strip()
ao_result_sentinel = os.environ.get("AO_RESULT_SENTINEL", "").strip()
process_handle_sentinel_action = os.environ.get("PROCESS_HANDLE_SENTINEL_ACTION", "").strip()
preserve_handler_result = os.environ.get("PRESERVE_HANDLER_RESULT", "").strip().lower() in {"1", "true", "yes", "on"}
capture_ao_result_passthrough = os.environ.get("CAPTURE_AO_RESULT_PASSTHROUGH", "").strip().lower() in {"1", "true", "yes", "on"}
trace_resolver_route = os.environ.get("TRACE_RESOLVER_ROUTE", "").strip().lower() in {"1", "true", "yes", "on"}
trace_runtime_path = os.environ.get("TRACE_RUNTIME_PATH", "").strip().lower() in {"1", "true", "yes", "on"}
inline_resolver_route_after_setup = os.environ.get("INLINE_RESOLVER_ROUTE_AFTER_SETUP", "").strip().lower() in {"1", "true", "yes", "on"}
inline_resolver_print_bridge_after_setup = os.environ.get("INLINE_RESOLVER_PRINT_BRIDGE_AFTER_SETUP", "").strip().lower() in {"1", "true", "yes", "on"}
bootstrap_resolver_handler_registration = os.environ.get("BOOTSTRAP_RESOLVER_HANDLER_REGISTRATION", "").strip().lower() in {"1", "true", "yes", "on"}
bootstrap_resolver_evaluate_wrapper = os.environ.get("BOOTSTRAP_RESOLVER_EVALUATE_WRAPPER", "").strip().lower() in {"1", "true", "yes", "on"}
bootstrap_resolver_evaluate_wrapper_after_setup = os.environ.get("BOOTSTRAP_RESOLVER_EVALUATE_WRAPPER_AFTER_SETUP", "").strip().lower() in {"1", "true", "yes", "on"}
direct_resolver_evaluate_bridge_after_setup = os.environ.get("DIRECT_RESOLVER_EVALUATE_BRIDGE_AFTER_SETUP", "").strip().lower() in {"1", "true", "yes", "on"}
disable_resolver_toplevel_wrappers = os.environ.get("DISABLE_RESOLVER_TOPLEVEL_WRAPPERS", "").strip().lower() in {"1", "true", "yes", "on"}
disable_resolver_process_handle_wrap = os.environ.get("DISABLE_RESOLVER_PROCESS_HANDLE_WRAP", "").strip().lower() in {"1", "true", "yes", "on"}
direct_process_handle_wrapper = os.environ.get("DIRECT_PROCESS_HANDLE_WRAPPER", "").strip().lower() in {"1", "true", "yes", "on"}
process_handle_identity_wrapper = os.environ.get("PROCESS_HANDLE_IDENTITY_WRAPPER", "").strip().lower() in {"1", "true", "yes", "on"}
process_handle_reply_echo = os.environ.get("PROCESS_HANDLE_REPLY_ECHO", "").strip().lower() in {"1", "true", "yes", "on"}
process_handle_post_result_message = os.environ.get("PROCESS_HANDLE_POST_RESULT_MESSAGE", "").strip().lower() in {"1", "true", "yes", "on"}

runtime_text = runtime.read_text(encoding="utf-8")
bundle_text = bundle.read_text(encoding="utf-8")

# Keep runtime return intact; strip resolver bundle terminal return so it only
# contributes package.preload chunks.
bundle_text = re.sub(
    r"\nreturn require\(\"ao\.resolver\.process\"\)\s*$",
    "\n",
    bundle_text,
    flags=re.MULTILINE,
)

if disable_resolver_toplevel_wrappers:
    wrapper_stub = (
        "local resolver_handler_registered = false\n"
        "local resolver_evaluate_wrapped = false\n"
        "local original_handlers_evaluate = nil\n"
        "local function resolve_handlers_api()\n"
        "  return nil\n"
        "end\n"
        "local function ensure_resolver_evaluate_wrapped(...)\n"
        "  return false\n"
        "end\n"
        "local function ensure_resolver_handler_registered()\n"
        "  return false\n"
        "end\n"
        "local function fallback_handle(msg)\n"
        "  return nil\n"
        "end\n"
        "if type(_G) == \"table\" then\n"
        "  _G.__dm_resolver_inline_route = function(msg)\n"
        "    return nil\n"
        "  end\n"
        "end\n"
        "local function ensure_resolver_process_handle_wrapped()\n"
        "  return false\n"
        "end\n\n"
        "local function emit_handler_error"
    )
    bundle_text, count = re.subn(
        r"local resolver_handler_registered = false.*?local function emit_handler_error",
        wrapper_stub,
        bundle_text,
        count=1,
        flags=re.S,
    )
    if count != 1:
        print("failed to disable resolver top-level wrappers", file=sys.stderr)
        sys.exit(1)

if disable_resolver_process_handle_wrap:
    process_handle_wrap_stub = (
        "local function ensure_resolver_process_handle_wrapped()\n"
        "  return false\n"
        "end\n\n"
        "if eager_resolver_wrappers_enabled then\n"
        "  ensure_resolver_handler_registered()\n"
        "  ensure_resolver_process_handle_wrapped()\n"
        "end\n\n"
        "local previous_Handle = nil\n"
    )
    bundle_text, count = re.subn(
        r"local function ensure_resolver_process_handle_wrapped\(\).*?local previous_Handle = nil\n",
        process_handle_wrap_stub,
        bundle_text,
        count=1,
        flags=re.S,
    )
    if count != 1:
        print("failed to disable resolver process.handle wrapping", file=sys.stderr)
        sys.exit(1)

marker = "\nreturn process"
idx = runtime_text.rfind(marker)
if idx < 0:
    print(f"runtime wrapper marker not found: {marker!r}", file=sys.stderr)
    sys.exit(1)

# Keep the full AO runtime wrapper (process.handle, scheduler plumbing, etc.).
# Inject resolver preload chunks, require resolver hooks once, then return
# the runtime process table.
injected = (
    "\n-- injected resolver bundle (preload-only)\n"
    + bundle_text
    + "\nif type(_G) == \"table\" then\n"
    + "  _G.__dm_emit_output = function(text)\n"
    + "    if type(print) == \"function\" then\n"
    + "      print(text)\n"
    + "    end\n"
    + "    return text\n"
    + "  end\n"
    + "end\n"
    + "\nlocal __ok_resolver, __err_resolver = pcall(require, \"ao.resolver.process\")\n"
    + "if not __ok_resolver then error(__err_resolver) end\n"
)

if direct_process_handle_wrapper:
    injected += (
        "local function __dm_promote_tags(msg)\n"
        + "  if type(msg) ~= \"table\" then return msg end\n"
        + "  local tags = msg.Tags or msg.tags\n"
        + "  if type(tags) == \"table\" then\n"
        + "    for _, tag in ipairs(tags) do\n"
        + "      if type(tag) == \"table\" then\n"
        + "        local name = tag.name or tag.Name\n"
        + "        local value = tag.value or tag.Value\n"
        + "        if type(name) == \"string\" and msg[name] == nil then\n"
        + "          msg[name] = value\n"
        + "        end\n"
        + "      end\n"
        + "    end\n"
        + "  end\n"
        + "  if msg.Action == nil and msg.action ~= nil then msg.Action = msg.action end\n"
        + "  if msg['Request-Id'] == nil then\n"
        + "    if msg.requestId ~= nil then\n"
        + "      msg['Request-Id'] = msg.requestId\n"
        + "    elseif msg['request-id'] ~= nil then\n"
        + "      msg['Request-Id'] = msg['request-id']\n"
        + "    elseif msg.Id ~= nil then\n"
        + "      msg['Request-Id'] = msg.Id\n"
        + "    end\n"
        + "  end\n"
        + "  if msg.Host == nil and msg.host ~= nil then msg.Host = msg.host end\n"
        + "  if msg.Path == nil and msg.path ~= nil then msg.Path = msg.path end\n"
        + "  if msg.Method == nil and msg.method ~= nil then msg.Method = msg.method end\n"
        + "  return msg\n"
        + "end\n"
        + "if type(process) == \"table\" then\n"
        + "  local __orig_process_handle = process.handle\n"
        + "  process.handle = function(msg)\n"
        + "    msg = __dm_promote_tags(msg)\n"
        + "    if type(normalizeMsg) == \"function\" then pcall(normalizeMsg, msg) end\n"
        + "    if type(__orig_process_handle) == \"function\" then\n"
        + "      local ok_orig, orig_res = pcall(__orig_process_handle, msg)\n"
        + "      if ok_orig and orig_res ~= nil then return orig_res end\n"
        + "    end\n"
        + "    if type(_G.handle) == \"function\" then\n"
        + "      local routed = _G.handle(msg)\n"
        + "      if routed ~= nil then return routed end\n"
        + "    end\n"
        + "    return nil\n"
        + "  end\n"
        + "end\n"
    )

if process_handle_identity_wrapper:
    injected += (
        "if type(process) == \"table\" and type(process.handle) == \"function\" then\n"
        + "  local __dm_orig_identity_process_handle = process.handle\n"
        + "  process.handle = function(msg, env)\n"
        + "    return __dm_orig_identity_process_handle(msg, env)\n"
        + "  end\n"
        + "end\n"
    )

if process_handle_reply_echo or process_handle_post_result_message:
    injected += (
        "local function __dm_find_reply_to(msg, include_from_fallback)\n"
        + "  if type(msg) ~= \"table\" then return nil end\n"
        + "  local target = msg['Reply-To'] or msg['ReplyTo'] or msg.replyTo\n"
        + "  local tags = msg.Tags or msg.tags\n"
        + "  if (target == nil or target == \"\") and type(tags) == \"table\" then\n"
        + "    for _, tag in ipairs(tags) do\n"
        + "      if type(tag) == \"table\" then\n"
        + "        local name = tag.name or tag.Name\n"
        + "        local value = tag.value or tag.Value\n"
        + "        if (name == 'Reply-To' or name == 'ReplyTo') and type(value) == 'string' and value ~= '' then\n"
        + "          target = value\n"
        + "          break\n"
        + "        end\n"
        + "      end\n"
        + "    end\n"
        + "  end\n"
        + "  if (target == nil or target == \"\") and include_from_fallback == true then\n"
        + "    target = msg.From or msg.from\n"
        + "  end\n"
        + "  if type(target) == \"string\" and target ~= \"\" then return target end\n"
        + "  return nil\n"
        + "end\n"
    )

if process_handle_reply_echo:
    injected += (
        "if type(process) == \"table\" and type(process.handle) == \"function\" then\n"
        + "  local __dm_orig_reply_echo_process_handle = process.handle\n"
        + "  process.handle = function(msg, env)\n"
        + "    local __dm_reply_target = __dm_find_reply_to(msg, true)\n"
        + "    if __dm_reply_target ~= nil and type(Send) == \"function\" then\n"
        + "      pcall(Send, {\n"
        + "        Target = __dm_reply_target,\n"
        + "        Action = 'DM-Debug-Reply',\n"
        + "        Data = '{\"status\":\"OK\",\"source\":\"process_handle_reply_echo\"}',\n"
        + "      })\n"
        + "      pcall(function()\n"
        + "        if type(print) == \"function\" then\n"
        + "          print('__DM_PROCESS_HANDLE_REPLY_ECHO__ target=' .. tostring(__dm_reply_target))\n"
        + "        end\n"
        + "      end)\n"
        + "    end\n"
        + "    return __dm_orig_reply_echo_process_handle(msg, env)\n"
        + "  end\n"
        + "end\n"
    )

if process_handle_post_result_message:
    injected += (
        "if type(process) == \"table\" and type(process.handle) == \"function\" then\n"
        + "  local __dm_orig_post_result_process_handle = process.handle\n"
        + "  process.handle = function(msg, env)\n"
        + "    local response = __dm_orig_post_result_process_handle(msg, env)\n"
        + "    local __dm_reply_target = __dm_find_reply_to(msg, false)\n"
        + "    if __dm_reply_target ~= nil and type(response) == \"table\" then\n"
        + "      if type(response.Messages) ~= \"table\" then\n"
        + "        response.Messages = {}\n"
        + "      end\n"
        + "      table.insert(response.Messages, {\n"
        + "        Target = __dm_reply_target,\n"
        + "        Action = 'DM-Debug-Post-Result',\n"
        + "        Data = '{\"status\":\"OK\",\"source\":\"process_handle_post_result_message\"}',\n"
        + "      })\n"
        + "      if type(response.Output) == \"table\" then\n"
        + "        local __dm_existing_output = response.Output.data\n"
        + "        if __dm_existing_output == nil then\n"
        + "          __dm_existing_output = ''\n"
        + "        elseif type(__dm_existing_output) ~= \"string\" then\n"
        + "          __dm_existing_output = tostring(__dm_existing_output)\n"
        + "        end\n"
        + "        if __dm_existing_output == '' then\n"
        + "          response.Output.data = '__DM_PROCESS_HANDLE_POST_RESULT_MESSAGE__'\n"
        + "        else\n"
        + "          response.Output.data = __dm_existing_output .. '\\n__DM_PROCESS_HANDLE_POST_RESULT_MESSAGE__'\n"
        + "        end\n"
        + "      end\n"
        + "    end\n"
        + "    return response\n"
        + "  end\n"
        + "end\n"
    )

if bootstrap_resolver_handler_registration:
    injected += (
        "\nif type(_G) == \"table\" and type(_G.__dm_resolver_inline_route) == \"function\" then\n"
        + "  local __dm_ok_bootstrap, __dm_bootstrap_err = pcall(_G.__dm_resolver_inline_route, {\n"
        + "    Action = \"__DM_BOOTSTRAP_RESOLVER_HANDLER__\",\n"
        + "    Tags = {},\n"
        + "  })\n"
        + "  if not __dm_ok_bootstrap and type(print) == \"function\" then\n"
        + "    print(\"__DM_BOOTSTRAP_RESOLVER_HANDLER_ERROR__ \" .. tostring(__dm_bootstrap_err))\n"
        + "  end\n"
        + "end\n"
    )

if bootstrap_resolver_evaluate_wrapper:
    injected += (
        "\nif type(_G) == \"table\" and type(_G.__dm_bootstrap_resolver_evaluate_wrapper) == \"function\" then\n"
        + "  local __dm_ok_bootstrap_eval, __dm_bootstrap_eval_err = pcall(_G.__dm_bootstrap_resolver_evaluate_wrapper)\n"
        + "  if not __dm_ok_bootstrap_eval and type(print) == \"function\" then\n"
        + "    print(\"__DM_BOOTSTRAP_RESOLVER_EVALUATE_ERROR__ \" .. tostring(__dm_bootstrap_eval_err))\n"
        + "  end\n"
        + "end\n"
    )

if trace_resolver_route:
    injected += (
        "\nif type(_G) == \"table\" then\n"
        + "  _G.__dm_trace_resolver_route = true\n"
        + "end\n"
    )

if trace_runtime_path:
    injected += (
        "\nlocal function __dm_safe_tostring(value)\n"
        + "  if value == nil then return \"nil\" end\n"
        + "  local ok, out = pcall(tostring, value)\n"
        + "  if ok then return out end\n"
        + "  return \"<tostring-error>\"\n"
        + "end\n"
        + "local function __dm_trace_runtime(label, msg, extra)\n"
        + "  local action = nil\n"
        + "  local id = nil\n"
        + "  local data = nil\n"
        + "  if type(msg) == \"table\" then\n"
        + "    action = msg.Action or msg.action\n"
        + "    id = msg.Id or msg.id\n"
        + "    data = msg.Data or msg.data\n"
        + "  end\n"
        + "  local line = \"__DM_TRACE_RUNTIME__ label=\" .. __dm_safe_tostring(label)\n"
        + "    .. \" action=\" .. __dm_safe_tostring(action)\n"
        + "    .. \" id=\" .. __dm_safe_tostring(id)\n"
        + "    .. \" data=\" .. string.sub(__dm_safe_tostring(data), 1, 180)\n"
        + "    .. \" extra=\" .. string.sub(__dm_safe_tostring(extra), 1, 180)\n"
        + "  pcall(function()\n"
        + "    if type(io) == \"table\" and type(io.stderr) == \"table\" and type(io.stderr.write) == \"function\" then\n"
        + "      io.stderr:write(line .. \"\\n\")\n"
        + "    end\n"
        + "  end)\n"
        + "  pcall(function()\n"
        + "    if type(print) == \"function\" then print(line) end\n"
        + "  end)\n"
        + "end\n"
        + "if type(normalizeMsg) == \"function\" then\n"
        + "  local __dm_orig_normalizeMsg = normalizeMsg\n"
        + "  normalizeMsg = function(msg)\n"
        + "    __dm_trace_runtime(\"before_normalizeMsg\", msg)\n"
        + "    local out = __dm_orig_normalizeMsg(msg)\n"
        + "    __dm_trace_runtime(\"after_normalizeMsg\", out)\n"
        + "    return out\n"
        + "  end\n"
        + "end\n"
        + "if type(Handlers) == \"table\" and type(Handlers.evaluate) == \"function\" then\n"
        + "  local __dm_orig_handlers_evaluate = Handlers.evaluate\n"
        + "  Handlers.evaluate = function(msg, env)\n"
        + "    __dm_trace_runtime(\"before_Handlers.evaluate\", msg)\n"
        + "    local result = __dm_orig_handlers_evaluate(msg, env)\n"
        + "    local result_summary = nil\n"
        + "    if type(result) == \"table\" then\n"
        + "      local output = result.Output\n"
        + "      if type(output) == \"table\" then\n"
        + "        output = output.data or output.prompt or \"<table>\"\n"
        + "      end\n"
        + "      result_summary = \"table output=\" .. __dm_safe_tostring(output)\n"
        + "    else\n"
        + "      result_summary = type(result) .. \":\" .. __dm_safe_tostring(result)\n"
        + "    end\n"
        + "    __dm_trace_runtime(\"after_Handlers.evaluate\", msg, result_summary)\n"
        + "    return result\n"
        + "  end\n"
        + "end\n"
        + "if type(process) == \"table\" and type(process.handle) == \"function\" then\n"
        + "  local __dm_orig_runtime_process_handle = process.handle\n"
        + "  process.handle = function(msg, env)\n"
        + "    __dm_trace_runtime(\"before_runtime_process.handle\", msg)\n"
        + "    local result = __dm_orig_runtime_process_handle(msg, env)\n"
        + "    local result_summary = nil\n"
        + "    if type(result) == \"table\" then\n"
        + "      local output = result.Output\n"
        + "      if type(output) == \"table\" then\n"
        + "        output = output.data or output.prompt or \"<table>\"\n"
        + "      end\n"
        + "      result_summary = \"table output=\" .. __dm_safe_tostring(output)\n"
        + "    else\n"
        + "      result_summary = type(result) .. \":\" .. __dm_safe_tostring(result)\n"
        + "    end\n"
        + "    __dm_trace_runtime(\"after_runtime_process.handle\", msg, result_summary)\n"
        + "    return result\n"
        + "  end\n"
        + "end\n"
    )

if ao_result_sentinel:
    injected += (
        "\nlocal __dm_ao_result_sentinel = "
        + repr(ao_result_sentinel)
        + "\n"
        + "if type(ao) == \"table\" and type(ao.result) == \"function\" then\n"
        + "  local __dm_orig_ao_result = ao.result\n"
        + "  ao.result = function(result)\n"
        + "    local payload = {\n"
        + "      data = __dm_ao_result_sentinel,\n"
        + "      prompt = type(Prompt) == \"function\" and Prompt() or nil,\n"
        + "      print = true,\n"
        + "    }\n"
        + "    if type(result) ~= \"table\" then result = {} end\n"
        + "    result.Output = payload\n"
        + "    local out = __dm_orig_ao_result(result)\n"
        + "    if type(out) == \"table\" then out.Output = payload end\n"
        + "    return out\n"
        + "  end\n"
        + "end\n"
    )

if capture_ao_result_passthrough:
    injected += (
        "\nif type(_G) == \"table\" then\n"
        + "  _G.__dm_last_ao_result = nil\n"
        + "end\n"
        + "if type(ao) == \"table\" and type(ao.result) == \"function\" then\n"
        + "  local __dm_orig_capture_ao_result = ao.result\n"
        + "  ao.result = function(result)\n"
        + "    local out = __dm_orig_capture_ao_result(result)\n"
        + "    if type(_G) == \"table\" then\n"
        + "      _G.__dm_last_ao_result = out\n"
        + "    end\n"
        + "    return out\n"
        + "  end\n"
        + "end\n"
    )

if sentinel_action:
    injected += (
        "\nlocal __dm_main_chunk_sentinel_action = "
        + repr(sentinel_action)
        + "\n"
        + "local function __dm_sentinel_probe_msg(msg)\n"
        + "  local probe_msg = msg\n"
        + "  if type(normalizeMsg) == \"function\" then\n"
        + "    local ok_norm, norm = pcall(normalizeMsg, msg)\n"
        + "    if ok_norm and type(norm) == \"table\" then probe_msg = norm end\n"
        + "  end\n"
        + "  return probe_msg\n"
        + "end\n"
        + "local function __dm_matches_main_chunk_sentinel(msg)\n"
        + "  local probe_msg = __dm_sentinel_probe_msg(msg)\n"
        + "  if type(probe_msg) ~= \"table\" then return false end\n"
        + "  local action = probe_msg.Action or probe_msg.action\n"
        + "  return action == __dm_main_chunk_sentinel_action\n"
        + "end\n"
        + "local function __dm_main_chunk_sentinel_response()\n"
        + "  local payload = {\n"
        + "    status = \"OK\",\n"
        + "    payload = {\n"
        + "      sentinel = \"main_chunk\",\n"
        + "      action = __dm_main_chunk_sentinel_action,\n"
        + "      source = \"runtime_wrapper\",\n"
        + "    },\n"
        + "  }\n"
        + "  local text = json.encode(payload)\n"
        + "  if type(print) == \"function\" then print(text) end\n"
        + "  if type(ao) == \"table\" and type(ao.result) == \"function\" then\n"
        + "    return ao.result({ Output = payload, Messages = {}, Spawns = {}, Assignments = {} })\n"
        + "  end\n"
        + "  return payload\n"
        + "end\n"
        + "if type(_G) == \"table\" then\n"
        + "  local __dm_orig_global_handle = _G.handle\n"
        + "  local __dm_orig_global_Handle = _G.Handle\n"
        + "  _G.handle = function(msg)\n"
        + "    if __dm_matches_main_chunk_sentinel(msg) then\n"
        + "      return __dm_main_chunk_sentinel_response()\n"
        + "    end\n"
        + "    if type(__dm_orig_global_handle) == \"function\" then\n"
        + "      return __dm_orig_global_handle(msg)\n"
        + "    end\n"
        + "    if type(__dm_orig_global_Handle) == \"function\" then\n"
        + "      return __dm_orig_global_Handle(msg)\n"
        + "    end\n"
        + "    return nil\n"
        + "  end\n"
        + "  _G.Handle = function(msg)\n"
        + "    if __dm_matches_main_chunk_sentinel(msg) then\n"
        + "      return __dm_main_chunk_sentinel_response()\n"
        + "    end\n"
        + "    if type(__dm_orig_global_Handle) == \"function\" then\n"
        + "      return __dm_orig_global_Handle(msg)\n"
        + "    end\n"
        + "    if type(__dm_orig_global_handle) == \"function\" then\n"
        + "      return __dm_orig_global_handle(msg)\n"
        + "    end\n"
        + "    return nil\n"
        + "  end\n"
        + "  if type(_G.Handlers) == \"table\" then\n"
        + "    _G.Handlers.handle = function(msg)\n"
        + "      return _G.handle(msg)\n"
        + "    end\n"
        + "  end\n"
        + "end\n"
        + "if type(process) == \"table\" and type(process.handle) == \"function\" then\n"
        + "  local __dm_orig_process_handle = process.handle\n"
        + "  process.handle = function(msg, env)\n"
        + "    if __dm_matches_main_chunk_sentinel(msg) then\n"
        + "      return __dm_main_chunk_sentinel_response()\n"
        + "    end\n"
        + "    return __dm_orig_process_handle(msg, env)\n"
        + "  end\n"
        + "end\n"
    )
composed = runtime_text[:idx] + injected + runtime_text[idx:]

if process_handle_sentinel_action:
    sentinel_patch = (
        "  ao.clearOutbox()\\n"
        "  if type(msg) == \\\"table\\\" then\\n"
        "    local __dm_process_handle_action = msg.Action or msg.action\\n"
        "    if __dm_process_handle_action == "
        + repr(process_handle_sentinel_action)
        + " then\\n"
        "      if type(print) == \\\"function\\\" then print(\\\"__DM_PROCESS_HANDLE_SENTINEL__\\\") end\\n"
        "    end\\n"
        "  end"
    )
    composed, count = re.subn(
        r"  ao\.clearOutbox\(\)",
        sentinel_patch,
        composed,
        count=1,
    )
    if count != 1:
        print("failed to inject process.handle sentinel after ao.clearOutbox()", file=sys.stderr)
        sys.exit(1)

if preserve_handler_result:
    preserve_patch = (
        "  if type(result) == \"table\" then\\n"
        "    local __dm_has_structured_result = result.Output ~= nil or result.Messages ~= nil or result.Spawns ~= nil or result.Assignments ~= nil or result.Error ~= nil\\n"
        "    if __dm_has_structured_result then\\n"
        "      if result.Output == nil and #HANDLER_PRINT_LOGS > 0 then\\n"
        "        result.Output = { data = table.concat(HANDLER_PRINT_LOGS, \"\\\\n\"), prompt = Prompt(), print = true }\\n"
        "      end\\n"
        "      HANDLER_PRINT_LOGS = {}\\n"
        "      ao.Nonce = msg.Nonce\\n"
        "      return result\\n"
        "    end\\n"
        "  end\\n\\n"
        "  if msg.Action == \"Eval\" then"
    )
    composed, count = re.subn(
        r'  if msg\.Action == "Eval" then',
        preserve_patch,
        composed,
        count=1,
    )
    if count != 1:
        print("failed to inject preserve-handler-result success path", file=sys.stderr)
        sys.exit(1)

if capture_ao_result_passthrough:
    captured_result_patch = (
        "  local __dm_captured_ao_result = nil\\n"
        "  if type(_G) == \\\"table\\\" then\\n"
        "    __dm_captured_ao_result = _G.__dm_last_ao_result\\n"
        "    _G.__dm_last_ao_result = nil\\n"
        "  end\\n"
        "  if type(__dm_captured_ao_result) == \\\"table\\\" then\\n"
        "    if __dm_captured_ao_result.Output == nil and #HANDLER_PRINT_LOGS > 0 then\\n"
        "      __dm_captured_ao_result.Output = { data = table.concat(HANDLER_PRINT_LOGS, \\\"\\\\n\\\"), prompt = Prompt(), print = true }\\n"
        "    end\\n"
        "    HANDLER_PRINT_LOGS = {}\\n"
        "    ao.Nonce = msg.Nonce\\n"
        "    return __dm_captured_ao_result\\n"
        "  end\\n\\n"
        "  if msg.Action == \\\"Eval\\\" then"
    )
    composed, count = re.subn(
        r'  if msg\.Action == "Eval" then',
        captured_result_patch,
        composed,
        count=1,
    )
    if count != 1:
        print("failed to inject captured-ao-result success path", file=sys.stderr)
        sys.exit(1)

if inline_resolver_route_after_setup:
    inline_route_patch = (
        "  if type(_G) == \"table\" and type(_G.__dm_resolver_inline_route) == \"function\" then\\n"
        "    local __dm_inline_routed = _G.__dm_resolver_inline_route(msg)\\n"
        "    if __dm_inline_routed ~= nil then\\n"
        "      return __dm_inline_routed\\n"
        "    end\\n"
        "  end\\n\\n"
        "  local co = coroutine.create("
    )
    composed, count = re.subn(
        r'  local co = coroutine\.create\(',
        inline_route_patch,
        composed,
        count=1,
    )
    if count != 1:
        print("failed to inject inline resolver route after runtime setup", file=sys.stderr)
        sys.exit(1)

if bootstrap_resolver_evaluate_wrapper_after_setup:
    bootstrap_eval_patch = (
        "  local function __dm_bootstrap_eval_log(line)\\n"
        "    pcall(function()\\n"
        "      if type(io) == \"table\" and type(io.stderr) == \"table\" and type(io.stderr.write) == \"function\" then\\n"
        "        io.stderr:write(line .. \"\\\\n\")\\n"
        "      end\\n"
        "    end)\\n"
        "  end\\n"
        "  if type(_G) == \"table\"\\n"
        "    and _G.__dm_resolver_evaluate_bootstrapped ~= true\\n"
        "    and type(_G.__dm_bootstrap_resolver_evaluate_wrapper) == \"function\"\\n"
        "  then\\n"
        "    local __dm_bootstrap_eval_ok, __dm_bootstrap_eval_result = pcall(_G.__dm_bootstrap_resolver_evaluate_wrapper)\\n"
        "    if __dm_bootstrap_eval_ok and __dm_bootstrap_eval_result == true then\\n"
        "      _G.__dm_resolver_evaluate_bootstrapped = true\\n"
        "      __dm_bootstrap_eval_log(\"__DM_BOOTSTRAP_RESOLVER_EVALUATE_AFTER_SETUP_OK__\")\\n"
        "    elseif __dm_bootstrap_eval_ok then\\n"
        "      __dm_bootstrap_eval_log(\"__DM_BOOTSTRAP_RESOLVER_EVALUATE_AFTER_SETUP_FALSE__ \" .. tostring(__dm_bootstrap_eval_result))\\n"
        "    elseif not __dm_bootstrap_eval_ok then\\n"
        "      __dm_bootstrap_eval_log(\"__DM_BOOTSTRAP_RESOLVER_EVALUATE_AFTER_SETUP_ERROR__ \" .. tostring(__dm_bootstrap_eval_result))\\n"
        "    end\\n"
        "  end\\n\\n"
        "  local co = coroutine.create("
    )
    composed, count = re.subn(
        r'  local co = coroutine\.create\(',
        bootstrap_eval_patch,
        composed,
        count=1,
    )
    if count != 1:
        print("failed to inject bootstrap-resolver-evaluate-wrapper after runtime setup", file=sys.stderr)
        sys.exit(1)

if direct_resolver_evaluate_bridge_after_setup:
    direct_bridge_patch = (
        "  local function __dm_direct_bridge_log(line)\\n"
        "    pcall(function()\\n"
        "      if type(io) == \"table\" and type(io.stderr) == \"table\" and type(io.stderr.write) == \"function\" then\\n"
        "        io.stderr:write(line .. \"\\\\n\")\\n"
        "      end\\n"
        "    end)\\n"
        "    pcall(function()\\n"
        "      if type(print) == \"function\" then\\n"
        "        print(line)\\n"
        "      end\\n"
        "    end)\\n"
        "  end\\n"
        "  if type(_G) == \"table\"\\n"
        "    and _G.__dm_resolver_direct_bridge_bootstrapped ~= true\\n"
        "    and type(Handlers) == \"table\"\\n"
        "    and type(Handlers.evaluate) == \"function\"\\n"
        "    and type(_G.__dm_resolver_handle_action) == \"function\"\\n"
        "  then\\n"
        "    local __dm_orig_handlers_evaluate = Handlers.evaluate\\n"
        "    Handlers.evaluate = function(msg, env)\\n"
        "      local __dm_action = nil\\n"
        "      if type(msg) == \"table\" then\\n"
        "        __dm_action = msg.Action or msg.action\\n"
        "      end\\n"
        "      __dm_direct_bridge_log(\"__DM_DIRECT_RESOLVER_EVALUATE_BRIDGE_PRE__ action=\" .. tostring(__dm_action))\\n"
        "      local __dm_routed = _G.__dm_resolver_handle_action(msg)\\n"
        "      if __dm_routed ~= nil then\\n"
        "        __dm_direct_bridge_log(\"__DM_DIRECT_RESOLVER_EVALUATE_BRIDGE_HIT__\")\\n"
        "        return __dm_routed\\n"
        "      end\\n"
        "      __dm_direct_bridge_log(\"__DM_DIRECT_RESOLVER_EVALUATE_BRIDGE_MISS__ action=\" .. tostring(__dm_action))\\n"
        "      return __dm_orig_handlers_evaluate(msg, env)\\n"
        "    end\\n"
        "    _G.__dm_resolver_direct_bridge_bootstrapped = true\\n"
        "    __dm_direct_bridge_log(\"__DM_DIRECT_RESOLVER_EVALUATE_BRIDGE_OK__\")\\n"
        "  end\\n\\n"
        "  local co = coroutine.create("
    )
    composed, count = re.subn(
        r'  local co = coroutine\.create\(',
        direct_bridge_patch,
        composed,
        count=1,
    )
    if count != 1:
        print("failed to inject direct resolver evaluate bridge after runtime setup", file=sys.stderr)
        sys.exit(1)

if inline_resolver_print_bridge_after_setup:
    inline_print_bridge_patch = (
        "  local __dm_inline_bridge_output = nil\\n"
        "  if type(_G) == \"table\" and type(_G.__dm_resolver_inline_route) == \"function\" then\\n"
        "    local __dm_inline_routed = _G.__dm_resolver_inline_route(msg)\\n"
        "    if type(__dm_inline_routed) == \"table\" and type(__dm_inline_routed.Output) == \"table\" then\\n"
        "      __dm_inline_bridge_output = __dm_inline_routed.Output.data\\n"
        "    elseif type(__dm_inline_routed) == \"string\" then\\n"
        "      __dm_inline_bridge_output = __dm_inline_routed\\n"
        "    end\\n"
        "    if __dm_inline_bridge_output ~= nil then\\n"
        "      HANDLER_PRINT_LOGS = HANDLER_PRINT_LOGS or {}\\n"
        "      table.insert(HANDLER_PRINT_LOGS, tostring(__dm_inline_bridge_output))\\n"
        "    end\\n"
        "  end\\n\\n"
        "  local co = coroutine.create(\\n"
        "    function()\\n"
        "      if __dm_inline_bridge_output ~= nil then\\n"
        "        return true, true\\n"
        "      end\\n"
        "      return pcall(Handlers.evaluate, msg, env)\\n"
        "    end\\n"
        "  )"
    )
    composed, count = re.subn(
        r'  local co = coroutine\.create\(\n    function\(\)\n      return pcall\(Handlers\.evaluate, msg, env\)\n    end\n  \)',
        inline_print_bridge_patch,
        composed,
        count=1,
    )
    if count != 1:
        print("failed to inject inline resolver print bridge after runtime setup", file=sys.stderr)
        sys.exit(1)

runtime.write_text(composed, encoding="utf-8")

if 'function process.handle' not in composed:
    print("composed runtime is missing process.handle", file=sys.stderr)
    sys.exit(1)
if 'package.preload["ao.resolver.process"]' not in composed:
    print("composed runtime is missing resolver preload", file=sys.stderr)
    sys.exit(1)
if 'pcall(require, "ao.resolver.process")' not in composed:
    print("composed runtime is missing resolver require hook", file=sys.stderr)
    sys.exit(1)
if "\nreturn process" not in composed:
    print("composed runtime is missing final return process", file=sys.stderr)
    sys.exit(1)
print("runtime composition ok")
PY

echo "[3/4] Ensuring resolver config has safe initial_memory"
python3 - <<'PY'
from pathlib import Path
import os
import re
import sys

cfg = Path("dist/resolver/config.yml")
text = cfg.read_text(encoding="utf-8")
minimum = int(os.environ.get("MIN_INITIAL_MEMORY", "8388608"))
match = re.search(r"^initial_memory:\s*(\d+)\s*$", text, flags=re.MULTILINE)
if not match:
    print("config.yml does not contain initial_memory", file=sys.stderr)
    sys.exit(1)
current = int(match.group(1))
if current < minimum:
    text = re.sub(r"^initial_memory:\s*\d+\s*$", f"initial_memory: {minimum}", text, flags=re.MULTILINE)
    cfg.write_text(text, encoding="utf-8")
    print(f"initial_memory raised {current} -> {minimum}")
else:
    print(f"initial_memory kept at {current}")
PY

echo "[4/4] Building resolver WASM via Docker"
RESOLVER_DIST_ABS="$(cd dist/resolver && pwd)"
docker run \
  --platform linux/amd64 \
  -e MIN_INITIAL_MEMORY="${MIN_INITIAL_MEMORY}" \
  -v "$(docker_bind_path "${RESOLVER_DIST_ABS}"):/src" \
  "${DOCKER_IMAGE}" \
  ao-build-module

if [[ ! -f "dist/resolver/process.wasm" ]]; then
  echo "resolver wasm build failed: dist/resolver/process.wasm missing" >&2
  exit 1
fi

echo "Done: dist/resolver/process.wasm"
