#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ===== User config =====
GDSIO="${GDSIO:-/usr/local/cuda/gds/tools/gdsio}"
TARGET_DIR="${TARGET_DIR:-/mnt/nvme0}"
GPU_ID="${GPU_ID:-0}"
RUNTIME="${RUNTIME:-30}"
VERIFY="${VERIFY:-0}"

# cleanup behavior
CLEAN_DATASET="${CLEAN_DATASET:-0}"   # 1 = delete dataset dir before each case
CLEAN_ON_EXIT="${CLEAN_ON_EXIT:-0}"   # 1 = delete all datasets created by this run at the end

# unique run id to avoid naming conflicts
RUN_TAG="${RUN_TAG:-g${GPU_ID}_$(date +%Y%m%d_%H%M%S)_$$}"

# xfer modes:
# 0 = GDS
# 2 = CPU bounce path
XFER_TYPES_STR="${XFER_TYPES_STR:-0 2}"
read -r -a XFER_TYPES <<< "${XFER_TYPES_STR}"

SEQ_BS_LIST_STR="${SEQ_BS_LIST_STR:-1M 4M}"
read -r -a SEQ_BS_LIST <<< "${SEQ_BS_LIST_STR}"

SEQ_WORKERS_STR="${SEQ_WORKERS_STR:-4 8 16 32}"
read -r -a SEQ_WORKERS <<< "${SEQ_WORKERS_STR}"

RAND_BS_LIST_STR="${RAND_BS_LIST_STR:-4K 16K}"
read -r -a RAND_BS_LIST <<< "${RAND_BS_LIST_STR}"

RAND_WORKERS_STR="${RAND_WORKERS_STR:-4 8 16 32 64 128}"
read -r -a RAND_WORKERS <<< "${RAND_WORKERS_STR}"

SEQ_SIZE="${SEQ_SIZE:-1G}"
RAND_SIZE="${RAND_SIZE:-1G}"
RAND_SEED="${RAND_SEED:-12345}"
RUN_SEQ="${RUN_SEQ:-1}"
RUN_RAND="${RUN_RAND:-1}"
SAVE_ENV_SNAPSHOT="${SAVE_ENV_SNAPSHOT:-1}"
RESULTS_ROOT="${RESULTS_ROOT:-${PROJECT_ROOT}/results}"
RESULT_BATCH="${RESULT_BATCH:-$(date +%Y%m%d_%H%M%S)}"

infer_mode_name() {
  if [[ "${#XFER_TYPES[@]}" -eq 1 ]]; then
    case "${XFER_TYPES[0]}" in
      0) echo "gds" ;;
      2) echo "cpu_bounce" ;;
      *) echo "all_modes" ;;
    esac
    return
  fi

  echo "all_modes"
}

MODE_NAME="${MODE_NAME:-$(infer_mode_name)}"
OUT_DIR="${OUT_DIR:-${RESULTS_ROOT}/${RESULT_BATCH}/${MODE_NAME}/gpu_${GPU_ID}}"
RUN_DATA_DIR="${RUN_DATA_DIR:-${TARGET_DIR}/${RUN_TAG}}"

mkdir -p "${RUN_DATA_DIR}" "${OUT_DIR}"

if [[ ! -x "${GDSIO}" ]]; then
  echo "ERROR: gdsio not found or not executable at: ${GDSIO}"
  exit 1
fi

declare -a CREATED_DATASETS=()

register_dataset() {
  local ds="$1"
  CREATED_DATASETS+=("$ds")
}

cleanup_dataset_if_needed() {
  local ds="$1"
  if [[ "${CLEAN_DATASET}" == "1" && -e "${ds}" ]]; then
    echo "[CLEAN] Removing existing dataset: ${ds}"
    rm -rf -- "${ds}"
  fi
}

cleanup_all_datasets_on_exit() {
  if [[ "${CLEAN_ON_EXIT}" == "1" ]]; then
    echo "[CLEAN] Removing all datasets created in this run..."
    if [[ "${#CREATED_DATASETS[@]}" -gt 0 ]]; then
      for ds in "${CREATED_DATASETS[@]}"; do
        [[ -e "${ds}" ]] && rm -rf -- "${ds}"
      done
    fi
    rmdir "${RUN_DATA_DIR}" 2>/dev/null || true
  fi
}
trap cleanup_all_datasets_on_exit EXIT

dataset_dir() {
  local kind="$1"   # seq or rand
  local x="$2"
  local bs="$3"
  local w="$4"
  echo "${RUN_DATA_DIR}/${kind}_x${x}_bs${bs}_w${w}"
}

run_case() {
  local name="$1"
  shift
  local log="${OUT_DIR}/${name}.log"

  echo "============================================================"
  echo "[RUN] ${name}"
  echo "CMD : $*"
  echo "LOG : ${log}"
  echo "============================================================"

  {
    echo "# ${name}"
    echo "# $(date)"
    echo "# CMD: $*"
    "$@"
    echo
  } | tee "${log}"
}

run_gdsio_case() {
  local name="$1"
  shift
  local -a cmd=("$@")

  if [[ "${VERIFY}" == "1" ]]; then
    cmd+=(-V)
  fi

  run_case "${name}" "${cmd[@]}"
}

echo "[INFO] Output dir      : ${OUT_DIR}"
echo "[INFO] Target dir      : ${TARGET_DIR}"
echo "[INFO] Run data dir    : ${RUN_DATA_DIR}"
echo "[INFO] GPU id          : ${GPU_ID}"
echo "[INFO] Runtime         : ${RUNTIME}s"
echo "[INFO] gdsio           : ${GDSIO}"
echo "[INFO] Script dir      : ${SCRIPT_DIR}"
echo "[INFO] Project root    : ${PROJECT_ROOT}"
echo "[INFO] Results root    : ${RESULTS_ROOT}"
echo "[INFO] Result batch    : ${RESULT_BATCH}"
echo "[INFO] Mode name       : ${MODE_NAME}"
echo "[INFO] Run tag         : ${RUN_TAG}"
echo "[INFO] Clean dataset   : ${CLEAN_DATASET}"
echo "[INFO] Clean on exit   : ${CLEAN_ON_EXIT}"
echo "[INFO] Xfer types      : ${XFER_TYPES[*]}"
echo "[INFO] Run seq         : ${RUN_SEQ}"
echo "[INFO] Run rand        : ${RUN_RAND}"

# ------------------------------------------------------------
# 0) Optional environment snapshot
# ------------------------------------------------------------
if [[ "${SAVE_ENV_SNAPSHOT}" == "1" ]]; then
  {
    echo "# uname -a"; uname -a
    echo
    echo "# nvidia-smi topo -m"; nvidia-smi topo -m || true
    echo
    echo "# lsblk"; lsblk || true
    echo
    echo "# mount"; mount | grep -E "${TARGET_DIR}|/mnt|nvme|lustre|weka|nfs" || true
  } > "${OUT_DIR}/env_snapshot.txt" 2>&1
fi

# ------------------------------------------------------------
# 1) Sequential write/read benchmark
# ------------------------------------------------------------
if [[ "${RUN_SEQ}" == "1" ]]; then
  for x in "${XFER_TYPES[@]}"; do
    for bs in "${SEQ_BS_LIST[@]}"; do
      for w in "${SEQ_WORKERS[@]}"; do
        ds="$(dataset_dir seq "${x}" "${bs}" "${w}")"
        cleanup_dataset_if_needed "${ds}"
        mkdir -p "${ds}"
        register_dataset "${ds}"

        run_gdsio_case "seq_write_x${x}_bs${bs}_w${w}" \
          "${GDSIO}" \
          -D "${ds}" \
          -d "${GPU_ID}" \
          -w "${w}" \
          -s "${SEQ_SIZE}" \
          -i "${bs}" \
          -x "${x}" \
          -I 1 \
          -T "${RUNTIME}"

        run_gdsio_case "seq_read_x${x}_bs${bs}_w${w}" \
          "${GDSIO}" \
          -D "${ds}" \
          -d "${GPU_ID}" \
          -w "${w}" \
          -s "${SEQ_SIZE}" \
          -i "${bs}" \
          -x "${x}" \
          -I 0 \
          -T "${RUNTIME}"
      done
    done
  done
fi

# ------------------------------------------------------------
# 2) Random write/read benchmark
# ------------------------------------------------------------
# Note: use same seed for randwrite/randread pairs if you enable verify.

if [[ "${RUN_RAND}" == "1" ]]; then
  for x in "${XFER_TYPES[@]}"; do
    for bs in "${RAND_BS_LIST[@]}"; do
      for w in "${RAND_WORKERS[@]}"; do
        ds="$(dataset_dir rand "${x}" "${bs}" "${w}")"
        cleanup_dataset_if_needed "${ds}"
        mkdir -p "${ds}"
        register_dataset "${ds}"

        run_gdsio_case "rand_write_x${x}_bs${bs}_w${w}" \
          "${GDSIO}" \
          -D "${ds}" \
          -d "${GPU_ID}" \
          -w "${w}" \
          -s "${RAND_SIZE}" \
          -i "${bs}" \
          -x "${x}" \
          -I 3 \
          -k "${RAND_SEED}" \
          -T "${RUNTIME}"

        run_gdsio_case "rand_read_x${x}_bs${bs}_w${w}" \
          "${GDSIO}" \
          -D "${ds}" \
          -d "${GPU_ID}" \
          -w "${w}" \
          -s "${RAND_SIZE}" \
          -i "${bs}" \
          -x "${x}" \
          -I 2 \
          -k "${RAND_SEED}" \
          -T "${RUNTIME}"
      done
    done
  done
fi

# ------------------------------------------------------------
# 3) Simple summary extraction
# ------------------------------------------------------------
SUMMARY_CSV="${OUT_DIR}/summary.csv"
echo "name,iotype,xfertype,threads,dataset_kib,iosize_kib,throughput_gib_s,avg_latency_us,ops,total_time_s" > "${SUMMARY_CSV}"

shopt -s nullglob
for f in "${OUT_DIR}"/*.log; do
  line="$(grep -E 'IoType:' "$f" | tail -n 1 || true)"
  if [[ -n "${line}" ]]; then
    name="$(basename "$f" .log)"
    iotype="$(echo "$line" | sed -n 's/.*IoType: \([^ ]*\).*/\1/p')"
    xfertype="$(echo "$line" | sed -n 's/.*XferType: \([^ ]*\).*/\1/p')"
    threads="$(echo "$line" | sed -n 's/.*Threads: \([^ ]*\).*/\1/p')"
    dataset="$(echo "$line" | sed -n 's/.*DataSetSize: \([^ ]*\).*/\1/p')"
    iosize="$(echo "$line" | sed -n 's/.*IOSize: \([^ ]*\).*/\1/p')"
    tp="$(echo "$line" | sed -n 's/.*Throughput: \([^ ]*\) GiB\/sec.*/\1/p')"
    lat="$(echo "$line" | sed -n 's/.*Avg_Latency: \([^ ]*\) usecs.*/\1/p')"
    ops="$(echo "$line" | sed -n 's/.* ops: \([^ ]*\) total_time.*/\1/p')"
    tsec="$(echo "$line" | sed -n 's/.* total_time \([^ ]*\) secs.*/\1/p')"
    echo "${name},${iotype},${xfertype},${threads},${dataset},${iosize},${tp},${lat},${ops},${tsec}" >> "${SUMMARY_CSV}"
  fi
done
shopt -u nullglob

echo
echo "[DONE] Summary CSV: ${SUMMARY_CSV}"
echo "[DONE] Raw logs    : ${OUT_DIR}"

