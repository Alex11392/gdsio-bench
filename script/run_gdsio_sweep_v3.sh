#!/usr/bin/env bash
set -euo pipefail

GDSIO=${GDSIO:-/usr/local/cuda/gds/tools/gdsio}
OUT_ROOT=${OUT_ROOT:-/home/poc/gds_bench/results}
TESTFILE=${TESTFILE:-/mnt/nvme0/gds_test/testfile_v3}
DEVICE=${DEVICE:-/dev/nvme0n1}
GPU=${GPU:-0}
DATASET_SIZE=${DATASET_SIZE:-10G}
DURATION=${DURATION:-120}
WARMUP=${WARMUP:-2}
COOLDOWN=${COOLDOWN:-3}
REPS=${REPS:-3}
MODES_STR=${MODES_STR:-"0 2"}
PATTERNS_STR=${PATTERNS_STR:-"0 2"}
SIZES_KIB_STR=${SIZES_KIB_STR:-"4 8 16 32 64 128 256 512 1024 2048 4096"}
THREADS_STR=${THREADS_STR:-"1 2 4 8 16 32"}
IO_SWEEP_THREADS=${IO_SWEEP_THREADS:-16}
THREAD_SWEEP_SIZE_KIB=${THREAD_SWEEP_SIZE_KIB:-4}
LOCK_MEMORY_CLOCK=${LOCK_MEMORY_CLOCK:-1}
MEMORY_CLOCK=${MEMORY_CLOCK:-10001}
PRECONDITION=${PRECONDITION:-full} # none|quick|full; inspired by paper FIO SSD preconditioning
PRECOND_SIZE=${PRECOND_SIZE:-256G}
PRECOND_ROUNDS=${PRECOND_ROUNDS:-1}
PRECOND_FREE_RESERVE=${PRECOND_FREE_RESERVE:-8G}
MOUNT_POINT=${MOUNT_POINT:-/mnt/nvme0}
ENABLE_PERF=${ENABLE_PERF:-1}
ENABLE_PIDSTAT=${ENABLE_PIDSTAT:-1}
ENABLE_IOSTAT=${ENABLE_IOSTAT:-1}
ENABLE_MPSTAT=${ENABLE_MPSTAT:-1}
ENABLE_PCIE_MONITOR=${ENABLE_PCIE_MONITOR:-1}
ENABLE_PERF_RECORD=${ENABLE_PERF_RECORD:-1}
PERF_RECORD_SECONDS=${PERF_RECORD_SECONDS:-30}
GDSIO_TIMEOUT=${GDSIO_TIMEOUT:-$((DURATION + 180))}

TS=$(date +%Y%m%d_%H%M%S)
RUNDIR="${OUT_ROOT}/gdsio_sweep_v3_${TS}"
RAW_DIR="${RUNDIR}/raw"
MASTER="${RUNDIR}/master.csv"
PARSER="$(dirname "$0")/parse_gdsio_sweep_v3.py"
mkdir -p "$RAW_DIR"

CSV_HEADER="mode,pattern,io_size_kib,threads,rep,dataset_size,duration_s,exit_code,xfertype,throughput_gibs,avg_lat_us,iops,ops,total_time_s,active_cores,total_cpu_pct,gdsio_cpu_pct,gdsio_usr_pct,gdsio_sys_pct,dram_read_mibs,dram_write_mibs,ssd_r_mbs,ssd_w_mbs,ssd_r_await_ms,ssd_w_await_ms,ssd_aqu_sz,ssd_util_pct,pcie_min_gen,pcie_max_gen,pcie_saw_gen4,pcie_saw_downshift"
echo "$CSV_HEADER" > "$MASTER"

cat > "${RUNDIR}/run_config.env" <<EOF
GDSIO=$GDSIO
TESTFILE=$TESTFILE
DEVICE=$DEVICE
GPU=$GPU
DATASET_SIZE=$DATASET_SIZE
DURATION=$DURATION
WARMUP=$WARMUP
COOLDOWN=$COOLDOWN
REPS=$REPS
MODES_STR=$MODES_STR
PATTERNS_STR=$PATTERNS_STR
SIZES_KIB_STR=$SIZES_KIB_STR
THREADS_STR=$THREADS_STR
IO_SWEEP_THREADS=$IO_SWEEP_THREADS
THREAD_SWEEP_SIZE_KIB=$THREAD_SWEEP_SIZE_KIB
LOCK_MEMORY_CLOCK=$LOCK_MEMORY_CLOCK
MEMORY_CLOCK=$MEMORY_CLOCK
PRECONDITION=$PRECONDITION
PRECOND_SIZE=$PRECOND_SIZE
PRECOND_ROUNDS=$PRECOND_ROUNDS
PRECOND_FREE_RESERVE=$PRECOND_FREE_RESERVE
MOUNT_POINT=$MOUNT_POINT
ENABLE_PERF=$ENABLE_PERF
ENABLE_PIDSTAT=$ENABLE_PIDSTAT
ENABLE_IOSTAT=$ENABLE_IOSTAT
ENABLE_MPSTAT=$ENABLE_MPSTAT
ENABLE_PCIE_MONITOR=$ENABLE_PCIE_MONITOR
ENABLE_PERF_RECORD=$ENABLE_PERF_RECORD
PERF_RECORD_SECONDS=$PERF_RECORD_SECONDS
GDSIO_TIMEOUT=$GDSIO_TIMEOUT
EOF

size_to_bytes() {
  numfmt --from=iec "$1"
}

# gdsio -s only accepts K|M|G; convert any IEC size to the largest G multiple.
to_gdsio_size() {
  local bytes
  bytes=$(numfmt --from=iec "$1")
  echo "$((bytes / 1073741824))G"
}

require_existing_dataset() {
  local required existing
  required=$(size_to_bytes "$DATASET_SIZE")
  if [[ ! -f "$TESTFILE" ]]; then
    echo "ERROR: dataset does not exist: $TESTFILE" >&2
    echo "Set PRECONDITION=quick or PRECONDITION=full to create/precondition it." >&2
    exit 1
  fi
  existing=$(stat -c %s "$TESTFILE")
  if [[ "$existing" -lt "$required" ]]; then
    echo "ERROR: dataset too small: $TESTFILE has ${existing} bytes, needs ${required} bytes" >&2
    echo "For 120s tests, use a larger dataset, e.g. DATASET_SIZE=1T." >&2
    exit 1
  fi
}

create_testfile() {
  rm -f "$TESTFILE"
  mkdir -p "$(dirname "$TESTFILE")"
  echo "[$(date +%H:%M:%S)] creating testfile: $TESTFILE size=$DATASET_SIZE (fallocate + dd bs=1M)"
  # fallocate first so EXT4 allocates one contiguous region, then dd to initialize.
  # fio bs=128K causes scattered extents after preconditioning; fallocate+dd avoids this.
  fallocate -l "$DATASET_SIZE" "$TESTFILE"
  dd if=/dev/zero of="$TESTFILE" bs=1M oflag=direct conv=notrunc \
    count=$(( $(numfmt --from=iec "$DATASET_SIZE") / 1048576 )) \
    > "${RUNDIR}/testfile_create.log" 2>&1
  sync
}

run_fio_precondition() {
  local size=$1
  local round=$2
  local label=${3:-}
  local prefix="${RUNDIR}/fio_precond${label:+_${label}}_round${round}"
  local seq_log="${prefix}_seq.log"
  local rand_log="${prefix}_rand.log"
  echo "[$(date +%H:%M:%S)] FIO sequential precondition round ${round}, size=${size}, rw=write, bs=128k"
  fio --name="precond_seq_r${round}" --filename="$TESTFILE" --rw=write --bs=128k \
    --direct=1 --size="$size" --iodepth=32 --numjobs=1 --group_reporting \
    > "$seq_log" 2>&1
  sync
  echo "[$(date +%H:%M:%S)] FIO random precondition round ${round}, size=${size}, rw=randwrite, bs=4k"
  fio --name="precond_rand_r${round}" --filename="$TESTFILE" --rw=randwrite --bs=4k \
    --direct=1 --size="$size" --iodepth=32 --numjobs=1 --group_reporting \
    > "$rand_log" 2>&1
  sync
}

compute_full_precond_size() {
  local avail_b reserve_b fill_b
  avail_b=$(df -B1 --output=avail "$MOUNT_POINT" | tail -n 1 | tr -d ' ')
  reserve_b=$(size_to_bytes "$PRECOND_FREE_RESERVE")
  if [[ -z "$avail_b" || "$avail_b" -le "$reserve_b" ]]; then
    echo "ERROR: not enough free space on $MOUNT_POINT for full preconditioning: avail=${avail_b:-unknown}, reserve=${reserve_b}" >&2
    exit 1
  fi
  fill_b=$(( avail_b - reserve_b ))
  echo "$fill_b"
}

precondition_dataset() {
  case "$PRECONDITION" in
    none)
      require_existing_dataset
      ;;
    quick)
      local round
      for round in $(seq 1 "$PRECOND_ROUNDS"); do
        run_fio_precondition "$PRECOND_SIZE" "$round"
      done
      create_testfile
      require_existing_dataset
      ;;
    full)
      # Unmount → mkfs.ext4 → remount → FIO fill the usable filesystem area.
      # Use df after mkfs instead of blockdev size because EXT4 metadata is not writable file space.
      local device_b fill_b
      device_b=$(sudo blockdev --getsize64 "$DEVICE")
      echo "[$(date +%H:%M:%S)] PRECONDITION=full: device=$(numfmt --to=iec $device_b)"

      echo "[$(date +%H:%M:%S)] umount $DEVICE"
      sudo umount "$DEVICE" > "${RUNDIR}/precond_umount.log" 2>&1

      echo "[$(date +%H:%M:%S)] mkfs.ext4 $DEVICE"
      sudo mkfs.ext4 -F "$DEVICE" > "${RUNDIR}/precond_mkfs.log" 2>&1

      echo "[$(date +%H:%M:%S)] mount $DEVICE $MOUNT_POINT"
      sudo mount "$DEVICE" "$MOUNT_POINT" > "${RUNDIR}/precond_mount.log" 2>&1
      sudo chown -R "$(id -u):$(id -g)" "$MOUNT_POINT"
      mkdir -p "$(dirname "$TESTFILE")"
      fill_b=$(compute_full_precond_size)
      echo "[$(date +%H:%M:%S)] full precondition fill size=$(numfmt --to=iec "$fill_b"), reserve=${PRECOND_FREE_RESERVE}"

      local round
      for round in $(seq 1 "$PRECOND_ROUNDS"); do
        run_fio_precondition "$fill_b" "$round"
      done
      create_testfile
      require_existing_dataset
      ;;
    *)
      echo "ERROR: PRECONDITION must be none, quick, or full" >&2
      exit 1
      ;;
  esac
}

lock_memory_clock() {
  if [[ "$LOCK_MEMORY_CLOCK" == "1" ]]; then
    nvidia-smi -i "$GPU" --query-gpu=index,pci.bus_id,persistence_mode,pstate,clocks.mem,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits > "${RUNDIR}/nvidia_smi_before_memlock.csv"
    sudo nvidia-smi -i "$GPU" -pm 1 > "${RUNDIR}/nvidia_smi_pm.log" 2>&1 || true
    sudo nvidia-smi -i "$GPU" -lmc "${MEMORY_CLOCK},${MEMORY_CLOCK}" > "${RUNDIR}/nvidia_smi_lmc.log" 2>&1
    nvidia-smi -i "$GPU" --query-gpu=index,pci.bus_id,persistence_mode,pstate,clocks.mem,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits > "${RUNDIR}/nvidia_smi_after_memlock.csv"
  fi
}

restore_memory_clock() {
  if [[ "$LOCK_MEMORY_CLOCK" == "1" ]]; then
    sudo nvidia-smi -i "$GPU" -rmc > "${RUNDIR}/nvidia_smi_rmc.log" 2>&1 || true
    sudo nvidia-smi -i "$GPU" -rac > "${RUNDIR}/nvidia_smi_rac.log" 2>&1 || true
    nvidia-smi -i "$GPU" --query-gpu=index,pci.bus_id,persistence_mode,pstate,clocks.mem,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits > "${RUNDIR}/nvidia_smi_after_restore.csv" 2>/dev/null || true
  fi
}

trap restore_memory_clock EXIT

build_perf_events() {
  local events=()
  local dev name
  for dev in /sys/bus/event_source/devices/uncore_imc_*; do
    [[ -d "$dev" ]] || continue
    name=$(basename "$dev")
    [[ "$name" == *free_running* ]] && continue
    events+=("${name}/cas_count_read/" "${name}/cas_count_write/")
  done
  local IFS=,
  echo "${events[*]}"
}

label_mode() {
  case "$1" in
    0) echo gds ;;
    2) echo cpu ;;
    *) echo "x$1" ;;
  esac
}

label_pattern() {
  case "$1" in
    0) echo seq ;;
    2) echo rand ;;
    *) echo "I$1" ;;
  esac
}

monitor_pcie() {
  local outfile=$1
  local total=$2
  printf "timestamp,bus_id,gen_current,gen_max,width_current,width_max\n" > "$outfile"
  local end=$((SECONDS + total))
  while [[ "$SECONDS" -lt "$end" ]]; do
    local ts
    ts=$(date +%s)
    nvidia-smi -i "$GPU" --query-gpu=pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max \
      --format=csv,noheader,nounits | sed "s/^/${ts},/" >> "$outfile"
    sleep 1
  done
}

wait_pid() {
  local pid=${1:-}
  if [[ -n "$pid" ]]; then
    wait "$pid" 2>/dev/null || true
  fi
}

run_one() {
  local mode=$1 pattern=$2 io_size=$3 threads=$4 rep=$5
  local mode_label pattern_label tag case_dir total perf_events
  mode_label=$(label_mode "$mode")
  pattern_label=$(label_pattern "$pattern")
  tag="${mode_label}_${pattern_label}_${io_size}k_t${threads}_r${rep}"
  case_dir="${RAW_DIR}/${tag}"
  total=$((WARMUP + DURATION + COOLDOWN))
  mkdir -p "$case_dir"

  cat > "${case_dir}/case.env" <<EOF
MODE=$mode
MODE_LABEL=$mode_label
PATTERN=$pattern
PATTERN_LABEL=$pattern_label
IO_SIZE_KIB=$io_size
THREADS=$threads
REP=$rep
DATASET_SIZE=$DATASET_SIZE
EOF

  echo "[$(date +%H:%M:%S)] $tag"

  local mp_pid="" perf_pid="" iostat_pid="" pcie_pid=""
  if [[ "$ENABLE_MPSTAT" == "1" ]]; then
    mpstat -P ALL 1 "$total" > "${case_dir}/mpstat.log" 2>&1 &
    mp_pid=$!
  fi
  if [[ "$ENABLE_IOSTAT" == "1" ]]; then
    iostat -x "$DEVICE" 1 "$total" > "${case_dir}/iostat.log" 2>&1 &
    iostat_pid=$!
  fi
  if [[ "$ENABLE_PERF" == "1" ]]; then
    perf_events=$(build_perf_events)
    sudo perf stat -x ',' -e "$perf_events" -a sleep "$total" > "${case_dir}/perf.log" 2>&1 &
    perf_pid=$!
  fi
  if [[ "$ENABLE_PCIE_MONITOR" == "1" ]]; then
    monitor_pcie "${case_dir}/pcie_link.csv" "$total" &
    pcie_pid=$!
  fi

  sleep "$WARMUP"

  set +e
  "$GDSIO" -f "$TESTFILE" -d "$GPU" -w "$threads" \
    -s "$(to_gdsio_size "$DATASET_SIZE")" -i "${io_size}K" -x "$mode" -I "$pattern" -T "$DURATION" \
    > "${case_dir}/gdsio.log" 2>&1 &
  local gdsio_pid=$!
  (
    sleep "$GDSIO_TIMEOUT"
    if kill -0 "$gdsio_pid" 2>/dev/null; then
      echo "gdsio timed out after ${GDSIO_TIMEOUT}s" >> "${case_dir}/gdsio.log"
      kill "$gdsio_pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid=$!
  local pidstat_pid=""
  local perf_record_pid=""
  if [[ "$ENABLE_PIDSTAT" == "1" ]]; then
    pidstat -t -u -r -d -p "$gdsio_pid" 1 "$DURATION" > "${case_dir}/pidstat.log" 2>&1 &
    pidstat_pid=$!
  fi
  if [[ "$ENABLE_PERF_RECORD" == "1" ]]; then
    sudo perf record -g -p "$gdsio_pid" -o "${case_dir}/perf.data" -- sleep "$PERF_RECORD_SECONDS" \
      > "${case_dir}/perf_record.log" 2>&1 &
    perf_record_pid=$!
  fi
  wait "$gdsio_pid"
  local exit_code=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  set -e

  wait_pid "$pidstat_pid"
  wait_pid "$perf_record_pid"
  wait_pid "$mp_pid"
  wait_pid "$perf_pid"
  wait_pid "$iostat_pid"
  wait_pid "$pcie_pid"

  python3 "$PARSER" "$case_dir" "$mode_label" "$pattern_label" "$io_size" "$threads" "$rep" \
    "$WARMUP" "$DURATION" "$COOLDOWN" "$DATASET_SIZE" "$exit_code" "$DEVICE" >> "$MASTER"
  sleep 1
}

echo "Run dir: $RUNDIR"
precondition_dataset
lock_memory_clock

# IO size sweep: vary io_size, threads fixed at IO_SWEEP_THREADS
for mode in $MODES_STR; do
  for pattern in $PATTERNS_STR; do
    for io_size in $SIZES_KIB_STR; do
      for rep in $(seq 1 "$REPS"); do
        run_one "$mode" "$pattern" "$io_size" "$IO_SWEEP_THREADS" "$rep"
      done
    done
  done
done

# Thread sweep: vary threads, io_size fixed at THREAD_SWEEP_SIZE_KIB
# Skip IO_SWEEP_THREADS to avoid duplicate directory with io_size sweep above.
for mode in $MODES_STR; do
  for pattern in $PATTERNS_STR; do
    for threads in $THREADS_STR; do
      [[ "$threads" == "$IO_SWEEP_THREADS" ]] && continue
      for rep in $(seq 1 "$REPS"); do
        run_one "$mode" "$pattern" "$THREAD_SWEEP_SIZE_KIB" "$threads" "$rep"
      done
    done
  done
done

restore_memory_clock
trap - EXIT

echo "=== DONE ==="
echo "Run dir: $RUNDIR"
echo "Master CSV: $MASTER"
