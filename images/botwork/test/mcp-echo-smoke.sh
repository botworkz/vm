#!/usr/bin/env bash
set -euo pipefail

if [[ -t 2 ]]; then
  COLOR_RED='\033[31m'
  COLOR_YELLOW='\033[33m'
  COLOR_GREEN='\033[32m'
  COLOR_RESET='\033[0m'
else
  COLOR_RED=''
  COLOR_YELLOW=''
  COLOR_GREEN=''
  COLOR_RESET=''
fi

log_info() { echo -e "${COLOR_GREEN}==>${COLOR_RESET} $*" >&2; }
log_warn() { echo -e "${COLOR_YELLOW}WARN:${COLOR_RESET} $*" >&2; }
log_error() { echo -e "${COLOR_RED}ERROR:${COLOR_RESET} $*" >&2; }

die() { log_error "$*"; exit 1; }

ensure_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

WORK_DIR="$(mktemp -d /tmp/mcp-echo-smoke.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

API_BASE="${API_BASE:-http://127.0.0.1:8080}"
TENANT="${TENANT:-mcp}"
PLUGIN="${PLUGIN:-echo}"
MCP_ACCEPT_HEADER="application/json, text/event-stream"
MCP_STREAM_READ_TIMEOUT_SECONDS="${MCP_STREAM_READ_TIMEOUT_SECONDS:-5}"
NEXT_ID=1
LAST_HEADERS=""
LAST_BODY=""
LAST_STATUS=""
LAST_ERROR=""

normalize_response_body() {
  local input_file="$1"
  local output_file="$2"
  local expected_id="${3:-}"

  python3 - "${input_file}" "${output_file}" "${expected_id}" <<'PY'
import json
import pathlib
import sys

input_file, output_file, expected_id = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(input_file).read_text(encoding="utf-8", errors="replace")

if not text.strip():
    pathlib.Path(output_file).write_text("", encoding="utf-8")
    sys.exit(0)

stripped = text.lstrip()
if stripped.startswith("{") or stripped.startswith("["):
    pathlib.Path(output_file).write_text(text, encoding="utf-8")
    sys.exit(0)

candidates = []
chunks = []
current = []
for line in text.splitlines():
    if line.startswith("data:"):
      current.append(line[5:].lstrip())
      continue
    if line.strip() == "":
      if current:
        chunks.append("\n".join(current).strip())
        current = []
if current:
    chunks.append("\n".join(current).strip())

for chunk in chunks:
    if not chunk or chunk == "[DONE]":
      continue
    try:
      payload = json.loads(chunk)
    except Exception:
      continue
    candidates.append((chunk, payload))

if not candidates:
    pathlib.Path(output_file).write_text(text, encoding="utf-8")
    sys.exit(0)

if expected_id:
    for raw, payload in candidates:
        if str(payload.get("id", "")) == expected_id:
            pathlib.Path(output_file).write_text(raw, encoding="utf-8")
            sys.exit(0)

pathlib.Path(output_file).write_text(candidates[-1][0], encoding="utf-8")
PY
}

response_header() {
  local name="$1"
  python3 - "${LAST_HEADERS}" "${name}" <<'PY'
import pathlib
import re
import sys

header_file, target = sys.argv[1], sys.argv[2].lower()
text = pathlib.Path(header_file).read_text(encoding="utf-8", errors="replace")
for line in text.splitlines():
    if ":" not in line:
        continue
    key, value = line.split(":", 1)
    if key.strip().lower() == target:
        print(re.sub(r"\r$", "", value.strip()))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

body_contains() {
  local needle="$1"
  local context="$2"
  if grep -Fq -- "${needle}" "${LAST_BODY}"; then
    return 0
  fi
  LAST_ERROR="${context}: response body did not contain expected text: ${needle}"
  return 1
}

validate_last_response() {
  local context="$1"
  local allow_empty="$2"

  if [[ -z "${LAST_STATUS}" ]]; then
    LAST_ERROR="${context}: missing HTTP status"
    return 1
  fi

  if [[ ! "${LAST_STATUS}" =~ ^2 ]]; then
    LAST_ERROR="${context}: HTTP ${LAST_STATUS}"
    return 1
  fi

  if [[ ! -s "${LAST_BODY}" ]]; then
    if [[ "${allow_empty}" == "true" ]]; then
      return 0
    fi
    LAST_ERROR="${context}: empty response body"
    return 1
  fi

  if ! python3 - "${LAST_BODY}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)
if payload.get("error") is not None:
    raise SystemExit(1)
PY
  then
    LAST_ERROR="${context}: JSON-RPC error response"
    return 1
  fi

  return 0
}

extract_rpc_id() {
  local body="$1"
  python3 - "${body}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
rpc_id = payload.get("id")
if rpc_id is None:
    raise SystemExit(1)
print(rpc_id)
PY
}

rpc_post() {
  local plugin="$1"
  local session_id="$2"
  local body="$3"

  LAST_ERROR=""
  LAST_HEADERS="${WORK_DIR}/headers-$(date +%s%N).txt"
  local raw_body="${WORK_DIR}/raw-body-$(date +%s%N).txt"
  LAST_BODY="${WORK_DIR}/body-$(date +%s%N).txt"

  local url="${API_BASE}/${TENANT}/${plugin}"
  local -a curl_args=(
    -sS
    -o "${raw_body}"
    -D "${LAST_HEADERS}"
    -X POST "${url}"
    -H "Content-Type: application/json"
    -H "Accept: ${MCP_ACCEPT_HEADER}"
    --data "${body}"
    -w "%{http_code}"
  )

  if [[ -n "${session_id}" ]]; then
    curl_args+=( -H "Mcp-Session-Id: ${session_id}" )
  fi

  if ! LAST_STATUS="$(curl "${curl_args[@]}")"; then
    LAST_ERROR="POST ${url} failed"
    return 1
  fi

  local request_id=""
  if request_id="$(extract_rpc_id "${body}" 2>/dev/null || true)"; then
    :
  fi

  normalize_response_body "${raw_body}" "${LAST_BODY}" "${request_id}"

  if [[ -n "${request_id}" ]] && [[ -n "${session_id}" ]]; then
    if ! python3 - "${LAST_BODY}" "${request_id}" <<'PY'
import json
import pathlib
import sys

path, expected = sys.argv[1], sys.argv[2]
text = pathlib.Path(path).read_text(encoding="utf-8", errors="replace").strip()
if not text:
    raise SystemExit(1)
payload = json.loads(text)
if str(payload.get("id", "")) != expected:
    raise SystemExit(1)
PY
    then
      local stream_raw="${WORK_DIR}/stream-raw-$(date +%s%N).txt"
      local stream_body="${WORK_DIR}/stream-body-$(date +%s%N).txt"
      local stream_url="${url}"

      if ! curl -sS \
        -o "${stream_raw}" \
        -D /dev/null \
        -X GET "${stream_url}" \
        -H "Accept: ${MCP_ACCEPT_HEADER}" \
        -H "Mcp-Session-Id: ${session_id}" \
        --max-time "${MCP_STREAM_READ_TIMEOUT_SECONDS}"; then
        LAST_ERROR="POST ${url}: response id ${request_id} not in inline body and SSE fallback failed"
        return 1
      fi

      normalize_response_body "${stream_raw}" "${stream_body}" "${request_id}"
      if ! [[ -s "${stream_body}" ]]; then
        LAST_ERROR="POST ${url}: empty SSE fallback body"
        return 1
      fi

      LAST_BODY="${stream_body}"
    fi
  fi

  if [[ -n "${request_id}" ]]; then
    NEXT_ID=$((NEXT_ID + 1))
  fi

  return 0
}

rpc_notify() {
  local plugin="$1"
  local session_id="$2"
  local body="$3"

  LAST_ERROR=""
  LAST_HEADERS="${WORK_DIR}/headers-$(date +%s%N).txt"
  LAST_BODY="${WORK_DIR}/body-$(date +%s%N).txt"

  local url="${API_BASE}/${TENANT}/${plugin}"
  local -a curl_args=(
    -sS
    -o "${LAST_BODY}"
    -D "${LAST_HEADERS}"
    -X POST "${url}"
    -H "Content-Type: application/json"
    -H "Accept: ${MCP_ACCEPT_HEADER}"
    -H "Mcp-Session-Id: ${session_id}"
    --data "${body}"
    -w "%{http_code}"
  )

  if ! LAST_STATUS="$(curl "${curl_args[@]}")"; then
    LAST_ERROR="POST notify ${url} failed"
    return 1
  fi

  if [[ ! "${LAST_STATUS}" =~ ^2 ]]; then
    LAST_ERROR="notify ${plugin}: HTTP ${LAST_STATUS}"
    return 1
  fi

  return 0
}

wait_for_envoy_ready() {
  local attempts="${ENVOY_READY_ATTEMPTS:-30}"
  local sleep_seconds="${ENVOY_READY_SLEEP_SECONDS:-2}"
  local body attempt
  for attempt in $(seq 1 "${attempts}"); do
    body=$(printf '{"jsonrpc":"2.0","id":%d,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-echo-smoke-probe","version":"0.1"}}}' "${NEXT_ID}")
    if rpc_post "${PLUGIN}" "" "${body}" && [[ "${LAST_STATUS}" == "200" ]]; then
      log_info "envoy + broker + ${PLUGIN} ready (probe initialize 200)"
      return 0
    fi
    log_warn "envoy not ready yet (status=${LAST_STATUS:-none}); retry ${attempt}/${attempts}"
    sleep "${sleep_seconds}"
  done
  die "envoy did not become ready after ${attempts} attempts (last status=${LAST_STATUS:-none})"
}

for cmd in curl python3; do
  ensure_command "${cmd}"
done

wait_for_envoy_ready

INIT_BODY=$(printf '{"jsonrpc":"2.0","id":%d,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-echo-smoke","version":"0.1"}}}' "${NEXT_ID}")
rpc_post "${PLUGIN}" "" "${INIT_BODY}" || die "${LAST_ERROR}"
validate_last_response "initialize ${PLUGIN}" false || { cat "${LAST_BODY}" >&2 || true; die "${LAST_ERROR}"; }
SESSION_ID="$(response_header 'Mcp-Session-Id')"
[[ -n "${SESSION_ID}" ]] || die "initialize ${PLUGIN}: missing Mcp-Session-Id"

rpc_notify "${PLUGIN}" "${SESSION_ID}" '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  || die "notifications/initialized: ${LAST_ERROR}"

LIST_BODY=$(printf '{"jsonrpc":"2.0","id":%d,"method":"tools/list","params":{}}' "${NEXT_ID}")
rpc_post "${PLUGIN}" "${SESSION_ID}" "${LIST_BODY}" || die "${LAST_ERROR}"
validate_last_response "tools/list ${PLUGIN}" false || die "${LAST_ERROR}"
TOOLS_JSON="${WORK_DIR}/tools.json"
cp "${LAST_BODY}" "${TOOLS_JSON}"
TOOL_NAME="$(python3 - "${TOOLS_JSON}" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
tools = payload.get("result", {}).get("tools") or []
for t in tools:
    hay = " ".join(str(t.get(k, "")) for k in ("name", "title", "description")).lower()
    if "echo" in hay:
        print(t["name"]); sys.exit(0)
if len(tools) == 1:
    print(tools[0]["name"]); sys.exit(0)
sys.exit("no echo-like tool found")
PY
)"

NONCE="hello-from-echo-smoke-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
ARGS_JSON="$(python3 - "${TOOLS_JSON}" "${TOOL_NAME}" "${NONCE}" <<'PY'
import json
import re
import sys

payload_path, tool_name, nonce = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.load(open(payload_path))
tools = payload.get("result", {}).get("tools") or []
tool = next((t for t in tools if t.get("name") == tool_name), None)
if not tool:
    raise SystemExit(f"tool not found: {tool_name}")
properties = ((tool.get("inputSchema") or {}).get("properties") or {})
if not properties:
    raise SystemExit("tool input schema has no properties")
preferred = re.compile(r"message|text|value|input|prompt", re.IGNORECASE)
key = None
for candidate, schema in properties.items():
    if isinstance(schema, dict) and schema.get("type") == "string" and preferred.search(candidate):
        key = candidate
        break
if key is None:
    for candidate, schema in properties.items():
        if isinstance(schema, dict) and schema.get("type") == "string":
            key = candidate
            break
if key is None:
    raise SystemExit("no string input property found")
print(json.dumps({key: nonce}))
PY
)"

CALL_BODY=$(printf '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "${NEXT_ID}" "${TOOL_NAME}" "${ARGS_JSON}")
rpc_post "${PLUGIN}" "${SESSION_ID}" "${CALL_BODY}" || die "${LAST_ERROR}"
validate_last_response "tools/call ${PLUGIN}/${TOOL_NAME}" false || die "${LAST_ERROR}"
body_contains "${NONCE}" "echo response" || die "${LAST_ERROR}"

# ── Structured-content + config-injection assertion ─────────────────────────
#
# The vm/ smoke test has a single end-to-end job: prove that the content of
# `plugins-base.yaml`'s `config:` block makes it intact through
#
#   plugins.yaml → config-broker → session-broker → launcher → container env
#                                                                     │
#                                                                     ▼
#                                                          BOTWORK_MCP_CONFIG
#                                                                     │
#                                                                     ▼
#                                                       mcp-echo's response.env
#
# A regression in any of those legs surfaces here as a single failed assert.
#
# We compare against the on-disk fixture rather than a hard-coded literal
# because the fixture *is* the authoritative shape; if someone tweaks the
# YAML, this stays honest without the test silently going stale.
log_info "Asserting structured echo response surfaces injected BOTWORK_MCP_CONFIG"
python3 - "${LAST_BODY}" /etc/botwork/plugins.yaml <<'PY' || die "config-injection assertion failed"
import json
import pathlib
import sys

response_path, plugins_yaml_path = sys.argv[1], sys.argv[2]

# 1) Parse the JSON-RPC response. rmcp's Json<T> wrapper places the structured
#    payload under result.structuredContent; older wrappers / unknown SDKs
#    might place it under structured_content. Tolerate either.
payload = json.loads(pathlib.Path(response_path).read_text(encoding="utf-8"))
result = payload.get("result")
if not isinstance(result, dict):
    raise SystemExit(f"missing result object: {payload!r}")

structured = result.get("structuredContent") or result.get("structured_content")
if not isinstance(structured, dict):
    raise SystemExit(
        "echo response missing structuredContent — is mcp-echo new enough? "
        f"keys present: {sorted(result.keys())}"
    )

for required in ("message", "plugin", "version", "env"):
    if required not in structured:
        raise SystemExit(
            f"structuredContent missing '{required}'; got keys "
            f"{sorted(structured.keys())}"
        )

if structured["plugin"] != "mcp-echo":
    raise SystemExit(f"unexpected plugin name: {structured['plugin']!r}")

env_list = structured["env"]
if not isinstance(env_list, list):
    raise SystemExit("structuredContent.env must be a list")

env = {}
for entry in env_list:
    if not isinstance(entry, dict) or "name" not in entry or "value" not in entry:
        raise SystemExit(f"malformed env entry: {entry!r}")
    env[entry["name"]] = entry["value"]

# 2) BOTWORK_MCP_CONFIG must be present.
config_blob = env.get("BOTWORK_MCP_CONFIG")
if config_blob is None:
    raise SystemExit(
        "BOTWORK_MCP_CONFIG was NOT injected into mcp-echo's environment. "
        "config-broker → session-broker → launcher → container plumbing is "
        "broken somewhere on this path. env keys: "
        f"{sorted(env.keys())}"
    )

# 3) The injected blob must be valid JSON.
try:
    received = json.loads(config_blob)
except json.JSONDecodeError as exc:
    raise SystemExit(
        f"BOTWORK_MCP_CONFIG was not valid JSON ({exc}). raw value: {config_blob!r}"
    )

# 4) The injected blob must structurally match the on-disk fixture.
#    We re-load plugins.yaml so this test stays honest if the fixture moves.
import yaml  # provisioned via 00-base.sh's python3-yaml

fixture = yaml.safe_load(
    pathlib.Path(plugins_yaml_path).read_text(encoding="utf-8")
)
expected = ((fixture.get("plugins") or {}).get("echo") or {}).get("config")
if expected is None:
    raise SystemExit(
        f"plugins.yaml at {plugins_yaml_path} has no echo.config block; "
        "the smoke fixture is stripped — please restore it."
    )

if received != expected:
    raise SystemExit(
        "Injected BOTWORK_MCP_CONFIG does not match plugins.yaml fixture.\n"
        f"  expected: {json.dumps(expected, sort_keys=True)}\n"
        f"  received: {json.dumps(received, sort_keys=True)}"
    )

# 5) Sentinel string assertion — separate from the structural compare so the
#    failure is easy to read when only this prong trips.
marker = expected.get("vm_smoke_marker")
if marker != "vm-base-config-injection-ok":
    raise SystemExit(
        f"vm_smoke_marker drift in fixture: got {marker!r}; the goss check "
        "and this assertion both rely on the canonical value."
    )

# 6) Light secret-redaction sanity: any BOTWORK_SECRET_* keys that happen to
#    be present in the spawned env must be redacted by mcp-echo. The base
#    image doesn't provision any (no auth-broker / vault), so this is a
#    no-op today and a defensive check for when overlays add them. Failure
#    here means mcp-echo's redaction rule has been weakened.
for name, value in env.items():
    if name.startswith("BOTWORK_SECRET_") and not value.startswith("<redacted len="):
        raise SystemExit(
            f"BOTWORK_SECRET_* env value not redacted in mcp-echo response: {name}"
        )

print("config-injection assertion ok")
PY

log_info "echo MCP smoke passed (tenant=${TENANT}, plugin=${PLUGIN}, tool=${TOOL_NAME})"
