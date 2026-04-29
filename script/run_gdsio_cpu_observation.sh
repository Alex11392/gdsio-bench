#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  run_gdsio_cpu_observation.sh [config.env]

Runs a focused four-case GDS-vs-CPU experiment with mpstat/pidstat logging.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  echo "ERROR: expected at most one optional config file path" >&2
  usage >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  CONFIG_FILE="$1"
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config file not found: ${CONFIG_FILE}" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

GDSIO="${GDSIO:-/usr/local/cuda-13.2/gds/tools/gdsio}"
TARGET_DIR="${TARGET_DIR:-/mnt/nvme0}"
GPU_ID="${GPU_ID:-0}"
RUNTIME="${RUNTIME:-10}"
REPEATS="${REPEATS:-3}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${PROJECT_ROOT}/results}"
RUN_ID="${RUN_ID:-cpu_observation_$(date +%Y%m%d_%H%M%S)}"
RUN_ROOT="${RUN_ROOT:-${OUTPUT_ROOT}/${RUN_ID}}"
META_DIR="${META_DIR:-${RUN_ROOT}/meta}"
CASES_DIR="${CASES_DIR:-${RUN_ROOT}/cases}"
SUMMARY_CSV="${SUMMARY_CSV:-${RUN_ROOT}/summary.csv}"
DATASET_ROOT="${DATASET_ROOT:-${TARGET_DIR}/gdsio_cpu_observation_${RUN_ID}_gpu${GPU_ID}}"

X_FLAGS_STR="${X_FLAGS_STR-0 2}"
read -r -a X_FLAGS <<< "${X_FLAGS_STR}"

PREPARE_DATASETS="${PREPARE_DATASETS:-1}"
PREP_X_FLAG="${PREP_X_FLAG:-2}"
PREP_IO_SIZE="${PREP_IO_SIZE:-1M}"
PREP_DURATION="${PREP_DURATION:-1}"
PREP_MIN_FILL_RATIO="${PREP_MIN_FILL_RATIO:-0.95}"
PREP_MAX_ATTEMPTS="${PREP_MAX_ATTEMPTS:-6}"

ENABLE_MPSTAT="${ENABLE_MPSTAT:-1}"
ENABLE_PIDSTAT="${ENABLE_PIDSTAT:-1}"
ENABLE_IOSTAT="${ENABLE_IOSTAT:-1}"
ENABLE_NVIDIA_DMON="${ENABLE_NVIDIA_DMON:-0}"
ENABLE_NVFS_SAMPLER="${ENABLE_NVFS_SAMPLER:-0}"
ENABLE_GDS_STATS="${ENABLE_GDS_STATS:-0}"
SAVE_META="${SAVE_META:-1}"

MPSTAT_INTERVAL="${MPSTAT_INTERVAL:-1}"
PIDSTAT_INTERVAL="${PIDSTAT_INTERVAL:-1}"
IOSTAT_INTERVAL="${IOSTAT_INTERVAL:-1}"
NVIDIA_DMON_INTERVAL="${NVIDIA_DMON_INTERVAL:-1}"
NVFS_SAMPLE_INTERVAL="${NVFS_SAMPLE_INTERVAL:-1}"
GDS_STATS_INTERVAL="${GDS_STATS_INTERVAL:-1}"

CPU_OBS_CASES_STR="${CPU_OBS_CASES_STR-seq:read:8:1G:1M seq:read:8:1G:4M seq:write:8:1G:1M rand:write:32:1G:4K}"
read -r -a CPU_OBS_CASES <<< "${CPU_OBS_CASES_STR}"

NVFS_STATS_PATH="${NVFS_STATS_PATH:-/proc/driver/nvidia-fs/stats}"
NVFS_VERSION_PATH="${NVFS_VERSION_PATH:-/proc/driver/nvidia-fs/version}"
GDSCHECK_BIN="${GDSCHECK_BIN:-/usr/local/cuda/gds/tools/gdscheck}"
GDS_STATS_BIN="${GDS_STATS_BIN:-/usr/local/cuda/gds/tools/gds_stats}"

declare -A PREPARED_DATASETS=()

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
}

for cmd in awk date hostname sed stat tee uname; do
  require_cmd "${cmd}"
done

if [[ ! -x "${GDSIO}" ]]; then
  echo "ERROR: gdsio not found or not executable at: ${GDSIO}" >&2
  exit 1
fi

mkdir -p "${META_DIR}" "${CASES_DIR}" "${DATASET_ROOT}"

xfer_label() {
  case "$1" in
    0) echo "GPUD" ;;
    2) echo "CPU_GPU" ;;
    *) echo "UNKNOWN" ;;
  esac
}

io_type_flag() {
  local pattern="$1"
  local mode="$2"
  case "${pattern}:${mode}" in
    seq:read) echo "0" ;;
    seq:write) echo "1" ;;
    rand:read) echo "2" ;;
    rand:write) echo "3" ;;
    *) echo "ERROR: unsupported pattern/mode ${pattern}/${mode}" >&2; exit 1 ;;
  esac
}

sanitize_name() {
  echo "$1" | sed 's#[ /:]#_#g'
}

extract_metric() {
  local log_file="$1"
  local prefix="$2"
  sed -n "s/.*${prefix} \([^ ]*\).*/\1/p" "${log_file}" | tail -n 1
}

extract_dataset_progress_kib() {
  local log_file="$1"
  sed -n 's/.*DataSetSize: \([0-9][0-9]*\)\/\([0-9][0-9]*\)(KiB).*/\1 \2/p' "${log_file}" | tail -n 1
}

extract_xfertype() {
  local log_file="$1"
  sed -n 's/.*XferType: \([^ ]*\).*/\1/p' "${log_file}" | tail -n 1
}

snapshot_nvfs_stats() {
  local out_file="$1"
  if [[ -r "${NVFS_STATS_PATH}" ]]; then
    cat "${NVFS_STATS_PATH}" > "${out_file}" 2>/dev/null || printf 'read failed\n' > "${out_file}"
  else
    printf 'unavailable\n' > "${out_file}"
  fi
}

stop_pid_if_alive() {
  local pid="$1"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}

start_mpstat_sampler() {
  local out_file="$1"
  if [[ "${ENABLE_MPSTAT}" != "1" ]] || ! command -v mpstat >/dev/null 2>&1; then
    return 0
  fi
  mpstat -P ALL "${MPSTAT_INTERVAL}" > "${out_file}" 2>&1 &
  echo "$!"
}

start_pidstat_sampler() {
  local pid="$1"
  local out_file="$2"
  if [[ "${ENABLE_PIDSTAT}" != "1" ]] || ! command -v pidstat >/dev/null 2>&1; then
    return 0
  fi
  pidstat -r -u -d -p "${pid}" "${PIDSTAT_INTERVAL}" > "${out_file}" 2>&1 &
  echo "$!"
}

start_iostat_sampler() {
  local out_file="$1"
  if [[ "${ENABLE_IOSTAT}" != "1" ]] || ! command -v iostat >/dev/null 2>&1; then
    return 0
  fi
  iostat -dxm "${IOSTAT_INTERVAL}" > "${out_file}" 2>&1 &
  echo "$!"
}

capture_meta() {
  if [[ "${SAVE_META}" != "1" ]]; then
    return
  fi
  uname -a > "${META_DIR}/uname.txt" 2>&1 || true
  lscpu > "${META_DIR}/lscpu.txt" 2>&1 || true
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi > "${META_DIR}/nvidia-smi.txt" 2>&1 || true
    nvidia-smi topo -m > "${META_DIR}/nvidia-smi-topo.txt" 2>&1 || true
  fi
  if [[ -x "${GDSCHECK_BIN}" ]]; then
    "${GDSCHECK_BIN}" -p > "${META_DIR}/gdscheck-platform.txt" 2>&1 || true
  fi
  if [[ -r "${NVFS_VERSION_PATH}" ]]; then
    cat "${NVFS_VERSION_PATH}" > "${META_DIR}/nvidia-fs-version.txt"
  fi
}

init_summary_csv() {
  cat > "${SUMMARY_CSV}" <<'EOF'
case_name,test_group,mode,pattern,target_metric,sweep_axis,repeat_id,x_flag,xfer_label,gpu_id,threads,dataset,io_size,throughput_gib_s,avg_latency_us,iops,ops,total_time_s,exit_code,case_dir,xfer_match,prepared_dataset
EOF
}

append_summary_row() {
  local case_name="$1"
  local test_group="$2"
  local mode="$3"
  local pattern="$4"
  local target_metric="$5"
  local repeat_id="$6"
  local x_flag="$7"
  local threads="$8"
  local dataset_size="$9"
  local io_size="${10}"
  local exit_code="${11}"
  local case_dir="${12}"
  local gdsio_log="${13}"
  local prepared_dataset="${14}"
  local throughput avg_latency ops total_time iops expected_xfer actual_xfer xfer_match

  throughput="$(extract_metric "${gdsio_log}" "Throughput:")"
  avg_latency="$(extract_metric "${gdsio_log}" "Avg_Latency:")"
  ops="$(extract_metric "${gdsio_log}" "ops:")"
  total_time="$(sed -n 's/.* total_time \([^ ]*\) secs.*/\1/p' "${gdsio_log}" | tail -n 1)"
  if [[ -n "${ops}" && -n "${total_time}" ]]; then
    iops="$(awk -v ops="${ops}" -v total="${total_time}" 'BEGIN { if (total > 0) printf "%.6f", ops / total; }')"
  else
    iops=""
  fi
  actual_xfer="$(extract_xfertype "${gdsio_log}")"
  expected_xfer="$(xfer_label "${x_flag}")"
  if [[ -z "${actual_xfer}" ]]; then
    xfer_match="NA"
  elif [[ "${actual_xfer}" == "${expected_xfer}" ]]; then
    xfer_match="1"
  else
    xfer_match="0"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${case_name}" \
    "${test_group}" \
    "${mode}" \
    "${pattern}" \
    "${target_metric}" \
    "$( [[ "${test_group}" == io_size_* ]] && echo io_size || echo threads )" \
    "${repeat_id}" \
    "${x_flag}" \
    "${expected_xfer}" \
    "${GPU_ID}" \
    "${threads}" \
    "${dataset_size}" \
    "${io_size}" \
    "${throughput}" \
    "${avg_latency}" \
    "${iops}" \
    "${ops}" \
    "${total_time}" \
    "${exit_code}" \
    "${case_dir}" \
    "${xfer_match}" \
    "${prepared_dataset}" >> "${SUMMARY_CSV}"
}

prepare_dataset_if_needed() {
  local dataset_key="$1"
  local mode="$2"
  local threads="$3"
  local dataset_size="$4"
  local io_size="$5"
  local dataset_dir="$6"

  if [[ "${PREPARE_DATASETS}" != "1" ]]; then
    echo "0"
    return
  fi
  if [[ "${mode}" != "read" ]]; then
    echo "0"
    return
  fi
  if [[ -n "${PREPARED_DATASETS[${dataset_key}]:-}" ]]; then
    echo "1"
    return
  fi

  mkdir -p "${dataset_dir}"
  local prep_log="${dataset_dir}/prep_write.log"
  local attempt=1
  local current_duration="${PREP_DURATION}"
  local actual_kib target_kib fill_ratio
  while (( attempt <= PREP_MAX_ATTEMPTS )); do
    rm -rf "${dataset_dir:?}/"*
    echo "[PREP] creating dataset ${dataset_dir} (threads=${threads}, size=${dataset_size}, io_size=${PREP_IO_SIZE}, duration=${current_duration}s, attempt=${attempt})" >&2
    set +e
    "${GDSIO}" -D "${dataset_dir}" -d "${GPU_ID}" -w "${threads}" -s "${dataset_size}" -i "${PREP_IO_SIZE}" -x "${PREP_X_FLAG}" -I 1 -T "${current_duration}" > "${prep_log}" 2>&1
    prep_rc="$?"
    set -e
    if [[ "${prep_rc}" != "0" ]]; then
      echo "ERROR: dataset preparation failed for ${dataset_dir}. See ${prep_log}" >&2
      exit "${prep_rc}"
    fi
    read -r actual_kib target_kib <<< "$(extract_dataset_progress_kib "${prep_log}")"
    if [[ -n "${actual_kib}" && -n "${target_kib}" ]]; then
      fill_ratio="$(awk -v actual="${actual_kib}" -v target="${target_kib}" 'BEGIN { if (target > 0) printf "%.6f", actual / target; }')"
      if awk -v ratio="${fill_ratio}" -v min_ratio="${PREP_MIN_FILL_RATIO}" 'BEGIN { exit !(ratio >= min_ratio) }'; then
        PREPARED_DATASETS["${dataset_key}"]="1"
        echo "1"
        return
      fi
      echo "[PREP] dataset underfilled: actual=${actual_kib}KiB target=${target_kib}KiB ratio=${fill_ratio}; retrying" >&2
    fi
    attempt=$((attempt + 1))
    current_duration=$((current_duration * 2))
  done

  echo "ERROR: dataset preparation did not reach fill ratio ${PREP_MIN_FILL_RATIO} for ${dataset_dir}. See ${prep_log}" >&2
  exit 1
}

run_case() {
  local pattern="$1"
  local mode="$2"
  local threads="$3"
  local dataset_size="$4"
  local io_size="$5"
  local repeat_id="$6"
  local x_flag="$7"

  local test_group target_metric case_name dataset_key dataset_dir case_dir gdsio_log command_file
  local exit_code_file mpstat_log pidstat_log iostat_log nvfs_before nvfs_after iotype prepared_dataset
  local gdsio_pid="" mpstat_pid="" pidstat_pid="" iostat_pid="" exit_code

  if [[ "${pattern}" == "seq" ]]; then
    test_group="$( [[ "${io_size}" == "1M" || "${io_size}" == "4M" ]] && echo cpu_obs_seq || echo cpu_obs_seq_misc )"
    target_metric="throughput"
  else
    test_group="cpu_obs_rand"
    target_metric="iops_latency"
  fi

  case_name="$(sanitize_name "${pattern}_${mode}_x${x_flag}_th${threads}_size${dataset_size}_io${io_size}_rep${repeat_id}")"
  dataset_key="$(sanitize_name "${pattern}_${mode}_th${threads}_size${dataset_size}_io${io_size}_rep${repeat_id}")"
  dataset_dir="${DATASET_ROOT}/${dataset_key}"
  case_dir="${CASES_DIR}/${case_name}"
  gdsio_log="${case_dir}/gdsio.log"
  command_file="${case_dir}/command.sh"
  exit_code_file="${case_dir}/exit_code.txt"
  mpstat_log="${case_dir}/mpstat.log"
  pidstat_log="${case_dir}/pidstat.log"
  iostat_log="${case_dir}/iostat.log"
  nvfs_before="${case_dir}/nvidia_fs_stats_before.txt"
  nvfs_after="${case_dir}/nvidia_fs_stats_after.txt"
  iotype="$(io_type_flag "${pattern}" "${mode}")"

  mkdir -p "${case_dir}" "${dataset_dir}"
  prepared_dataset="$(prepare_dataset_if_needed "${dataset_key}" "${mode}" "${threads}" "${dataset_size}" "${io_size}" "${dataset_dir}")"
  snapshot_nvfs_stats "${nvfs_before}"

cat > "${command_file}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${GDSIO}" -D "${dataset_dir}" -d "${GPU_ID}" -w "${threads}" -s "${dataset_size}" -i "${io_size}" -x "${x_flag}" -I "${iotype}" -T "${RUNTIME}"
EOF
  chmod +x "${command_file}"

  mpstat_pid="$(start_mpstat_sampler "${mpstat_log}" || true)"
  iostat_pid="$(start_iostat_sampler "${iostat_log}" || true)"

  set +e
  "${command_file}" > "${gdsio_log}" 2>&1 &
  gdsio_pid="$!"
  set -e

  pidstat_pid="$(start_pidstat_sampler "${gdsio_pid}" "${pidstat_log}" || true)"

  echo "[RUN] ${case_name}"
  echo "      command: ${command_file}"

  set +e
  wait "${gdsio_pid}"
  exit_code="$?"
  set -e
  printf '%s\n' "${exit_code}" > "${exit_code_file}"

  stop_pid_if_alive "${pidstat_pid}"
  stop_pid_if_alive "${mpstat_pid}"
  stop_pid_if_alive "${iostat_pid}"
  snapshot_nvfs_stats "${nvfs_after}"
  append_summary_row "${case_name}" "${test_group}" "${mode}" "${pattern}" "${target_metric}" "${repeat_id}" "${x_flag}" "${threads}" "${dataset_size}" "${io_size}" "${exit_code}" "${case_dir}" "${gdsio_log}" "${prepared_dataset}"

  if [[ "${exit_code}" != "0" ]]; then
    echo "ERROR: case failed: ${case_name}" >&2
    exit "${exit_code}"
  fi
}

capture_meta
init_summary_csv

echo "[INFO] gdsio             : ${GDSIO}"
echo "[INFO] target_dir        : ${TARGET_DIR}"
echo "[INFO] dataset_root      : ${DATASET_ROOT}"
echo "[INFO] gpu_id            : ${GPU_ID}"
echo "[INFO] runtime           : ${RUNTIME}"
echo "[INFO] repeats           : ${REPEATS}"
echo "[INFO] output_root       : ${RUN_ROOT}"
echo "[INFO] x_flags           : ${X_FLAGS_STR}"
echo "[INFO] cases             : ${CPU_OBS_CASES_STR}"

for repeat_id in $(seq 1 "${REPEATS}"); do
  for x_flag in "${X_FLAGS[@]}"; do
    for case_def in "${CPU_OBS_CASES[@]}"; do
      IFS=':' read -r pattern mode threads dataset_size io_size <<< "${case_def}"
      run_case "${pattern}" "${mode}" "${threads}" "${dataset_size}" "${io_size}" "${repeat_id}" "${x_flag}"
    done
  done
done

echo "[DONE] summary : ${SUMMARY_CSV}"
echo "[DONE] cases   : ${CASES_DIR}"
