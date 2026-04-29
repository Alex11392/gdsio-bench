#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
DOCS_DATA_DIR="${ROOT_DIR}/docs/data"
REQUEST_JSON="${DOCS_DATA_DIR}/lmcache_long_prompt_request.json"

VENV_DIR="${VENV_DIR:-/home/poc/vllm_lmcache_gds/.venv}"
MODEL_NAME="${MODEL_NAME:-facebook/opt-125m}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.7}"
GPU_DEVICE="${GPU_DEVICE:-1}"
DIRECT_PORT="${DIRECT_PORT:-8010}"
FALLBACK_PORT="${FALLBACK_PORT:-8011}"
RUN_ID="${RUN_ID:-lmcache_gds_mode_validation_$(date +%Y%m%d_%H%M%S)}"
RAW_RUN_DIR="${RESULTS_DIR}/${RUN_ID}"
COMMITTED_DATA_DIR="${DOCS_DATA_DIR}/${RUN_ID}"
CUFILE_LOG="${CUFILE_LOG:-/usr/local/cuda/gds/tools/cufile.log}"

mkdir -p "${RAW_RUN_DIR}" "${COMMITTED_DATA_DIR}"

if [[ ! -x "${VENV_DIR}/bin/vllm" ]]; then
  echo "Missing vLLM environment at ${VENV_DIR}" >&2
  exit 1
fi

if [[ ! -f "${REQUEST_JSON}" ]]; then
  echo "Missing request JSON at ${REQUEST_JSON}" >&2
  exit 1
fi

cleanup_pid() {
  local pid="${1:-}"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

wait_for_server() {
  local port="$1"
  local timeout_secs="$2"
  local server_pid="$3"
  local start_ts
  start_ts="$(date +%s)"
  while true; do
    if curl -fsS "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      return 1
    fi
    if (( "$(date +%s)" - start_ts > timeout_secs )); then
      return 1
    fi
    sleep 1
  done
}

extract_json_field() {
  local json_path="$1"
  local expr="$2"
  python3 - "$json_path" "$expr" <<'PY'
import json
import sys

path = sys.argv[1]
expr = sys.argv[2]
data = json.load(open(path))

value = data
for part in expr.split("."):
    if part.isdigit():
        value = value[int(part)]
    else:
        value = value[part]
print(value)
PY
}

copy_cufile_delta() {
  local before_bytes="$1"
  local delta_out="$2"
  if [[ ! -f "${CUFILE_LOG}" ]]; then
    : > "${delta_out}"
    return 0
  fi
  python3 - "${CUFILE_LOG}" "${before_bytes}" "${delta_out}" <<'PY'
import os
import sys

src, offset_str, dst = sys.argv[1:4]
offset = int(offset_str)
size = os.path.getsize(src)
with open(dst, "wb") as out:
    if size <= offset:
        sys.exit(0)
    with open(src, "rb") as f:
        f.seek(offset)
        out.write(f.read())
PY
}

run_mode() {
  local mode="$1"
  local port="$2"
  local use_cufile="$3"

  local mode_dir="${RAW_RUN_DIR}/${mode}"
  local committed_mode_dir="${COMMITTED_DATA_DIR}/${mode}"
  local cache_dir="/mnt/nvme0/${RUN_ID}_${mode}_cache"
  local config_path="${mode_dir}/lmcache_config.yaml"
  local server_log="${mode_dir}/server.log"
  local request_1_json="${mode_dir}/request_1.json"
  local request_2_json="${mode_dir}/request_2.json"
  local metrics_txt="${mode_dir}/metrics_snippet.txt"
  local env_txt="${mode_dir}/env.txt"
  local cufile_delta="${mode_dir}/cufile_delta.log"
  local summary_csv="${RAW_RUN_DIR}/summary.csv"
  local server_pid=""

  mkdir -p "${mode_dir}" "${committed_mode_dir}" "${cache_dir}"

  cat > "${config_path}" <<EOF
chunk_size: 256
local_cpu: false
gds_path: "${cache_dir}"
cufile_buffer_size: 1024
extra_config:
  use_cufile: ${use_cufile}
EOF

  {
    echo "mode=${mode}"
    echo "port=${port}"
    echo "cache_dir=${cache_dir}"
    echo "config_path=${config_path}"
    echo "model_name=${MODEL_NAME}"
    echo "gpu_memory_utilization=${GPU_MEMORY_UTILIZATION}"
    echo "gpu_device=${GPU_DEVICE}"
    echo "use_cufile=${use_cufile}"
  } > "${env_txt}"

  local cufile_before=0
  if [[ -f "${CUFILE_LOG}" ]]; then
    cufile_before="$(stat -c '%s' "${CUFILE_LOG}")"
  fi

  (
    source "${VENV_DIR}/bin/activate"
    export CUDA_VISIBLE_DEVICES="${GPU_DEVICE}"
    export LMCACHE_USE_EXPERIMENTAL=True
    export LMCACHE_CONFIG_FILE="${config_path}"
    exec vllm serve "${MODEL_NAME}" \
      --port "${port}" \
      --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
      --kv-transfer-config '{"kv_connector":"LMCacheConnectorV1","kv_role":"kv_both"}'
  ) > "${server_log}" 2>&1 &
  server_pid="$!"

  if ! wait_for_server "${port}" 180 "${server_pid}"; then
    cleanup_pid "${server_pid}"
    echo "Server failed to start for mode ${mode}. See ${server_log}" >&2
    exit 1
  fi

  local start_ms end_ms first_ms second_ms

  start_ms="$(date +%s%3N)"
  curl -fsS "http://127.0.0.1:${port}/v1/completions" \
    -H 'Content-Type: application/json' \
    --data-binary @"${REQUEST_JSON}" \
    > "${request_1_json}"
  end_ms="$(date +%s%3N)"
  first_ms="$((end_ms - start_ms))"

  start_ms="$(date +%s%3N)"
  curl -fsS "http://127.0.0.1:${port}/v1/completions" \
    -H 'Content-Type: application/json' \
    --data-binary @"${REQUEST_JSON}" \
    > "${request_2_json}"
  end_ms="$(date +%s%3N)"
  second_ms="$((end_ms - start_ms))"

  curl -fsS "http://127.0.0.1:${port}/metrics" \
    | egrep 'external_prefix_cache|prefix_cache' \
    > "${metrics_txt}" || true

  sleep 2
  cleanup_pid "${server_pid}"

  copy_cufile_delta "${cufile_before}" "${cufile_delta}"

  find "${cache_dir}" -maxdepth 3 -type f | sort > "${mode_dir}/cache_files.txt"
  cp "${config_path}" "${committed_mode_dir}/lmcache_config.yaml"
  cp "${env_txt}" "${committed_mode_dir}/env.txt"
  cp "${metrics_txt}" "${committed_mode_dir}/metrics_snippet.txt"
  cp "${mode_dir}/cache_files.txt" "${committed_mode_dir}/cache_files.txt"
  cp "${request_1_json}" "${committed_mode_dir}/request_1.json"
  cp "${request_2_json}" "${committed_mode_dir}/request_2.json"

  grep -E 'Using cufile|Not using cufile|Stored |LMCache hit tokens|GDS backend using|No base pointer found|Error saving|LMCache is unhealthy' \
    "${server_log}" \
    > "${committed_mode_dir}/key_log_lines.txt" || true

  cp "${cufile_delta}" "${committed_mode_dir}/cufile_delta.log"

  local stored_tokens lmcache_hit_tokens cache_file_count direct_branch fallback_branch cufile_delta_bytes
  stored_tokens="$(grep -oE 'Stored [0-9]+' "${server_log}" | awk '{print $2}' | tail -n1)"
  lmcache_hit_tokens="$(grep -oE 'LMCache hit tokens: [0-9]+' "${server_log}" | awk '{print $4}' | tail -n1)"
  cache_file_count="$(wc -l < "${mode_dir}/cache_files.txt" | tr -d ' ')"
  direct_branch=0
  fallback_branch=0
  grep -q 'Using cufile' "${server_log}" && direct_branch=1 || true
  grep -q 'Not using cufile' "${server_log}" && fallback_branch=1 || true
  cufile_delta_bytes="$(wc -c < "${cufile_delta}" | tr -d ' ')"
  stored_tokens="${stored_tokens:-0}"
  lmcache_hit_tokens="${lmcache_hit_tokens:-0}"

  local prompt_tokens total_tokens completion_tokens
  prompt_tokens="$(extract_json_field "${request_2_json}" 'usage.prompt_tokens')"
  total_tokens="$(extract_json_field "${request_2_json}" 'usage.total_tokens')"
  completion_tokens="$(extract_json_field "${request_2_json}" 'usage.completion_tokens')"

  if [[ ! -f "${summary_csv}" ]]; then
    cat > "${summary_csv}" <<'EOF'
mode,use_cufile,first_request_ms,second_request_ms,stored_tokens,lmcache_hit_tokens,cache_file_count,prompt_tokens,total_tokens,completion_tokens,direct_branch_log,fallback_branch_log,cufile_delta_bytes
EOF
  fi

  cat >> "${summary_csv}" <<EOF
${mode},${use_cufile},${first_ms},${second_ms},${stored_tokens},${lmcache_hit_tokens},${cache_file_count},${prompt_tokens},${total_tokens},${completion_tokens},${direct_branch},${fallback_branch},${cufile_delta_bytes}
EOF
}

{
  echo "${RUN_ID}"
} > "${RAW_RUN_DIR}/run_id.txt"

{
  echo "run_id=${RUN_ID}"
  echo "timestamp=$(date --iso-8601=seconds)"
  echo "hostname=$(hostname)"
  echo "pwd=$(pwd)"
  echo "repo_root=${ROOT_DIR}"
  echo "venv_dir=${VENV_DIR}"
  echo "request_json=${REQUEST_JSON}"
} > "${RAW_RUN_DIR}/meta.txt"

nvidia-smi > "${RAW_RUN_DIR}/nvidia_smi_before.txt"
/usr/local/cuda/gds/tools/gdscheck.py -p > "${RAW_RUN_DIR}/gdscheck.txt"
stat -f -c '%T' /mnt/nvme0 > "${RAW_RUN_DIR}/filesystem_type.txt"

run_mode "direct" "${DIRECT_PORT}" "true"
run_mode "forced_fallback" "${FALLBACK_PORT}" "false"

cp "${RAW_RUN_DIR}/summary.csv" "${COMMITTED_DATA_DIR}/summary.csv"
cp "${RAW_RUN_DIR}/gdscheck.txt" "${COMMITTED_DATA_DIR}/gdscheck.txt"
cp "${RAW_RUN_DIR}/filesystem_type.txt" "${COMMITTED_DATA_DIR}/filesystem_type.txt"
cp "${RAW_RUN_DIR}/meta.txt" "${COMMITTED_DATA_DIR}/meta.txt"

echo "Completed run: ${RUN_ID}"
echo "Raw artifacts: ${RAW_RUN_DIR}"
echo "Committed data: ${COMMITTED_DATA_DIR}"
