#!/usr/bin/env bash
# Run all normal integration/performance benchmarks for a sweep of ROB/IQ sizes.
# Intended to live in <repo>/sim and be run from there.
set -u -o pipefail

# Edit these two lists for the configurations you want to sweep.
ROB_SIZES=(8 16 32 64)
IQ_SIZES=(8 16 32)

# Program name : plusarg understood by core_tb.sv.
# SLOW/LOOP/FIB are deliberately excluded.
PROGRAMS=(
  "sum:+PERF"
  "ilp:+ILP"
  "mem_mul_div:+MEM_MULDIV"
  "general:+GEN"
  "balanced:+BAL"
  "matrix_multiply:+MATMUL"
)

OUT_ROOT="sim_logs"
TB_FILE="core_tb"
RTL_FLIST="../inputs/orion_rv_src_list.txt"
TB_SRC="../src/tb/${TB_FILE}.sv"

# For your existing naming convention, change the line inside run_config() to:
# cfg_dir="${OUT_ROOT}/ROB_${rob}_IQ_${iq}_PHY_128"

run_program() {
  local cfg_dir="$1"
  local name="$2"
  local plusarg="$3"
  local log="${cfg_dir}/${name}.txt"
  local rc

  echo "[run] ${name} (${plusarg})"

  # -l writes the ModelSim/Questa transcript directly to the desired file.
  vsim -c \
    -l "${log}" \
    "${plusarg}" \
    -do "run -all; quit -f" \
    "work.${TB_FILE}"
  rc=$?

  # vsim can still return 0 when the TB reports failed checks, because the TB
  # calls $finish. Inspect the transcript as well as the simulator exit code.
  if (( rc != 0 )); then
    echo "[FAIL] ${name}: vsim exit code ${rc}; see ${log}"
    return 1
  fi

  if grep -q "INTEGRATION CHECKS FAILED" "${log}"; then
    echo "[FAIL] ${name}: integration checks failed; see ${log}"
    return 1
  fi

  if grep -q "WATCHDOG TIMEOUT" "${log}"; then
    echo "[FAIL] ${name}: watchdog timeout; see ${log}"
    return 1
  fi

  if ! grep -q "INTEGRATION TEST SUMMARY" "${log}"; then
    echo "[FAIL] ${name}: no integration summary found; see ${log}"
    return 1
  fi

  echo "[PASS] ${name}"
  return 0
}

run_config() {
  local rob="$1"
  local iq="$2"
  local cfg_dir="${OUT_ROOT}/ROB_${rob}_IQ_${iq}"
  local entry name plusarg
  local config_failed=0

  mkdir -p "${cfg_dir}"

  echo
  echo "============================================================"
  echo "ROB=${rob}, IQ=${iq}"
  echo "Output: ${cfg_dir}"
  echo "============================================================"

  # ROB/IQ are package compile-time parameters, so rebuild work for each
  # configuration. Compile once, then run all six benchmarks.
  rm -rf work
  vlib work || return 1

  echo "[compile] ROB=${rob}, IQ=${iq}"
  if ! vlog -sv \
      "+define+ORION_ROB_SIZE=${rob}" \
      "+define+ORION_IQ_SIZE=${iq}" \
      -f "${RTL_FLIST}" \
      > "${cfg_dir}/compile.log" 2>&1; then
    echo "[FAIL] RTL compilation failed; see ${cfg_dir}/compile.log"
    return 1
  fi

  if ! vlog -sv \
      "+define+ORION_ROB_SIZE=${rob}" \
      "+define+ORION_IQ_SIZE=${iq}" \
      "${TB_SRC}" \
      >> "${cfg_dir}/compile.log" 2>&1; then
    echo "[FAIL] testbench compilation failed; see ${cfg_dir}/compile.log"
    return 1
  fi

  for entry in "${PROGRAMS[@]}"; do
    name="${entry%%:*}"
    plusarg="${entry#*:}"
    run_program "${cfg_dir}" "${name}" "${plusarg}" || config_failed=1
  done

  return "${config_failed}"
}

config_failures=0
for rob in "${ROB_SIZES[@]}"; do
  for iq in "${IQ_SIZES[@]}"; do
    if ! run_config "${rob}" "${iq}"; then
      ((config_failures++))
    fi
  done
done

echo
echo "Sweep complete. Configurations with at least one failure: ${config_failures}"
echo "Results: ${OUT_ROOT}/"
exit "${config_failures}"
