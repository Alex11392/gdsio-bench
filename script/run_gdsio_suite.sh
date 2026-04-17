#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  run_gdsio_suite.sh [config.env]

Environment overrides:
  GDSIO=/usr/local/cuda-13.2/gds/tools/gdsio
  TARGET_DIR=/mnt/nvme0
  GPU_ID=0
  DURATION=30
  MODES_STR="read write"
  X_FLAGS_STR="0 2"
  IO_SWEEP_THREADS=8
  IO_SWEEP_THROUGHPUT_SIZES_STR="128K 256K 512K 1M 2M 4M"
  IO_SWEEP_LATENCY_SIZES_STR="4K 8K 16K 32K 64K 128K"
  THREAD_SWEEP_THREADS_STR="1 2 4 8 16 32"
  THREAD_SWEEP_THROUGHPUT_IO_SIZE=1M
  THREAD_SWEEP_LATENCY_IO_SIZE=4K
  DATASET_SIZE_THROUGHPUT=1G
  DATASET_SIZE_LATENCY=1G
  OUTPUT_ROOT=... RUN_ID=... DATASET_ROOT=...
  VERIFY=0 FAIL_FAST=0 CLEAN_CASE_DATASET=0 CLEAN_RUN_DATASET_ON_EXIT=0
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
DURATION="${DURATION:-30}"
VERIFY="${VERIFY:-0}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${PROJECT_ROOT}/gdsio_harness_results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
RUN_ROOT="${RUN_ROOT:-${OUTPUT_ROOT}/${RUN_ID}}"
META_DIR="${META_DIR:-${RUN_ROOT}/meta}"
CASES_DIR="${CASES_DIR:-${RUN_ROOT}/cases}"
SUMMARY_CSV="${SUMMARY_CSV:-${RUN_ROOT}/summary.csv}"
CUFILE_LOG_DIR="${CUFILE_LOG_DIR:-/home/poc/cufile_log}"
NVFS_STATS_PATH="${NVFS_STATS_PATH:-/proc/driver/nvidia-fs/stats}"
NVFS_VERSION_PATH="${NVFS_VERSION_PATH:-/proc/driver/nvidia-fs/version}"
FAIL_FAST="${FAIL_FAST:-0}"
STOP_ON_FIRST_FAILURE="${STOP_ON_FIRST_FAILURE:-${FAIL_FAST}}"
CLEAN_CASE_DATASET="${CLEAN_CASE_DATASET:-0}"
CLEAN_RUN_DATASET_ON_EXIT="${CLEAN_RUN_DATASET_ON_EXIT:-0}"
RESET_NVFS_STATS="${RESET_NVFS_STATS:-1}"
SAVE_META="${SAVE_META:-1}"
SAVE_CUFILE_LOGS="${SAVE_CUFILE_LOGS:-1}"
ENABLE_MPSTAT="${ENABLE_MPSTAT:-1}"
ENABLE_PIDSTAT="${ENABLE_PIDSTAT:-1}"
ENABLE_NVFS_SAMPLER="${ENABLE_NVFS_SAMPLER:-1}"
MPSTAT_INTERVAL="${MPSTAT_INTERVAL:-1}"
PIDSTAT_INTERVAL="${PIDSTAT_INTERVAL:-1}"
NVFS_SAMPLE_INTERVAL="${NVFS_SAMPLE_INTERVAL:-1}"
VERIFY_XFER_LABEL="${VERIFY_XFER_LABEL:-1}"

MODES_STR="${MODES_STR:-read write}"
read -r -a MODES <<< "${MODES_STR}"

X_FLAGS_STR="${X_FLAGS_STR:-0 2}"
read -r -a X_FLAGS <<< "${X_FLAGS_STR}"

IO_SWEEP_THREADS="${IO_SWEEP_THREADS:-8}"
IO_SWEEP_THROUGHPUT_SIZES_STR="${IO_SWEEP_THROUGHPUT_SIZES_STR:-128K 256K 512K 1M 2M 4M}"
read -r -a IO_SWEEP_THROUGHPUT_SIZES <<< "${IO_SWEEP_THROUGHPUT_SIZES_STR}"
IO_SWEEP_LATENCY_SIZES_STR="${IO_SWEEP_LATENCY_SIZES_STR:-4K 8K 16K 32K 64K 128K}"
read -r -a IO_SWEEP_LATENCY_SIZES <<< "${IO_SWEEP_LATENCY_SIZES_STR}"

THREAD_SWEEP_THROUGHPUT_IO_SIZE="${THREAD_SWEEP_THROUGHPUT_IO_SIZE:-1M}"
THREAD_SWEEP_LATENCY_IO_SIZE="${THREAD_SWEEP_LATENCY_IO_SIZE:-4K}"
THREAD_SWEEP_THREADS_STR="${THREAD_SWEEP_THREADS_STR:-1 2 4 8 16 32}"
read -r -a THREAD_SWEEP_THREADS <<< "${THREAD_SWEEP_THREADS_STR}"

DATASET_SIZE_THROUGHPUT="${DATASET_SIZE_THROUGHPUT:-1G}"
DATASET_SIZE_LATENCY="${DATASET_SIZE_LATENCY:-1G}"
DATASET_ROOT="${DATASET_ROOT:-${TARGET_DIR}/gdsio_suite_${RUN_ID}_gpu${GPU_ID}}"

declare -a RUN_DATASETS=()
declare -A GDSIO_PIDS=()
declare -a BG_PIDS=()

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
}

require_cmd awk
require_cmd date
require_cmd hostname
require_cmd sed
require_cmd stat
require_cmd tee
require_cmd uname

if [[ ! -x "${GDSIO}" ]]; then
  echo "ERROR: gdsio not found or not executable at: ${GDSIO}" >&2
  exit 1
fi

mkdir -p "${META_DIR}" "${CASES_DIR}" "${DATASET_ROOT}"

sanitize_name() {
  echo "$1" | sed 's#[ /]#_#g'
}

ordered_modes() {
  local mode
  local -a ordered=()
  local seen_write=0
  local seen_read=0
  local seen_other=0

  for mode in "${MODES[@]}"; do
    case "${mode}" in
      write)
        if [[ "${seen_write}" == "0" ]]; then
          ordered+=("write")
          seen_write=1
        fi
        ;;
      read)
        seen_read=1
        ;;
      *)
        ordered+=("${mode}")
        seen_other=1
        ;;
    esac
  done

  if [[ "${seen_read}" == "1" ]]; then
    if [[ "${seen_write}" == "0" ]]; then
      ordered+=("read")
    else
      ordered+=("read")
    fi
  fi

  printf '%s\n' "${ordered[@]}"
}

dataset_key() {
  local test_group="$1"
  local x_flag="$2"
  local threads="$3"
  local io_size="$4"
  printf '%s__x%s__th%s__io%s' \
    "$(sanitize_name "${test_group}")" \
    "${x_flag}" \
    "${threads}" \
    "$(sanitize_name "${io_size}")"
}

xfer_label() {
  case "$1" in
    0) echo "GPUD" ;;
    1) echo "CPU_ONLY" ;;
    2) echo "CPU_GPU" ;;
    3) echo "CPU_ASYNC_GPU" ;;
    4) echo "CPU_CACHED_GPU" ;;
    5) echo "GPU_DIRECT_ASYNC" ;;
    6) echo "GPU_BATCH" ;;
    7) echo "GPU_BATCH_STREAM" ;;
    *) echo "UNKNOWN" ;;
  esac
}

mode_iotype() {
  case "$1" in
    read) echo "0" ;;
    write) echo "1" ;;
    randread) echo "2" ;;
    randwrite) echo "3" ;;
    *) echo "ERROR: unsupported mode $1" >&2; exit 1 ;;
  esac
}

register_dataset() {
  RUN_DATASETS+=("$1")
}

cleanup_dataset_if_needed() {
  local dataset_path="$1"
  if [[ "${CLEAN_CASE_DATASET}" == "1" && -e "${dataset_path}" ]]; then
    rm -rf -- "${dataset_path}"
  fi
}

cleanup_all_run_datasets() {
  if [[ "${CLEAN_RUN_DATASET_ON_EXIT}" != "1" ]]; then
    return
  fi
  local ds
  for ds in "${RUN_DATASETS[@]:-}"; do
    [[ -e "${ds}" ]] && rm -rf -- "${ds}"
  done
  rmdir "${DATASET_ROOT}" 2>/dev/null || true
}

stop_pid_if_alive() {
  local pid="$1"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

cleanup_background_pids() {
  local pid
  for pid in "${BG_PIDS[@]:-}"; do
    stop_pid_if_alive "${pid}"
  done
}

cleanup_on_exit() {
  cleanup_background_pids
  cleanup_all_run_datasets
}
trap cleanup_on_exit EXIT

write_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  printf '%s=%s\n' "${key}" "${value}" >> "${file}"
}

capture_meta() {
  local run_info="${META_DIR}/run_info.txt"
  : > "${run_info}"
  write_kv "${run_info}" "start_time" "$(date --iso-8601=seconds)"
  write_kv "${run_info}" "hostname" "$(hostname)"
  write_kv "${run_info}" "kernel" "$(uname -r)"
  write_kv "${run_info}" "gdsio" "${GDSIO}"
  write_kv "${run_info}" "target_dir" "${TARGET_DIR}"
  write_kv "${run_info}" "dataset_root" "${DATASET_ROOT}"
  write_kv "${run_info}" "gpu_id" "${GPU_ID}"
  write_kv "${run_info}" "duration_s" "${DURATION}"
  write_kv "${run_info}" "output_root" "${RUN_ROOT}"
  write_kv "${run_info}" "cufile_log_dir" "${CUFILE_LOG_DIR}"
  write_kv "${run_info}" "modes" "${MODES_STR}"
  write_kv "${run_info}" "x_flags" "${X_FLAGS_STR}"
  write_kv "${run_info}" "verify" "${VERIFY}"
  write_kv "${run_info}" "reset_nvfs_stats" "${RESET_NVFS_STATS}"

  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi > "${META_DIR}/nvidia-smi.txt" 2>&1 || true
  fi

  if [[ -r "${NVFS_VERSION_PATH}" ]]; then
    cat "${NVFS_VERSION_PATH}" > "${META_DIR}/nvidia-fs-version.txt"
  else
    printf 'unavailable\n' > "${META_DIR}/nvidia-fs-version.txt"
  fi

  if [[ -r "${NVFS_STATS_PATH}" ]]; then
    cat "${NVFS_STATS_PATH}" > "${META_DIR}/nvidia-fs-stats-initial.txt" 2>/dev/null || true
  else
    printf 'unavailable\n' > "${META_DIR}/nvidia-fs-stats-initial.txt"
  fi
}

init_summary_csv() {
  cat > "${SUMMARY_CSV}" <<'EOF'
case_name,test_group,mode,x_flag,xfer_label,gpu_id,threads,dataset,io_size,throughput_gib_s,avg_latency_us,iops,ops,total_time_s,exit_code,case_dir,xfer_match
EOF
}

reset_nvfs_stats_if_possible() {
  local out_file="$1"
  if [[ "${RESET_NVFS_STATS}" != "1" ]]; then
    printf 'skip: RESET_NVFS_STATS=%s\n' "${RESET_NVFS_STATS}" > "${out_file}"
    return
  fi
  if [[ ! -e "${NVFS_STATS_PATH}" ]]; then
    printf 'skip: missing %s\n' "${NVFS_STATS_PATH}" > "${out_file}"
    return
  fi
  if [[ ! -w "${NVFS_STATS_PATH}" ]]; then
    printf 'skip: %s not writable\n' "${NVFS_STATS_PATH}" > "${out_file}"
    return
  fi
  if printf '0\n' > "${NVFS_STATS_PATH}" 2>"${out_file}"; then
    printf 'ok: reset at %s\n' "$(date --iso-8601=seconds)" > "${out_file}"
  else
    printf 'failed: see stderr above\n' >> "${out_file}"
  fi
}

snapshot_nvfs_stats() {
  local out_file="$1"
  if [[ -r "${NVFS_STATS_PATH}" ]]; then
    cat "${NVFS_STATS_PATH}" > "${out_file}" 2>/dev/null || printf 'read failed\n' > "${out_file}"
  else
    printf 'unavailable\n' > "${out_file}"
  fi
}

start_nvfs_sampler() {
  local out_file="$1"
  if [[ "${ENABLE_NVFS_SAMPLER}" != "1" || ! -r "${NVFS_STATS_PATH}" ]]; then
    printf 'disabled or unavailable\n' > "${out_file}"
    return 1
  fi
  (
    while true; do
      printf '=== %s ===\n' "$(date --iso-8601=seconds)"
      cat "${NVFS_STATS_PATH}" 2>/dev/null || printf 'read failed\n'
      sleep "${NVFS_SAMPLE_INTERVAL}"
    done
  ) > "${out_file}" 2>&1 &
  BG_PIDS+=("$!")
  echo "$!"
}

start_mpstat_sampler() {
  local out_file="$1"
  if [[ "${ENABLE_MPSTAT}" != "1" ]] || ! command -v mpstat >/dev/null 2>&1; then
    printf 'disabled or unavailable\n' > "${out_file}"
    return 1
  fi
  mpstat -P ALL "${MPSTAT_INTERVAL}" > "${out_file}" 2>&1 &
  BG_PIDS+=("$!")
  echo "$!"
}

start_pidstat_sampler() {
  local pid="$1"
  local out_file="$2"
  if [[ "${ENABLE_PIDSTAT}" != "1" ]] || ! command -v pidstat >/dev/null 2>&1; then
    printf 'disabled or unavailable\n' > "${out_file}"
    return 1
  fi
  pidstat -r -u -d -p "${pid}" "${PIDSTAT_INTERVAL}" > "${out_file}" 2>&1 &
  BG_PIDS+=("$!")
  echo "$!"
}

write_case_info() {
  local file="$1"
  local case_name="$2"
  local test_group="$3"
  local mode="$4"
  local x_flag="$5"
  local threads="$6"
  local dataset="$7"
  local io_size="$8"
  : > "${file}"
  write_kv "${file}" "start_time" "$(date --iso-8601=seconds)"
  write_kv "${file}" "case_name" "${case_name}"
  write_kv "${file}" "test_group" "${test_group}"
  write_kv "${file}" "gpu_id" "${GPU_ID}"
  write_kv "${file}" "x_flag" "${x_flag}"
  write_kv "${file}" "xfer_label" "$(xfer_label "${x_flag}")"
  write_kv "${file}" "mode" "${mode}"
  write_kv "${file}" "threads" "${threads}"
  write_kv "${file}" "dataset_size" "${dataset}"
  write_kv "${file}" "io_size" "${io_size}"
  write_kv "${file}" "duration_s" "${DURATION}"
  write_kv "${file}" "gdsio" "${GDSIO}"
  write_kv "${file}" "target_dir" "${TARGET_DIR}"
  write_kv "${file}" "dataset_root" "${DATASET_ROOT}"
  write_kv "${file}" "cufile_log_dir" "${CUFILE_LOG_DIR}"
}

capture_cufile_logs() {
  local marker="$1"
  local out_dir="$2"
  mkdir -p "${out_dir}"
  if [[ "${SAVE_CUFILE_LOGS}" != "1" || ! -d "${CUFILE_LOG_DIR}" ]]; then
    printf 'disabled or unavailable\n' > "${out_dir}/README.txt"
    return
  fi
  local found=0
  local src
  shopt -s nullglob
  for src in "${CUFILE_LOG_DIR}"/*; do
    if [[ "${src}" -nt "${marker}" ]]; then
      cp -p -- "${src}" "${out_dir}/" 2>/dev/null || true
      found=1
    fi
  done
  shopt -u nullglob
  if [[ "${found}" == "0" ]]; then
    printf 'No cufile logs newer than marker %s\n' "${marker}" > "${out_dir}/README.txt"
  fi
}

extract_metric() {
  local log_file="$1"
  local key="$2"
  awk -v wanted="${key}" '
    index($0, wanted) > 0 {
      for (i = 1; i <= NF; ++i) {
        gsub(/,/, "", $i)
        if ($i == wanted && (i + 1) <= NF) {
          v = $(i + 1)
          gsub(/,/, "", v)
          print v
          exit
        }
      }
    }
  ' "${log_file}"
}

extract_xfertype() {
  local log_file="$1"
  awk '
    /XferType:/ {
      for (i = 1; i <= NF; ++i) {
        if ($i == "XferType:" && (i + 1) <= NF) {
          gsub(/,/, "", $(i + 1))
          print $(i + 1)
          exit
        }
      }
    }
  ' "${log_file}"
}

append_summary_row() {
  local case_name="$1"
  local test_group="$2"
  local mode="$3"
  local x_flag="$4"
  local threads="$5"
  local dataset="$6"
  local io_size="$7"
  local exit_code="$8"
  local case_dir="$9"
  local gdsio_log="${10}"

  local throughput avg_latency ops total_time iops expected_xfer actual_xfer xfer_match
  throughput="$(extract_metric "${gdsio_log}" "Throughput:")"
  avg_latency="$(extract_metric "${gdsio_log}" "Avg_Latency:")"
  ops="$(extract_metric "${gdsio_log}" "ops:")"
  total_time="$(extract_metric "${gdsio_log}" "total_time")"
  expected_xfer="$(xfer_label "${x_flag}")"
  actual_xfer="$(extract_xfertype "${gdsio_log}")"
  xfer_match="NA"

  if [[ -n "${actual_xfer}" ]]; then
    if [[ "${actual_xfer}" == "${expected_xfer}" ]]; then
      xfer_match="1"
    else
      xfer_match="0"
    fi
  fi

  if [[ -n "${ops}" && -n "${total_time}" ]]; then
    iops="$(awk -v ops="${ops}" -v total="${total_time}" 'BEGIN { if (total > 0) printf "%.6f", ops / total; }')"
  else
    iops=""
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${case_name}" \
    "${test_group}" \
    "${mode}" \
    "${x_flag}" \
    "${expected_xfer}" \
    "${GPU_ID}" \
    "${threads}" \
    "${dataset}" \
    "${io_size}" \
    "${throughput}" \
    "${avg_latency}" \
    "${iops}" \
    "${ops}" \
    "${total_time}" \
    "${exit_code}" \
    "${case_dir}" \
    "${xfer_match}" >> "${SUMMARY_CSV}"
}

run_case() {
  local test_group="$1"
  local mode="$2"
  local x_flag="$3"
  local threads="$4"
  local dataset_size="$5"
  local io_size="$6"

  local safe_group safe_io case_name case_dir dataset_dir ds_key marker_file command_file
  local case_info_file gdsio_log exit_code_file mpstat_log pidstat_log
  local nvfs_before nvfs_after nvfs_samples reset_log cufile_out_dir
  local iotype exit_code=0 gdsio_pid="" pidstat_pid="" mpstat_pid="" nvfs_pid=""

  safe_group="$(sanitize_name "${test_group}")"
  safe_io="$(sanitize_name "${io_size}")"
  case_name="${safe_group}__${mode}__x${x_flag}__th${threads}__io${safe_io}"
  case_dir="${CASES_DIR}/${case_name}"
  ds_key="$(dataset_key "${test_group}" "${x_flag}" "${threads}" "${io_size}")"
  dataset_dir="${DATASET_ROOT}/${ds_key}"
  marker_file="${case_dir}/cufile_marker"
  command_file="${case_dir}/command.sh"
  case_info_file="${case_dir}/case_info.txt"
  gdsio_log="${case_dir}/gdsio.log"
  exit_code_file="${case_dir}/exit_code.txt"
  mpstat_log="${case_dir}/mpstat.log"
  pidstat_log="${case_dir}/pidstat.log"
  nvfs_before="${case_dir}/nvidia_fs_stats_before.txt"
  nvfs_after="${case_dir}/nvidia_fs_stats_after.txt"
  nvfs_samples="${case_dir}/nvidia_fs_stats_samples.log"
  reset_log="${case_dir}/nvidia_fs_stats_reset.txt"
  cufile_out_dir="${case_dir}/cufile_logs"
  iotype="$(mode_iotype "${mode}")"

  cleanup_dataset_if_needed "${dataset_dir}"
  mkdir -p "${case_dir}" "${dataset_dir}"
  register_dataset "${dataset_dir}"
  write_case_info "${case_info_file}" "${case_name}" "${test_group}" "${mode}" "${x_flag}" "${threads}" "${dataset_size}" "${io_size}"

  reset_nvfs_stats_if_possible "${reset_log}"
  snapshot_nvfs_stats "${nvfs_before}"
  : > "${marker_file}"

  cat > "${command_file}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"${GDSIO}" -D "${dataset_dir}" -d "${GPU_ID}" -w "${threads}" -s "${dataset_size}" -i "${io_size}" -x "${x_flag}" -I "${iotype}" -T "${DURATION}"$( [[ "${VERIFY}" == "1" ]] && printf ' -V' )
EOF
  chmod +x "${command_file}"

  mpstat_pid="$(start_mpstat_sampler "${mpstat_log}" || true)"
  nvfs_pid="$(start_nvfs_sampler "${nvfs_samples}" || true)"

  set +e
  "${command_file}" > "${gdsio_log}" 2>&1 &
  gdsio_pid="$!"
  GDSIO_PIDS["${case_name}"]="${gdsio_pid}"
  set -e

  pidstat_pid="$(start_pidstat_sampler "${gdsio_pid}" "${pidstat_log}" || true)"

  set +e
  wait "${gdsio_pid}"
  exit_code="$?"
  set -e

  printf '%s\n' "${exit_code}" > "${exit_code_file}"

  stop_pid_if_alive "${pidstat_pid}"
  stop_pid_if_alive "${mpstat_pid}"
  stop_pid_if_alive "${nvfs_pid}"
  snapshot_nvfs_stats "${nvfs_after}"
  capture_cufile_logs "${marker_file}" "${cufile_out_dir}"
  append_summary_row "${case_name}" "${test_group}" "${mode}" "${x_flag}" "${threads}" "${dataset_size}" "${io_size}" "${exit_code}" "${case_dir}" "${gdsio_log}"

  if [[ "${VERIFY_XFER_LABEL}" == "1" ]]; then
    local expected actual
    expected="$(xfer_label "${x_flag}")"
    actual="$(extract_xfertype "${gdsio_log}")"
    if [[ -n "${actual}" && "${actual}" != "${expected}" ]]; then
      printf 'WARNING: expected XferType %s, got %s\n' "${expected}" "${actual}" | tee -a "${case_info_file}" >&2
    fi
  fi

  if [[ "${exit_code}" != "0" && "${STOP_ON_FIRST_FAILURE}" == "1" ]]; then
    echo "ERROR: case failed: ${case_name}" >&2
    exit "${exit_code}"
  fi
}

run_matrix() {
  local mode x_flag io_size threads
  local -a modes_to_run=()

  mapfile -t modes_to_run < <(ordered_modes)

  for mode in "${modes_to_run[@]}"; do
    for x_flag in "${X_FLAGS[@]}"; do
      for io_size in "${IO_SWEEP_THROUGHPUT_SIZES[@]}"; do
        run_case "io_size_sweep_throughput" "${mode}" "${x_flag}" "${IO_SWEEP_THREADS}" "${DATASET_SIZE_THROUGHPUT}" "${io_size}"
      done
      for io_size in "${IO_SWEEP_LATENCY_SIZES[@]}"; do
        run_case "io_size_sweep_latency" "${mode}" "${x_flag}" "${IO_SWEEP_THREADS}" "${DATASET_SIZE_LATENCY}" "${io_size}"
      done
      for threads in "${THREAD_SWEEP_THREADS[@]}"; do
        run_case "thread_sweep_throughput" "${mode}" "${x_flag}" "${threads}" "${DATASET_SIZE_THROUGHPUT}" "${THREAD_SWEEP_THROUGHPUT_IO_SIZE}"
      done
      for threads in "${THREAD_SWEEP_THREADS[@]}"; do
        run_case "thread_sweep_latency" "${mode}" "${x_flag}" "${threads}" "${DATASET_SIZE_LATENCY}" "${THREAD_SWEEP_LATENCY_IO_SIZE}"
      done
    done
  done
}

echo "[INFO] run_root        : ${RUN_ROOT}"
echo "[INFO] gdsio           : ${GDSIO}"
echo "[INFO] target_dir      : ${TARGET_DIR}"
echo "[INFO] dataset_root    : ${DATASET_ROOT}"
echo "[INFO] gpu_id          : ${GPU_ID}"
echo "[INFO] duration        : ${DURATION}"
echo "[INFO] modes           : ${MODES_STR}"
echo "[INFO] x_flags         : ${X_FLAGS_STR}"
echo "[INFO] summary_csv     : ${SUMMARY_CSV}"

if [[ "${SAVE_META}" == "1" ]]; then
  capture_meta
fi
init_summary_csv
run_matrix

echo "[INFO] completed run: ${RUN_ROOT}"
echo "[INFO] summary      : ${SUMMARY_CSV}"
