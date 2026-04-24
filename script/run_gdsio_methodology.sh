#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  run_gdsio_methodology.sh [config.env]

This is the canonical benchmark runner kept in this repo.
It splits GDSIO benchmarking into two families:
  1. Large sequential IO for throughput
  2. Small random IO for IOPS/latency
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
VERIFY="${VERIFY:-0}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${PROJECT_ROOT}/results}"
RUN_ID="${RUN_ID:-methodology_$(date +%Y%m%d_%H%M%S)}"
RUN_ROOT="${RUN_ROOT:-${OUTPUT_ROOT}/${RUN_ID}}"
META_DIR="${META_DIR:-${RUN_ROOT}/meta}"
CASES_DIR="${CASES_DIR:-${RUN_ROOT}/cases}"
SUMMARY_CSV="${SUMMARY_CSV:-${RUN_ROOT}/summary.csv}"
DATASET_ROOT="${DATASET_ROOT:-${TARGET_DIR}/gdsio_methodology_${RUN_ID}_gpu${GPU_ID}}"
CUFILE_LOG_DIR="${CUFILE_LOG_DIR:-/home/poc/cufile_log}"
NVFS_STATS_PATH="${NVFS_STATS_PATH:-/proc/driver/nvidia-fs/stats}"
NVFS_VERSION_PATH="${NVFS_VERSION_PATH:-/proc/driver/nvidia-fs/version}"
GDS_STATS_BIN="${GDS_STATS_BIN:-/usr/local/cuda/gds/tools/gds_stats}"
GDSCHECK_BIN="${GDSCHECK_BIN:-/usr/local/cuda/gds/tools/gdscheck}"

parse_words_var() {
  local var_name="$1"
  local default_words="$2"
  local -n out_ref="$3"
  if [[ ${!var_name+x} ]]; then
    if [[ -z "${!var_name}" ]]; then
      out_ref=()
    else
      read -r -a out_ref <<< "${!var_name}"
    fi
  else
    read -r -a out_ref <<< "${default_words}"
  fi
}

X_FLAGS_STR="${X_FLAGS_STR-0 2}"
parse_words_var "X_FLAGS_STR" "0 2" X_FLAGS

REPEATS="${REPEATS:-3}"
PREPARE_DATASETS="${PREPARE_DATASETS:-1}"
PREP_X_FLAG="${PREP_X_FLAG:-2}"
PREP_IO_SIZE="${PREP_IO_SIZE:-auto}"
PREP_DURATION="${PREP_DURATION:-1}"
PREP_MIN_FILL_RATIO="${PREP_MIN_FILL_RATIO:-0.95}"
PREP_MAX_ATTEMPTS="${PREP_MAX_ATTEMPTS:-5}"
RESET_NVFS_STATS="${RESET_NVFS_STATS:-0}"
SAVE_META="${SAVE_META:-0}"
SAVE_CUFILE_LOGS="${SAVE_CUFILE_LOGS:-0}"
ENABLE_MPSTAT="${ENABLE_MPSTAT:-0}"
ENABLE_PIDSTAT="${ENABLE_PIDSTAT:-0}"
ENABLE_IOSTAT="${ENABLE_IOSTAT:-0}"
ENABLE_NVIDIA_DMON="${ENABLE_NVIDIA_DMON:-0}"
ENABLE_NVFS_SAMPLER="${ENABLE_NVFS_SAMPLER:-0}"
ENABLE_GDS_STATS="${ENABLE_GDS_STATS:-0}"
MPSTAT_INTERVAL="${MPSTAT_INTERVAL:-1}"
PIDSTAT_INTERVAL="${PIDSTAT_INTERVAL:-1}"
IOSTAT_INTERVAL="${IOSTAT_INTERVAL:-1}"
NVIDIA_DMON_INTERVAL="${NVIDIA_DMON_INTERVAL:-1}"
NVFS_SAMPLE_INTERVAL="${NVFS_SAMPLE_INTERVAL:-1}"
GDS_STATS_INTERVAL="${GDS_STATS_INTERVAL:-1}"
VERIFY_XFER_LABEL="${VERIFY_XFER_LABEL:-1}"

SEQ_IO_SWEEP_THREADS="${SEQ_IO_SWEEP_THREADS:-8}"
SEQ_IO_SIZES_STR="${SEQ_IO_SIZES_STR-128K 256K 512K 1M 2M 4M}"
parse_words_var "SEQ_IO_SIZES_STR" "128K 256K 512K 1M 2M 4M" SEQ_IO_SIZES
SEQ_THREAD_SWEEP_IO_SIZE="${SEQ_THREAD_SWEEP_IO_SIZE:-1M}"
SEQ_THREADS_STR="${SEQ_THREADS_STR-1 2 4 8 16 32}"
parse_words_var "SEQ_THREADS_STR" "1 2 4 8 16 32" SEQ_THREADS
SEQ_DATASET_SIZE="${SEQ_DATASET_SIZE:-1G}"

RAND_IO_SWEEP_THREADS="${RAND_IO_SWEEP_THREADS:-32}"
RAND_IO_SIZES_STR="${RAND_IO_SIZES_STR-4K 8K 16K 32K 64K 128K}"
parse_words_var "RAND_IO_SIZES_STR" "4K 8K 16K 32K 64K 128K" RAND_IO_SIZES
RAND_THREAD_SWEEP_IO_SIZE="${RAND_THREAD_SWEEP_IO_SIZE:-4K}"
RAND_THREADS_STR="${RAND_THREADS_STR-1 2 4 8 16 32}"
parse_words_var "RAND_THREADS_STR" "1 2 4 8 16 32" RAND_THREADS
RAND_DATASET_SIZE="${RAND_DATASET_SIZE:-1G}"
RAND_SEED="${RAND_SEED:-12345}"
RAND_USE_UNALIGNED="${RAND_USE_UNALIGNED:-0}"
RAND_FILL_BUFFER="${RAND_FILL_BUFFER:-0}"

MODES_STR="${MODES_STR-read write}"
parse_words_var "MODES_STR" "read write" MODES

BENCH_FAMILY="${BENCH_FAMILY:-all}"
case "${BENCH_FAMILY}" in
  all|io_size|threads) ;;
  *)
    echo "ERROR: unsupported BENCH_FAMILY=${BENCH_FAMILY} (expected all, io_size, or threads)" >&2
    exit 1
    ;;
esac

declare -a RUN_DATASETS=()
declare -A PREPARED_DATASETS=()
declare -A GDSIO_PIDS=()
PREPARED_DATASET_RESULT="0"

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

sanitize_name() {
  echo "$1" | sed 's#[ /]#_#g'
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

write_kv() {
  local out_file="$1"
  local key="$2"
  local value="$3"
  printf '%s=%s\n' "${key}" "${value}" >> "${out_file}"
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
  write_kv "${run_info}" "runtime_s" "${RUNTIME}"
  write_kv "${run_info}" "x_flags" "${X_FLAGS_STR}"
  write_kv "${run_info}" "repeats" "${REPEATS}"
  write_kv "${run_info}" "seq_io_sizes" "${SEQ_IO_SIZES_STR}"
  write_kv "${run_info}" "rand_io_sizes" "${RAND_IO_SIZES_STR}"
  write_kv "${run_info}" "seq_threads" "${SEQ_THREADS_STR}"
  write_kv "${run_info}" "rand_threads" "${RAND_THREADS_STR}"
  write_kv "${run_info}" "prep_datasets" "${PREPARE_DATASETS}"

  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi > "${META_DIR}/nvidia-smi.txt" 2>&1 || true
    nvidia-smi topo -m > "${META_DIR}/nvidia-smi-topo.txt" 2>&1 || true
  fi
  if [[ -x "${GDSCHECK_BIN}" ]]; then
    "${GDSCHECK_BIN}" -p > "${META_DIR}/gdscheck-platform.txt" 2>&1 || true
  fi
  lsblk -f > "${META_DIR}/lsblk-f.txt" 2>&1 || true
  mount > "${META_DIR}/mount.txt" 2>&1 || true
  lspci -tv > "${META_DIR}/lspci-tree.txt" 2>&1 || true
  if [[ -r "${NVFS_VERSION_PATH}" ]]; then
    cat "${NVFS_VERSION_PATH}" > "${META_DIR}/nvidia-fs-version.txt"
  fi
  if [[ -r "${NVFS_STATS_PATH}" ]]; then
    cat "${NVFS_STATS_PATH}" > "${META_DIR}/nvidia-fs-stats-initial.txt" 2>/dev/null || true
  fi
}

register_dataset() {
  RUN_DATASETS+=("$1")
}

dataset_key() {
  local logical_group="$1"
  local mode="$2"
  local x_flag="$3"
  local threads="$4"
  local dataset_size="$5"
  local repeat_id="$6"
  local key

  key="$(printf '%s__rep%s__th%s__size%s' \
    "$(sanitize_name "${logical_group}")" \
    "${repeat_id}" \
    "${threads}" \
    "$(sanitize_name "${dataset_size}")")"

  if [[ "${mode}" == "read" ]]; then
    printf '%s__shared_read' "${key}"
  else
    printf '%s__x%s' "${key}" "${x_flag}"
  fi
}

extract_metric() {
  local log_file="$1"
  local prefix="$2"
  sed -n "s/.*${prefix} \([^ ]*\).*/\1/p" "${log_file}" | tail -n 1
}

extract_xfertype() {
  local log_file="$1"
  sed -n 's/.*XferType: \([^ ]*\).*/\1/p' "${log_file}" | tail -n 1
}

extract_dataset_progress_kib() {
  local log_file="$1"
  sed -n 's/.*DataSetSize: \([0-9][0-9]*\)\/\([0-9][0-9]*\)(KiB).*/\1 \2/p' "${log_file}" | tail -n 1
}

resolve_prep_io_size() {
  local io_size="$1"
  if [[ -z "${PREP_IO_SIZE}" || "${PREP_IO_SIZE}" == "auto" ]]; then
    echo "${io_size}"
  else
    echo "${PREP_IO_SIZE}"
  fi
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
    printf 'reset ok\n' >> "${out_file}"
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

start_nvidia_dmon_sampler() {
  local out_file="$1"
  if [[ "${ENABLE_NVIDIA_DMON}" != "1" ]] || ! command -v nvidia-smi >/dev/null 2>&1; then
    return 0
  fi
  nvidia-smi dmon -s pucvmet -d "${NVIDIA_DMON_INTERVAL}" > "${out_file}" 2>&1 &
  echo "$!"
}

start_nvfs_sampler() {
  local out_file="$1"
  if [[ "${ENABLE_NVFS_SAMPLER}" != "1" || ! -r "${NVFS_STATS_PATH}" ]]; then
    return 0
  fi
  (
    while true; do
      date --iso-8601=seconds
      cat "${NVFS_STATS_PATH}" 2>/dev/null || printf 'read failed\n'
      sleep "${NVFS_SAMPLE_INTERVAL}"
    done
  ) > "${out_file}" 2>&1 &
  echo "$!"
}

start_gds_stats_sampler() {
  local pid="$1"
  local out_file="$2"
  if [[ "${ENABLE_GDS_STATS}" != "1" || ! -x "${GDS_STATS_BIN}" ]]; then
    return 0
  fi
  (
    while true; do
      date --iso-8601=seconds
      "${GDS_STATS_BIN}" -p "${pid}" 2>&1 || true
      sleep "${GDS_STATS_INTERVAL}"
    done
  ) > "${out_file}" 2>&1 &
  echo "$!"
}

capture_cufile_logs() {
  local marker_file="$1"
  local out_dir="$2"
  if [[ "${SAVE_CUFILE_LOGS}" != "1" || ! -d "${CUFILE_LOG_DIR}" ]]; then
    return
  fi
  mkdir -p "${out_dir}"
  find "${CUFILE_LOG_DIR}" -type f -newer "${marker_file}" -exec cp {} "${out_dir}/" \; 2>/dev/null || true
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
  local sweep_axis="$6"
  local repeat_id="$7"
  local x_flag="$8"
  local threads="$9"
  local dataset_size="${10}"
  local io_size="${11}"
  local exit_code="${12}"
  local case_dir="${13}"
  local gdsio_log="${14}"
  local prepared_dataset="${15}"
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
    "${sweep_axis}" \
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
  local logical_group="$1"
  local mode="$2"
  local x_flag="$3"
  local threads="$4"
  local dataset_size="$5"
  local repeat_id="$6"
  local dataset_dir="$7"
  local io_size="$8"
  local prepared_key

  if [[ "${PREPARE_DATASETS}" != "1" ]]; then
    PREPARED_DATASET_RESULT="0"
    return
  fi

  prepared_key="$(dataset_key "${logical_group}" "${mode}" "${x_flag}" "${threads}" "${dataset_size}" "${repeat_id}")"
  if [[ -n "${PREPARED_DATASETS[${prepared_key}]:-}" ]]; then
    PREPARED_DATASET_RESULT="1"
    return
  fi

  mkdir -p "${dataset_dir}"
  local prep_log="${dataset_dir}/prep_write.log"
  local prep_io_size
  prep_io_size="$(resolve_prep_io_size "${io_size}")"
  local attempt=1
  local current_duration="${PREP_DURATION}"
  local actual_kib="" target_kib="" fill_ratio=""
  while (( attempt <= PREP_MAX_ATTEMPTS )); do
    rm -rf "${dataset_dir:?}/"*
    echo "[PREP] creating dataset ${dataset_dir} (threads=${threads}, size=${dataset_size}, io_size=${prep_io_size}, duration=${current_duration}s, attempt=${attempt})" >&2
    set +e
    "${GDSIO}" -D "${dataset_dir}" -d "${GPU_ID}" -w "${threads}" -s "${dataset_size}" -i "${prep_io_size}" -x "${PREP_X_FLAG}" -I 1 -T "${current_duration}" > "${prep_log}" 2>&1
    local prep_rc="$?"
    set -e
    if [[ "${prep_rc}" != "0" ]]; then
      echo "ERROR: dataset preparation failed for ${dataset_dir}. See ${prep_log}" >&2
      exit "${prep_rc}"
    fi

    read -r actual_kib target_kib <<< "$(extract_dataset_progress_kib "${prep_log}")"
    if [[ -n "${actual_kib}" && -n "${target_kib}" ]]; then
      fill_ratio="$(awk -v actual="${actual_kib}" -v target="${target_kib}" 'BEGIN { if (target > 0) printf "%.6f", actual / target; }')"
      if awk -v ratio="${fill_ratio}" -v min_ratio="${PREP_MIN_FILL_RATIO}" 'BEGIN { exit !(ratio >= min_ratio) }'; then
        break
      fi
      echo "[PREP] dataset underfilled: actual=${actual_kib}KiB target=${target_kib}KiB ratio=${fill_ratio}; retrying" >&2
    else
      echo "[PREP] could not parse DataSetSize from ${prep_log}; retrying" >&2
    fi

    attempt=$((attempt + 1))
    current_duration=$((current_duration * 2))
  done

  if (( attempt > PREP_MAX_ATTEMPTS )); then
    echo "ERROR: dataset preparation did not reach fill ratio ${PREP_MIN_FILL_RATIO} for ${dataset_dir}. See ${prep_log}" >&2
    exit 1
  fi

  PREPARED_DATASETS["${prepared_key}"]="1"
  PREPARED_DATASET_RESULT="1"
}

run_case() {
  local test_group="$1"
  local mode="$2"
  local pattern="$3"
  local target_metric="$4"
  local sweep_axis="$5"
  local repeat_id="$6"
  local x_flag="$7"
  local threads="$8"
  local dataset_size="$9"
  local io_size="${10}"

  local safe_group safe_io case_name case_dir dataset_dir command_file case_info_file gdsio_log
  local exit_code_file mpstat_log pidstat_log iostat_log dmon_log gds_stats_log nvfs_before nvfs_after
  local nvfs_samples reset_log cufile_out_dir marker_file iotype prepared_dataset actual_xfer expected_xfer
  local gdsio_pid="" pidstat_pid="" mpstat_pid="" iostat_pid="" dmon_pid="" nvfs_pid="" gds_stats_pid=""

  safe_group="$(sanitize_name "${test_group}")"
  safe_io="$(sanitize_name "${io_size}")"
  case_name="${safe_group}__${mode}__x${x_flag}__th${threads}__io${safe_io}__rep${repeat_id}"
  case_dir="${CASES_DIR}/${case_name}"
  dataset_dir="${DATASET_ROOT}/$(dataset_key "${test_group}" "${mode}" "${x_flag}" "${threads}" "${dataset_size}" "${repeat_id}")"
  command_file="${case_dir}/command.sh"
  case_info_file="${case_dir}/case_info.txt"
  gdsio_log="${case_dir}/gdsio.log"
  exit_code_file="${case_dir}/exit_code.txt"
  mpstat_log="${case_dir}/mpstat.log"
  pidstat_log="${case_dir}/pidstat.log"
  iostat_log="${case_dir}/iostat.log"
  dmon_log="${case_dir}/nvidia-smi-dmon.log"
  gds_stats_log="${case_dir}/gds_stats.log"
  nvfs_before="${case_dir}/nvidia_fs_stats_before.txt"
  nvfs_after="${case_dir}/nvidia_fs_stats_after.txt"
  nvfs_samples="${case_dir}/nvidia_fs_stats_samples.log"
  reset_log="${case_dir}/nvidia_fs_stats_reset.txt"
  cufile_out_dir="${case_dir}/cufile_logs"
  marker_file="${case_dir}/cufile_marker"
  iotype="$(io_type_flag "${pattern}" "${mode}")"

  mkdir -p "${case_dir}" "${dataset_dir}"
  register_dataset "${dataset_dir}"
  prepare_dataset_if_needed "${test_group}" "${mode}" "${x_flag}" "${threads}" "${dataset_size}" "${repeat_id}" "${dataset_dir}" "${io_size}"
  prepared_dataset="${PREPARED_DATASET_RESULT}"

  : > "${case_info_file}"
  write_kv "${case_info_file}" "case_name" "${case_name}"
  write_kv "${case_info_file}" "test_group" "${test_group}"
  write_kv "${case_info_file}" "mode" "${mode}"
  write_kv "${case_info_file}" "pattern" "${pattern}"
  write_kv "${case_info_file}" "target_metric" "${target_metric}"
  write_kv "${case_info_file}" "sweep_axis" "${sweep_axis}"
  write_kv "${case_info_file}" "repeat_id" "${repeat_id}"
  write_kv "${case_info_file}" "x_flag" "${x_flag}"
  write_kv "${case_info_file}" "threads" "${threads}"
  write_kv "${case_info_file}" "dataset_size" "${dataset_size}"
  write_kv "${case_info_file}" "io_size" "${io_size}"
  write_kv "${case_info_file}" "dataset_dir" "${dataset_dir}"
  write_kv "${case_info_file}" "prepared_dataset" "${prepared_dataset}"

  reset_nvfs_stats_if_possible "${reset_log}"
  snapshot_nvfs_stats "${nvfs_before}"
  : > "${marker_file}"

  cat > "${command_file}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"${GDSIO}" -D "${dataset_dir}" -d "${GPU_ID}" -w "${threads}" -s "${dataset_size}" -i "${io_size}" -x "${x_flag}" -I "${iotype}" -T "${RUNTIME}"$( [[ "${VERIFY}" == "1" ]] && printf ' -V' )$( [[ "${pattern}" == "rand" ]] && printf ' -k %s' "${RAND_SEED}" )$( [[ "${pattern}" == "rand" && "${RAND_USE_UNALIGNED}" == "1" ]] && printf ' -U 1' )$( [[ "${pattern}" == "rand" && "${RAND_FILL_BUFFER}" == "1" ]] && printf ' -R 1' )
EOF
  chmod +x "${command_file}"

  mpstat_pid="$(start_mpstat_sampler "${mpstat_log}" || true)"
  iostat_pid="$(start_iostat_sampler "${iostat_log}" || true)"
  dmon_pid="$(start_nvidia_dmon_sampler "${dmon_log}" || true)"
  nvfs_pid="$(start_nvfs_sampler "${nvfs_samples}" || true)"

  set +e
  "${command_file}" > "${gdsio_log}" 2>&1 &
  gdsio_pid="$!"
  GDSIO_PIDS["${case_name}"]="${gdsio_pid}"
  set -e

  pidstat_pid="$(start_pidstat_sampler "${gdsio_pid}" "${pidstat_log}" || true)"
  gds_stats_pid="$(start_gds_stats_sampler "${gdsio_pid}" "${gds_stats_log}" || true)"

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
  stop_pid_if_alive "${dmon_pid}"
  stop_pid_if_alive "${nvfs_pid}"
  stop_pid_if_alive "${gds_stats_pid}"
  snapshot_nvfs_stats "${nvfs_after}"
  capture_cufile_logs "${marker_file}" "${cufile_out_dir}"
  append_summary_row "${case_name}" "${test_group}" "${mode}" "${pattern}" "${target_metric}" "${sweep_axis}" "${repeat_id}" "${x_flag}" "${threads}" "${dataset_size}" "${io_size}" "${exit_code}" "${case_dir}" "${gdsio_log}" "${prepared_dataset}"

  if [[ "${VERIFY_XFER_LABEL}" == "1" ]]; then
    expected_xfer="$(xfer_label "${x_flag}")"
    actual_xfer="$(extract_xfertype "${gdsio_log}")"
    if [[ -n "${actual_xfer}" && "${actual_xfer}" != "${expected_xfer}" ]]; then
      printf 'WARNING: expected XferType %s, got %s\n' "${expected_xfer}" "${actual_xfer}" | tee -a "${case_info_file}" >&2
    fi
  fi

  if [[ "${exit_code}" != "0" ]]; then
    echo "ERROR: case failed: ${case_name}" >&2
    return "${exit_code}"
  fi
}

run_matrix() {
  local repeat_id x_flag io_size threads mode

  for repeat_id in $(seq 1 "${REPEATS}"); do
    for x_flag in "${X_FLAGS[@]}"; do
      for mode in "${MODES[@]}"; do
        case "${BENCH_FAMILY}" in
          all|io_size)
            for io_size in "${SEQ_IO_SIZES[@]}"; do
              run_case "io_size_sweep_throughput" "${mode}" "seq" "throughput" "io_size" "${repeat_id}" "${x_flag}" "${SEQ_IO_SWEEP_THREADS}" "${SEQ_DATASET_SIZE}" "${io_size}"
            done

            for io_size in "${RAND_IO_SIZES[@]}"; do
              run_case "io_size_sweep_iops" "${mode}" "rand" "iops_latency" "io_size" "${repeat_id}" "${x_flag}" "${RAND_IO_SWEEP_THREADS}" "${RAND_DATASET_SIZE}" "${io_size}"
            done
            ;;
        esac

        case "${BENCH_FAMILY}" in
          all|threads)
            for threads in "${SEQ_THREADS[@]}"; do
              run_case "thread_sweep_throughput" "${mode}" "seq" "throughput" "threads" "${repeat_id}" "${x_flag}" "${threads}" "${SEQ_DATASET_SIZE}" "${SEQ_THREAD_SWEEP_IO_SIZE}"
            done

            for threads in "${RAND_THREADS[@]}"; do
              run_case "thread_sweep_iops" "${mode}" "rand" "iops_latency" "threads" "${repeat_id}" "${x_flag}" "${threads}" "${RAND_DATASET_SIZE}" "${RAND_THREAD_SWEEP_IO_SIZE}"
            done
            ;;
        esac
      done
    done
  done
}

echo "[INFO] gdsio             : ${GDSIO}"
echo "[INFO] target_dir        : ${TARGET_DIR}"
echo "[INFO] dataset_root      : ${DATASET_ROOT}"
echo "[INFO] gpu_id            : ${GPU_ID}"
echo "[INFO] runtime           : ${RUNTIME}"
echo "[INFO] repeats           : ${REPEATS}"
echo "[INFO] output_root       : ${RUN_ROOT}"
echo "[INFO] seq_io_sizes      : ${SEQ_IO_SIZES_STR}"
echo "[INFO] rand_io_sizes     : ${RAND_IO_SIZES_STR}"
echo "[INFO] seq_threads       : ${SEQ_THREADS_STR}"
echo "[INFO] rand_threads      : ${RAND_THREADS_STR}"
echo "[INFO] x_flags           : ${X_FLAGS_STR}"
echo "[INFO] prepare_datasets  : ${PREPARE_DATASETS}"

if [[ "${SAVE_META}" == "1" ]]; then
  capture_meta
fi
init_summary_csv
run_matrix

echo "[DONE] summary : ${SUMMARY_CSV}"
echo "[DONE] cases   : ${CASES_DIR}"
