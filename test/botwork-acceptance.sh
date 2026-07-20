#!/usr/bin/env bash
# smoke/vm-narrative.sh — Comprehensive outside-contract smoke test against a deployed VM.
#
# Asserts the full external contract of the botwork stack: auth enforcement,
# tenant scoping, MCP plugin round-trips, secret allow-consumer boundaries,
# config-injection end-to-end, cross-tenant isolation, and logout/revocation.
# All assertions are exercised from outside the VM through the public edge.
#
# This script is intentionally aspirational: failures are concrete to-do items,
# not reasons to add skip flags or "if not deployed, pass" escape hatches.
#
# Phases:
#   Phase 0  — health reachable + auth-broker enforces (body-shape discriminated).
#              No credentials required; CI-safe immediately after cloud-init.
#   Phase 1  — OPAQUE register + login as smoketest tenant; bearer capture.
#   Phase 2  — list workspaces for smoketest; assert smoke workspace present.
#   Phase 3  — full plugin exec matrix (echo/exec-bash/exec-jq/exec-node/exec-python/
#              fetch/fs/git) + echo BOTWORK_MCP_CONFIG config-injection assertion +
#              five-secret allow-consumer boundary matrix (present/blocked + digest) +
#              cross-plugin workspace file sharing.
#   Phase 4  — cross-tenant negatives.
#   Phase 5  — logout invalidates the bearer.
#
# Usage: bash smoke/vm-narrative.sh <host>
#   <host>  VM hostname or IP address.  The script probes http://<host>/...
#           Use 127.0.0.1 when running from the botforge harness via port-forward.
#   Optional env:
#     SMOKE_BASE_URL      override base URL (default: http://<host>)
#     SMOKE_GH_TOKEN_FILE path to a GitHub PAT file for github.com/pat secret deposit
#     TENANT              tenant name (default: smoketest)
#     WORKSPACE           workspace name (default: smoke)
#
# On failure the script exits non-zero and prints the request URL, HTTP
# status, and up to 1 KB of the response body.
set -euo pipefail

HOST=${HOST:-127.0.0.1}

BASE_URL="${SMOKE_BASE_URL:-http://${HOST}}"

CURL=(curl --silent --show-error --max-time 10)

# ── Logging helpers ───────────────────────────────────────────────────────────
fail() {
  local msg="$1" url="$2" status="$3" body="$4"
  echo "[vm-narrative] FAIL: ${msg}" >&2
  echo "  URL:    ${url}" >&2
  echo "  Status: ${status}" >&2
  echo "  Body:   ${body:0:1024}" >&2
  exit 1
}

die() {
  echo "[vm-narrative] FATAL: ${*}" >&2
  exit 1
}

log_info() { echo "[vm-narrative] ${*}" >&2; }
log_warn()  { echo "[vm-narrative] WARN: ${*}" >&2; }

# ── Locate bw binary ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOGIN_BIN="${BOTWORK_LOGIN_BIN:-${REPO_ROOT}/build/bin/bw/bw}"

# ── Tenant / workspace constants ─────────────────────────────────────────────
TENANT="${TENANT:-testuser}"
WORKSPACE="${WORKSPACE:-testws}"

# ── Auth state ───────────────────────────────────────────────────────────────
PASSWORD="$(python3 - <<'PY'
import uuid
print(uuid.uuid4().hex)
PY
)"

# ── MCP transport ─────────────────────────────────────────────────────────────
MCP_ACCEPT_HEADER="application/json, text/event-stream"
MCP_STREAM_READ_TIMEOUT_SECONDS="${MCP_STREAM_READ_TIMEOUT_SECONDS:-5}"
NEXT_ID=1
LAST_HEADERS=""
LAST_BODY=""
LAST_STATUS=""
LAST_ERROR=""
AGENT_SESSION_ID="vm-narrative-$(python3 - <<'PY'
import uuid
print(uuid.uuid4().hex)
PY
)"
SHARED_RELATIVE_PATH="shared/smoke.txt"
SHARED_ABSOLUTE_PATH="/workspace/${SHARED_RELATIVE_PATH}"
SHARED_CONTENT="shared workspace smoke ${AGENT_SESSION_ID}"
GIT_REPO_ABSOLUTE_PATH="/workspace/git-smoke"
GIT_FILE_CONTENT="git smoke ${AGENT_SESSION_ID}"

declare -A SESSION_BY_PLUGIN=()
for plugin in ${PLUGIN_KEYS:-}; do
    ref="PLUGIN_SESSION_${plugin//-/_}"
    SESSION_BY_PLUGIN[$plugin]="${!ref}"
done

declare -A TOOLS_JSON_BY_PLUGIN=()

# ── Secret provisioning state ────────────────────────────────────────────────
WORK_DIR="$(mktemp -d /tmp/vm-narrative.XXXXXX)"
GITHUB_PAT_FILE="${WORK_DIR}/github-pat.txt"
PROBE_ONLY_FILE="${WORK_DIR}/probe-only-secret.txt"
JQ_ONLY_FILE="${WORK_DIR}/jq-only-secret.txt"
SHARED_FILE="${WORK_DIR}/shared-secret.txt"
UNRESTRICTED_FILE="${WORK_DIR}/unrestricted-secret.txt"
GITHUB_PAT_SHA256=""
PROBE_ONLY_SHA256=""
SHARED_SHA256=""

AUTH_READY_ATTEMPTS="${AUTH_READY_ATTEMPTS:-30}"
AUTH_READY_SLEEP_SECONDS="${AUTH_READY_SLEEP_SECONDS:-2}"

# ── MCP infrastructure ────────────────────────────────────────────────────────

# Build the URL for a plugin. mcp-secrets-probe has path: /mcp in the plugin
# definition and is addressed at /<tenant>/<workspace>/mcp-secrets-probe/mcp;
# all other plugins are addressed at /<tenant>/<workspace>/<plugin>.
plugin_url() {
  local plugin="$1"
  if [[ "${plugin}" == "mcp-secrets-probe" ]]; then
    printf '%s/%s/%s/%s/mcp' "${BASE_URL}" "${TENANT}" "${WORKSPACE}" "${plugin}"
  else
    printf '%s/%s/%s/%s' "${BASE_URL}" "${TENANT}" "${WORKSPACE}" "${plugin}"
  fi
}

# Rewrite LAST_BODY in place: if the body is an SSE stream, unwrap the JSON-RPC
# object matching expected_id from the data: lines. A body that is already bare
# JSON with a matching id is left untouched.
normalize_response_body() {
  local expected_id="$1"
  python3 - "${LAST_BODY}" "${expected_id}" <<'PY'
import json
import sys

path, expected_id = sys.argv[1:3]
try:
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
except OSError:
    sys.exit(1)

stripped = raw.lstrip()
# Already a JSON document: keep it only when it matches the request id.
if stripped[:1] == "{":
    try:
        payload = json.loads(raw)
        if (
            isinstance(payload, dict)
            and payload.get("jsonrpc")
            and str(payload.get("id")) == expected_id
        ):
            sys.exit(0)
    except json.JSONDecodeError:
        pass

# Parse as an SSE stream: split into events on blank lines, concatenate the
# "data:" lines of each event, and pick the first JSON-RPC object whose id
# matches the request id.
chosen = ""
for block in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n\n"):
    data = "\n".join(
        line[len("data:"):].lstrip()
        for line in block.split("\n")
        if line.startswith("data:")
    )
    if not data.strip():
        continue
    try:
        obj = json.loads(data)
    except json.JSONDecodeError:
        continue
    if (
        isinstance(obj, dict)
        and obj.get("jsonrpc")
        and str(obj.get("id")) == expected_id
    ):
        chosen = data
        break

if chosen:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(chosen)
    sys.exit(0)
sys.exit(1)
PY
}

rpc_post() {
  local plugin="$1"
  local session_id="$2"
  local request_body="$3"
  local request_id="${NEXT_ID}"
  local -a curl_args

  LAST_ERROR=""
  LAST_HEADERS="${WORK_DIR}/headers-${request_id}.txt"
  LAST_BODY="${WORK_DIR}/body-${request_id}.json"
  NEXT_ID=$((NEXT_ID + 1))

  curl_args=(
    "${CURL[@]}"
    -D "${LAST_HEADERS}"
    -o "${LAST_BODY}"
    -w '%{http_code}'
    -X POST
    "$(plugin_url "${plugin}")"
    -H "Authorization: Bearer ${BEARER}"
    -H 'Content-Type: application/json'
    -H "Accept: ${MCP_ACCEPT_HEADER}"
    --data-binary "${request_body}"
  )
  if [[ -n "${session_id}" ]]; then
    curl_args+=(-H "Mcp-Session-Id: ${session_id}")
  fi

  if ! LAST_STATUS="$("${curl_args[@]}")"; then
    LAST_ERROR="curl failed for plugin ${plugin}"
    if [[ -f "${LAST_BODY}" ]]; then
      cat "${LAST_BODY}" >&2
    fi
    return 1
  fi

  if normalize_response_body "${request_id}"; then
    return 0
  fi

  # Some MCP servers deliver responses asynchronously on the session SSE channel.
  if [[ "${LAST_STATUS}" == "200" ]]; then
    local stream_session_id="${session_id}"
    local stream_body stream_error stream_status
    local -a stream_curl_args
    if [[ -z "${stream_session_id}" ]]; then
      stream_session_id="$(response_header 'Mcp-Session-Id')"
    fi
    if [[ -n "${stream_session_id}" ]]; then
      stream_body="${WORK_DIR}/body-${request_id}-stream.raw"
      stream_error="${WORK_DIR}/body-${request_id}-stream.err"
      stream_curl_args=(
        "${CURL[@]}" -N
        --max-time "${MCP_STREAM_READ_TIMEOUT_SECONDS}"
        -o "${stream_body}"
        -w '%{http_code}'
        -X GET
        "$(plugin_url "${plugin}")"
        -H "Authorization: Bearer ${BEARER}"
        -H "Accept: ${MCP_ACCEPT_HEADER}"
        -H "Mcp-Session-Id: ${stream_session_id}"
      )
      if stream_status="$("${stream_curl_args[@]}" 2>"${stream_error}")" && [[ "${stream_status}" == "200" ]]; then
        cp "${stream_body}" "${LAST_BODY}"
        if normalize_response_body "${request_id}"; then
          return 0
        fi
      elif [[ -s "${stream_error}" ]]; then
        LAST_ERROR="$(tr '\n' ' ' < "${stream_error}")"
      fi
    fi
  fi

  if [[ -z "${LAST_ERROR}" ]]; then
    LAST_ERROR="no JSON-RPC response for id ${request_id} from ${plugin}"
  fi
  return 1
}

# Send a JSON-RPC notification (no "id", no response expected).
rpc_notify() {
  local plugin="$1"
  local session_id="$2"
  local request_body="$3"
  local notify_id="${NEXT_ID}"
  local headers_file body_file status
  local -a curl_args

  NEXT_ID=$((NEXT_ID + 1))
  headers_file="${WORK_DIR}/headers-${notify_id}.txt"
  body_file="${WORK_DIR}/body-${notify_id}.json"

  curl_args=(
    "${CURL[@]}"
    -D "${headers_file}"
    -o "${body_file}"
    -w '%{http_code}'
    -X POST
    "$(plugin_url "${plugin}")"
    -H "Authorization: Bearer ${BEARER}"
    -H 'Content-Type: application/json'
    -H "Accept: ${MCP_ACCEPT_HEADER}"
    --data-binary "${request_body}"
  )
  if [[ -n "${session_id}" ]]; then
    curl_args+=(-H "Mcp-Session-Id: ${session_id}")
  fi

  if ! status="$("${curl_args[@]}")"; then
    LAST_ERROR="curl failed for notification to plugin ${plugin}"
    return 1
  fi
  if [[ ! "${status}" =~ ^2[0-9][0-9]$ ]]; then
    LAST_ERROR="notification to ${plugin}: expected 2xx, got ${status}"
    if [[ -f "${body_file}" ]]; then
      cat "${body_file}" >&2
    fi
    return 1
  fi
  LAST_ERROR=""
}

validate_last_response() {
  local context="$1"
  local allow_tool_error="${2:-false}"

  if [[ "${LAST_STATUS}" != "200" ]]; then
    LAST_ERROR="${context}: expected HTTP 200, got ${LAST_STATUS}"
    return 1
  fi

  if ! LAST_ERROR="$(python3 - "${LAST_BODY}" "${context}" "${allow_tool_error}" <<'PY'
import json
import sys

body_path, context, allow_tool_error = sys.argv[1:4]
allow_tool_error = allow_tool_error == "true"

try:
    with open(body_path, encoding="utf-8") as fh:
        payload = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"{context}: invalid JSON response: {exc}")

if payload.get("error") is not None:
    raise SystemExit(f"{context}: JSON-RPC error: {payload['error']}")

if "result" not in payload:
    raise SystemExit(f"{context}: missing JSON-RPC result")

result = payload["result"]
if isinstance(result, dict) and result.get("isError") and not allow_tool_error:
    raise SystemExit(f"{context}: tool returned isError=true")

print("")
PY
  )"; then
    LAST_ERROR="$(printf '%s' "${LAST_ERROR}" | tr '\n' ' ')"
    return 1
  fi
  LAST_ERROR=""
}

response_header() {
  local header_name="$1"
  tr -d '\r' < "${LAST_HEADERS}" | awk -F': ' -v key="${header_name,,}" 'tolower($1) == key { print $2; exit }'
}

body_contains() {
  local needle="$1"
  local context="$2"
  if ! grep -Fq -- "${needle}" "${LAST_BODY}"; then
    LAST_ERROR="${context}: response did not contain expected text: ${needle}"
    return 1
  fi
}

jsonrpc_initialize() {
  local plugin="$1"
  local session_id
  local request_body
  local notify_body

  request_body=$(cat <<JSON
{"jsonrpc":"2.0","id":${NEXT_ID},"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"vm-narrative-smoke","version":"0.1"}}}
JSON
)

  rpc_post "${plugin}" "" "${request_body}" || die "${LAST_ERROR}"
  validate_last_response "initialize ${plugin}" false || {
    if [[ -f "${LAST_BODY}" ]]; then
      cat "${LAST_BODY}" >&2
    fi
    die "${LAST_ERROR}"
  }
  session_id="$(response_header 'Mcp-Session-Id')"
  [[ -n "${session_id}" ]] || die "initialize ${plugin}: missing Mcp-Session-Id response header"
  SESSION_BY_PLUGIN["${plugin}"]="${session_id}"

  notify_body='{"jsonrpc":"2.0","method":"notifications/initialized"}'
  rpc_notify "${plugin}" "${session_id}" "${notify_body}" || die "initialize ${plugin}: ${LAST_ERROR}"

  log_info "Initialized ${plugin} (session ${session_id:0:8}…)"
}

tools_list() {
  local plugin="$1"
  local request_body

  request_body=$(cat <<JSON
{"jsonrpc":"2.0","id":${NEXT_ID},"method":"tools/list","params":{}}
JSON
)

  rpc_post "${plugin}" "${SESSION_BY_PLUGIN[${plugin}]}" "${request_body}" || die "${LAST_ERROR}"
  validate_last_response "tools/list ${plugin}" false || {
    if [[ -f "${LAST_BODY}" ]]; then
      cat "${LAST_BODY}" >&2
    fi
    die "${LAST_ERROR}"
  }
  TOOLS_JSON_BY_PLUGIN["${plugin}"]="${WORK_DIR}/tools-${plugin}.json"
  cp "${LAST_BODY}" "${TOOLS_JSON_BY_PLUGIN[${plugin}]}"
}

# ── Tool call table ───────────────────────────────────────────────────────────
# Hard-code tool names per (plugin, action) so renames surface as loud failures
# rather than silent wrong-tool calls (see assert_tools_registered).
declare -A TOOL_NAMES=(
  [echo:basic]=echo
  [exec-bash:basic]=run
  [exec-jq:basic]=run
  [exec-node:basic]=run
  [exec-python:basic]=run
  [fetch:basic]=fetch
  [fs:write]=write_file
  [fs:read]=read_file
  [git:add]=git_add
  [git:commit]=git_commit
  [git:init]=git_init
  [git:status]=git_status
  [mcp-secrets-probe:secret_present]=secret_present
  [mcp-secrets-probe:secret_digest]=secret_digest
)

tool_name() {
  local key="$1"
  local name="${TOOL_NAMES[${key}]:-}"
  [[ -n "${name}" ]] || die "tool_name: unknown key ${key}"
  printf '%s' "${name}"
}

# json_args: produce a compact JSON object from alternating key/value pairs.
# Accepts JSON-flavoured literals (true/false/null) and Python literals.
json_args() {
  python3 - "$@" <<'PY'
import ast, json, sys

pairs = sys.argv[1:]
if len(pairs) % 2 != 0:
    raise SystemExit("json_args needs an even number of arguments")

JSON_LITERALS = {"true": True, "false": False, "null": None}

out = {}
for key, raw in zip(pairs[0::2], pairs[1::2]):
    if raw in JSON_LITERALS:
        out[key] = JSON_LITERALS[raw]
        continue
    try:
        out[key] = ast.literal_eval(raw)
    except (SyntaxError, ValueError):
        out[key] = raw

print(json.dumps(out, separators=(",", ":")))
PY
}

assert_tools_registered() {
  log_info "Asserting expected tools are registered on each plugin"
  local key plugin action expected_tool tools_json
  for key in "${!TOOL_NAMES[@]}"; do
    plugin="${key%%:*}"
    if [[ -z "${SESSION_BY_PLUGIN[${plugin}]:-}" ]]; then
      continue
    fi
    action="${key##*:}"
    expected_tool="${TOOL_NAMES[${key}]}"
    tools_json="${TOOLS_JSON_BY_PLUGIN[${plugin}]:-}"
    [[ -n "${tools_json}" ]] || die "assert_tools_registered: no tools/list captured for plugin ${plugin}"
    python3 - "${tools_json}" "${plugin}" "${action}" "${expected_tool}" <<'PY' || die \
      "assert_tools_registered: plugin ${plugin} has no tool ${expected_tool} (action=${action}); was it renamed?"
import json
import sys

path, plugin, action, expected = sys.argv[1:5]
with open(path, encoding="utf-8") as fh:
    payload = json.load(fh)
names = [t.get("name") for t in payload.get("result", {}).get("tools", [])]
if expected not in names:
    print(
        f"plugin={plugin} action={action} expected_tool={expected!r} "
        f"not in registered tool names: {names!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
  done
}

# ── Per-(plugin, action) argument builders ────────────────────────────────────
args_echo_basic()                        { json_args message "$1"; }
args_exec_bash_basic()                   { json_args code "$1"; }
args_exec_jq_basic()                     { json_args filter "$1" input "$2"; }
args_exec_node_basic()                   { json_args code "$1"; }
args_exec_python_basic()                 { json_args code "$1"; }
args_fetch_basic()                       { json_args url "$1"; }
args_fs_write()                          { json_args path "$1" content "$2" create_parents true; }
args_fs_read()                           { json_args path "$1"; }
args_git_add()                           { json_args repo_path "$1" files "$2"; }
args_git_commit()                        { json_args repo_path "$1" message "$2"; }
args_git_init()                          { json_args repo_path "$1"; }
args_git_status()                        { json_args repo_path "$1"; }

call_tool_once() {
  local plugin="$1"
  local tool_name="$2"
  local arguments_json="$3"
  local allow_tool_error="${4:-false}"
  local request_body

  request_body=$(cat <<JSON
{"jsonrpc":"2.0","id":${NEXT_ID},"method":"tools/call","params":{"name":"${tool_name}","arguments":${arguments_json},"_meta":{"agent-session-id":"${AGENT_SESSION_ID}"}}}
JSON
)

  rpc_post "${plugin}" "${SESSION_BY_PLUGIN[${plugin}]}" "${request_body}" || return 1
  validate_last_response "tools/call ${plugin}/${tool_name}" "${allow_tool_error}"
}

call_tool_with_candidates() {
  local plugin="$1"
  local tool_name="$2"
  local allow_tool_error="$3"
  local expected_text="$4"
  local context="$5"
  shift 5
  local arguments_json
  local attempt=1

  for arguments_json in "$@"; do
    if call_tool_once "${plugin}" "${tool_name}" "${arguments_json}" "${allow_tool_error}"; then
      if [[ -n "${expected_text}" ]]; then
        if body_contains "${expected_text}" "${context}"; then
          return 0
        fi
      else
        return 0
      fi
    fi
    log_warn "${context} attempt ${attempt} failed: ${LAST_ERROR}"
    attempt=$((attempt + 1))
  done

  if [[ -f "${LAST_BODY}" ]]; then
    cat "${LAST_BODY}" >&2
  fi
  die "${context} failed: ${LAST_ERROR}"
}


# Poll an MCP initialize request through the edge until the auth seam answers
# 200. Required because auth-broker restarts after OPAQUE login provisioning and
# the first requests race the container coming up.
wait_for_auth_ready() {
  local attempts="${AUTH_READY_ATTEMPTS}"
  local request_body attempt

  for attempt in $(seq 1 "${attempts}"); do
    request_body=$(cat <<JSON
{"jsonrpc":"2.0","id":${NEXT_ID},"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"vm-narrative-probe","version":"0.1"}}}
JSON
)
    if rpc_post "echo" "" "${request_body}" && [[ "${LAST_STATUS}" == "200" ]]; then
      log_info "auth seam ready (probe initialize botwork-ui returned 200)"
      return 0
    fi
    log_warn "auth seam not ready yet (status=${LAST_STATUS:-none}); retrying (${attempt}/${attempts})"
    sleep "${AUTH_READY_SLEEP_SECONDS}"
  done

  die "auth seam did not become ready after ${attempts} attempts: last probe initialize echo status=${LAST_STATUS:-none}"
}

# ── Pre-flight: require commands ──────────────────────────────────────────────
for _cmd in curl python3 sha256sum; do
  command -v "${_cmd}" >/dev/null 2>&1 || die "missing required command: ${_cmd}"
done
if [[ ! -x "${LOGIN_BIN}" ]]; then
  fail "bw not found at ${LOGIN_BIN} — set BOTWORK_LOGIN_BIN to the prebuilt binary path or download the payload-assets artifact" \
    "" "" ""
fi

deposit_secret() {
  local service="$1" name="$2" kind="$3" value_file="$4"
  shift 4
  local -a consumers=("$@")

  local value_b64
  value_b64="$(base64 < "${value_file}" | tr -d '\n')"

  local consumers_json="["
  local first=true
  for c in "${consumers[@]}"; do
    if [[ "${first}" == "true" ]]; then
      first=false
    else
      consumers_json+=","
    fi
    consumers_json+="\"${c}\""
  done
  consumers_json+="]"

  local body
  body="{\"service\":\"${service}\",\"name\":\"${name}\",\"kind\":\"${kind}\",\"value_b64\":\"${value_b64}\",\"allowed_consumers\":${consumers_json},\"overwrite\":true}"

  local out status
  out="$(mktemp)"
  if ! status="$("${CURL[@]}" \
    --header "Authorization: Bearer ${BEARER}" \
    --header 'Content-Type: application/json' \
    --data "${body}" \
    --write-out '%{http_code}' --output "${out}" \
    "${SECRETS_API_URL}")"; then
    rm -f "${out}"
    die "deposit_secret ${service}/${name}: curl failed"
  fi
  local resp
  resp="$(cat "${out}")"
  rm -f "${out}"
  if [[ "${status}" != "200" ]] && [[ "${status}" != "201" ]]; then
    fail "deposit_secret ${service}/${name} failed — api may not have a POST /api/tenant/.../secrets handler, or the bearer is not valid" \
      "${SECRETS_API_URL}" "${status}" "${resp}"
  fi
  log_info "Deposited secret ${service}/${name} (allowed_consumers=${consumers_json})"
}

tenant_login() {
    if ! printf '%s' "${PASSWORD}" | "${LOGIN_BIN}" \
        --tenant "${TENANT}" \
        --server "${BASE_URL}" \
        login --password-stdin >/dev/null; then
      fail "bw login failed for tenant=${TENANT} — OPAQUE register succeeded but login failed; check auth-broker logs" \
        "${BASE_URL}/api/auth/login" "" ""
    fi
}

tenant_get_bearer() {
    # Capture the bearer. `bw env` prints `export BOTWORK_BEARER='<value>'`.
    BEARER="$("${LOGIN_BIN}" --tenant "${TENANT}" env \
      | sed -n "s/^export BOTWORK_BEARER='\(.*\)'\$/\1/p")"
    [[ -n "${BEARER}" ]] || fail "bw env did not produce a BOTWORK_BEARER value after successful login" "" "" ""
    echo -n "$BEARER"
}


# ─────────────────────────────────────────────────────────────────────────────
# NOT CURRENTLY USED — pending re-enablement of the secrets present/digest
# boundary matrix (see the Phase 3b work that was descoped from
# botspace/test/test-packed-baked.yaml). These helpers assert that
# mcp-secrets-probe reports the expected secret presence and sha256 digest per
# the allow-consumer boundaries. Keep them here, wired for export, so
# re-enabling is a matter of calling them from the baked config again — do not
# delete.
# ─────────────────────────────────────────────────────────────────────────────

args_mcp_secrets_probe_secret_present()  { json_args name "$1"; }
args_mcp_secrets_probe_secret_digest()   { json_args name "$1"; }

# Walk the JSON-RPC result body (tolerating nested JSON-in-strings) and assert
# that secret_present returned present=<expected>.
assert_probe_secret_present() {
  local tool_name="$1"
  local secret_name="$2"
  local expected="$3"
  local context="$4"
  local arguments_json

  arguments_json="$(args_mcp_secrets_probe_secret_present "${secret_name}")"
  call_tool_once mcp-secrets-probe "${tool_name}" "${arguments_json}" false || {
    if [[ -f "${LAST_BODY}" ]]; then
      cat "${LAST_BODY}" >&2
    fi
    die "${context}: ${LAST_ERROR}"
  }
  python3 - "${LAST_BODY}" "${secret_name}" "${expected}" "${context}" <<'PY'
import json
import sys

path, secret_name, expected_raw, context = sys.argv[1:5]
expected = expected_raw == "true"

with open(path, encoding="utf-8") as fh:
    payload = json.load(fh)

def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)
    elif isinstance(node, str):
        stripped = node.strip()
        if stripped.startswith("{") or stripped.startswith("["):
            try:
                nested = json.loads(stripped)
            except json.JSONDecodeError:
                return
            yield from walk(nested)

for node in walk(payload):
    if isinstance(node, dict) and node.get("present") is expected:
        raise SystemExit(0)

raise SystemExit(f"{context}: expected secret_present({secret_name!r}) -> present={expected}")
PY
}

# Walk the JSON-RPC result body and assert that secret_digest returned the
# expected sha256 hex string.
assert_probe_secret_digest() {
  local tool_name="$1"
  local secret_name="$2"
  local expected_digest="$3"
  local context="$4"
  local arguments_json

  arguments_json="$(args_mcp_secrets_probe_secret_digest "${secret_name}")"
  call_tool_once mcp-secrets-probe "${tool_name}" "${arguments_json}" false || {
    if [[ -f "${LAST_BODY}" ]]; then
      cat "${LAST_BODY}" >&2
    fi
    die "${context}: ${LAST_ERROR}"
  }
  python3 - "${LAST_BODY}" "${secret_name}" "${expected_digest}" "${context}" <<'PY'
import json
import re
import sys

path, secret_name, expected_digest, context = sys.argv[1:5]
if not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
    raise SystemExit(f"{context}: expected digest is not lowercase hex sha256")

with open(path, encoding="utf-8") as fh:
    payload = json.load(fh)

def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)
    elif isinstance(node, str):
        stripped = node.strip()
        if stripped.startswith("{") or stripped.startswith("["):
            try:
                nested = json.loads(stripped)
            except json.JSONDecodeError:
                return
            yield from walk(nested)

for node in walk(payload):
    if not isinstance(node, dict):
        continue
    candidate = node.get("sha256")
    if isinstance(candidate, str) and candidate == expected_digest:
        raise SystemExit(0)

raise SystemExit(f"{context}: expected secret_digest({secret_name!r}) -> sha256={expected_digest}")
PY
}

PROBE_PRESENT_TOOL="$(tool_name mcp-secrets-probe:secret_present)"
PROBE_DIGEST_TOOL="$(tool_name mcp-secrets-probe:secret_digest)"


export SESSION_BY_PLUGIN

ECHO_TOOL="$(tool_name echo:basic)"
EXEC_BASH_TOOL="$(tool_name exec-bash:basic)"
EXEC_JQ_TOOL="$(tool_name exec-jq:basic)"
EXEC_NODE_TOOL="$(tool_name exec-node:basic)"
EXEC_PYTHON_TOOL="$(tool_name exec-python:basic)"
FETCH_TOOL="$(tool_name fetch:basic)"
FS_WRITE_TOOL="$(tool_name fs:write)"
FS_READ_TOOL="$(tool_name fs:read)"
GIT_INIT_TOOL="$(tool_name git:init)"
GIT_STATUS_TOOL="$(tool_name git:status)"
GIT_ADD_TOOL="$(tool_name git:add)"
GIT_COMMIT_TOOL="$(tool_name git:commit)"

export ECHO_TOOL
export EXEC_BASH_TOOL
export EXEC_JQ_TOOL
export EXEC_NODE_TOOL
export EXEC_PYTHON_TOOL
export FETCH_TOOL
export FS_WRITE_TOOL
export FS_READ_TOOL
export GIT_INIT_TOOL
export GIT_STATUS_TOOL
export GIT_ADD_TOOL
export GIT_COMMIT_TOOL
export PROBE_PRESENT_TOOL
export PROBE_DIGEST_TOOL
export WORK_DIR
export GITHUB_PAT_FILE
export PROBE_ONLY_FILE
export JQ_ONLY_FILE
export SHARED_FILE
export UNRESTRICTED_FILE
export GITHUB_PAT_SHA256
export PROBE_ONLY_SHA256
export SHARED_SHA256
export SCRIPT_DIR
export REPO_ROOT
export LOGIN_BIN
export TENANT
export WORKSPACE
export SHARED_RELATIVE_PATH
export SHARED_ABSOLUTE_PATH
export SHARED_CONTENT
export GIT_REPO_RELATIVE_PATH="git-smoke"
export GIT_REPO_ABSOLUTE_PATH
export GIT_FILE_CONTENT

export -f tenant_login
export -f tenant_get_bearer
export -f fail
export -f die
export -f log_info
export -f log_warn
export -f plugin_url
export -f normalize_response_body
export -f rpc_post
export -f rpc_notify
export -f validate_last_response
export -f response_header
export -f body_contains
export -f jsonrpc_initialize
export -f tools_list
export -f tool_name
export -f json_args
export -f assert_tools_registered
export -f args_echo_basic
export -f args_exec_bash_basic
export -f args_exec_jq_basic
export -f args_exec_node_basic
export -f args_exec_python_basic
export -f args_fetch_basic
export -f args_fs_write
export -f args_fs_read
export -f args_git_add
export -f args_git_commit
export -f args_git_init
export -f args_git_status
export -f args_mcp_secrets_probe_secret_present
export -f args_mcp_secrets_probe_secret_digest
export -f call_tool_once
export -f call_tool_with_candidates
export -f assert_probe_secret_present
export -f assert_probe_secret_digest
export -f wait_for_auth_ready
export -f deposit_secret
export -f tenant_login
export -f tenant_get_bearer
