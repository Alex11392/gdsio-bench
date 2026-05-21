#!/usr/bin/env bash
# Dump top-N hot functions for every case in a focused gdsio run.
#   Usage: script/analyze_focused_perf.sh <run_dir> [top_n]
set -euo pipefail

RUN_DIR="${1:?Usage: $0 <run_dir> [top_n]}"
TOP_N="${2:-12}"

if [[ ! -d "${RUN_DIR}/raw" ]]; then
  echo "ERROR: no raw/ subdir under ${RUN_DIR}" >&2
  exit 1
fi

out="${RUN_DIR}/perf_top_funcs.txt"
echo "Writing perf summaries to: ${out}"
: > "${out}"

for case_dir in "${RUN_DIR}"/raw/*/; do
  name=$(basename "${case_dir}")
  perf_data="${case_dir}/perf.data"
  [[ -f "${perf_data}" ]] || continue
  {
    echo "========================================================="
    echo " ${name}"
    echo "========================================================="
    sudo perf report -i "${perf_data}" --stdio --no-children --percent-limit 0.5 -g none 2>/dev/null \
      | awk '/^# Overhead/{f=1} f' \
      | grep -vE "^#|^$" \
      | head -"${TOP_N}"
    echo ""
  } >> "${out}"
done

echo "Done. ${out} contains top-${TOP_N} hottest functions for each of the 48 cases."
