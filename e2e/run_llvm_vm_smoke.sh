#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_os="$(uname -s)"
if [[ "${host_os}" == "Linux" ]]; then
  default_target_platform="@llvm//platforms:linux_x86_64_musl"
  default_exec_platform="//e2e:actiond_linux_x86_64_musl_exec"
  default_server_target="//cmd/linux_actiond:linux-actiond-vm-standalone_pkg"
  default_server_script_path="/tmp/linux-actiond-vm-standalone"
  default_run_mac_host=0
  server_label="linux-actiond"
else
  default_target_platform="@llvm//platforms:linux_arm64_musl"
  default_exec_platform="//e2e:actiond_linux_arm64_musl_exec"
  default_server_target="//cmd/darwin-actiond:darwin-actiond"
  default_server_script_path="/tmp/darwin-actiond-standalone"
  default_run_mac_host=1
  server_label="darwin-actiond"
fi
workspace="${ACTIOND_LLVM_SMOKE_WORKSPACE:-${repo_root}}"
smoke_target="${ACTIOND_LLVM_SMOKE_TARGET:-@llvm-project//llvm:llvm-tblgen}"
warmup_target="${ACTIOND_LLVM_SMOKE_WARMUP_TARGET-//e2e:llvm_exec_warmup}"
target_platform="${ACTIOND_LLVM_SMOKE_TARGET_PLATFORM:-${default_target_platform}}"
# LLVM builds host-configured tools that execute remotely in the VM.
host_platform="${ACTIOND_LLVM_SMOKE_HOST_PLATFORM:-${target_platform}}"
exec_platform="${ACTIOND_LLVM_SMOKE_EXEC_PLATFORM:-${default_exec_platform}}"
host="${ACTIOND_LLVM_VM_SMOKE_HOST:-127.0.0.1}"
port="${ACTIOND_LLVM_VM_SMOKE_PORT:-8998}"
endpoint="${host}:${port}"
memory_mib="${ACTIOND_VM_MEMORY_MIB:-4096}"
cpus="${ACTIOND_VM_CPUS:-8}"
if [[ -v ACTIOND_LLVM_SMOKE_JOBS ]]; then
  jobs="${ACTIOND_LLVM_SMOKE_JOBS}"
else
  jobs="8"
fi
jobs_label="${jobs:-bazel default}"
jobs_flags=()
if [[ -n "${jobs}" ]]; then
  jobs_flags=(--jobs="${jobs}")
fi
output_root="${ACTIOND_LLVM_VM_SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/actiond-llvm-vm-smoke.XXXXXX")}"
llvm_output_base="${ACTIOND_LLVM_SMOKE_OUTPUT_BASE:-${output_root}/llvm-bazel-output-base}"
cas_image="${ACTIOND_VM_CAS_IMAGE:-${output_root}/server/cas.ext4}"
cas_image_size_mib="${ACTIOND_VM_CAS_IMAGE_SIZE_MIB:-8192}"
run_vm="${ACTIOND_LLVM_SMOKE_VM:-1}"
run_mac_host="${ACTIOND_LLVM_SMOKE_MAC_HOST:-${default_run_mac_host}}"
executor_timing_logs="${ACTIOND_LLVM_SMOKE_EXECUTOR_TIMING_LOGS:-1}"
server_target="${ACTIOND_LLVM_SMOKE_SERVER_TARGET:-${default_server_target}}"
server_script_path="${ACTIOND_LLVM_SMOKE_SERVER_SCRIPT_PATH:-${default_server_script_path}}"
qemu_path="${ACTIOND_LLVM_VM_SMOKE_QEMU:-${ACTIOND_VM_QEMU:-}}"
guest_executor_timing_logs="${ACTIOND_VM_EXECUTOR_TIMING_LOGS:-1}"
parse_vm_timings="${ACTIOND_LLVM_SMOKE_PARSE_TIMINGS:-1}"
build_mode_flags=(
  -c opt
  --strip=always
  --stripopt=--strip-all
)
server_build_mode_flags=("${build_mode_flags[@]}")
benchmark_zig_bazel_flags=(
  --@rules_zig//zig/settings:mode=release_fast
  --@rules_zig//zig/settings:zigopt=-mcpu=native
)
prebuilt_server_script_path="${ACTIOND_LLVM_SMOKE_PREBUILT_SERVER_SCRIPT:-}"
bazel_build_flags=()
if [[ -n "${ACTIOND_BAZEL_BUILD_FLAGS:-}" ]]; then
  read -r -a bazel_build_flags <<<"${ACTIOND_BAZEL_BUILD_FLAGS}"
fi
case "${executor_timing_logs}" in
  1|true|TRUE|yes|YES)
    executor_timing_logs=1
    bazel_build_flags+=(--//:executor_timing_logs=true)
    ;;
  0|false|FALSE|no|NO)
    executor_timing_logs=0
    bazel_build_flags+=(--//:executor_timing_logs=false)
    ;;
  *)
    echo "ACTIOND_LLVM_SMOKE_EXECUTOR_TIMING_LOGS must be 0 or 1" >&2
    exit 1
    ;;
esac
if [[ "${executor_timing_logs}" != "1" || "${guest_executor_timing_logs}" != "1" ]]; then
  parse_vm_timings="${ACTIOND_LLVM_SMOKE_PARSE_TIMINGS:-0}"
fi

server_pid=""
server_log=""
server_process_group=0

cleanup_server() {
  local status="${1:-$?}"
  if [[ -n "${server_pid}" ]]; then
    if [[ "${server_process_group}" == "1" ]]; then
      kill -TERM -- "-${server_pid}" >/dev/null 2>&1 || true
      sleep 0.2
      kill -KILL -- "-${server_pid}" >/dev/null 2>&1 || true
    fi
    kill -TERM "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  if [[ "${status}" -ne 0 && -n "${server_log}" && -f "${server_log}" ]]; then
    echo "----- ${server_label} VM log (${server_log}) -----" >&2
    tail -200 "${server_log}" >&2 || true
  fi
  server_pid=""
  server_log=""
  server_process_group=0
}

trap 'cleanup_server $?' EXIT

wait_for_port() {
  local timeout="${1:-90}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -n "${server_pid}" ]] && ! kill -0 "${server_pid}" >/dev/null 2>&1; then
      echo "${server_label} exited before ${endpoint} became ready" >&2
      return 1
    fi
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for ${endpoint}" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_guest_ready() {
  local stats_path="$1"
  local timeout="${2:-120}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -n "${server_pid}" ]] && ! kill -0 "${server_pid}" >/dev/null 2>&1; then
      echo "${server_label} exited before the guest became ready" >&2
      return 1
    fi
    if [[ -s "${stats_path}" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for guest actiond readiness; stats path: ${stats_path}" >&2
      return 1
    fi
    sleep 0.2
  done
}

prepare_server() {
  if [[ -n "${prebuilt_server_script_path}" ]]; then
    if [[ ! -x "${prebuilt_server_script_path}" ]]; then
      echo "prebuilt standalone script is not executable: ${prebuilt_server_script_path}" >&2
      return 1
    fi
    local copied_server="${output_root}/$(basename "${prebuilt_server_script_path}")"
    cp "${prebuilt_server_script_path}" "${copied_server}"
    chmod +x "${copied_server}"
    printf '%s\n' "${copied_server}"
    return 0
  fi

  if [[ "${host_os}" == "Linux" ]]; then
    local copied_server="${output_root}/linux-actiond-vm-standalone"
    (
      cd "${repo_root}"
      bazel build --config=remote \
        "${server_build_mode_flags[@]}" \
        ${bazel_build_flags[@]+"${bazel_build_flags[@]}"} \
        "${benchmark_zig_bazel_flags[@]}" \
        "${server_target}" >&2
    ) >&2
    local built_server
    built_server="$(
      cd "${repo_root}"
      bazel cquery --config=remote -c opt \
        ${bazel_build_flags[@]+"${bazel_build_flags[@]}"} \
        "${benchmark_zig_bazel_flags[@]}" \
        --output=files "${server_target}" | tail -n 1
    )"
    cp "${repo_root}/${built_server}" "${copied_server}"
    chmod +x "${copied_server}"
    printf '%s\n' "${copied_server}"
    return 0
  fi

  mkdir -p "$(dirname "${server_script_path}")"
  (
    cd "${repo_root}"
    bazel run --config=remote \
      --script_path="${server_script_path}" \
      "${server_build_mode_flags[@]}" \
      --bes_backend= \
      ${bazel_build_flags[@]+"${bazel_build_flags[@]}"} \
      "${benchmark_zig_bazel_flags[@]}" \
      "${server_target}"
  ) >&2
  printf '%s\n' "${server_script_path}"
}

run_smoke() {
  local build_log="${output_root}/llvm_tblgen_smoke.log"
  local measured_server_log="${output_root}/${server_label}-vm.measured.log"
  local remote_grpc_log="${ACTIOND_LLVM_SMOKE_REMOTE_GRPC_LOG:-}"
  local timings="${output_root}/timings.md"
  local server
  local elapsed

  mkdir -p "${output_root}"
  server="$(prepare_server)"
  server_log="${output_root}/${server_label}-vm.log"

  local server_cmd=(
    "${server}" serve-vm
    --listen="${endpoint}"
    --root="${output_root}/server"
    --cas-image="${cas_image}"
    --cas-image-size-mib="${cas_image_size_mib}"
    --memory-mib="${memory_mib}"
    --cpus="${cpus}"
  )
  if [[ "${executor_timing_logs}" == "1" ]]; then
    server_cmd+=(
      --actiondfs-stats-path="${output_root}/actiondfs_stats.txt"
    )
  fi
  if [[ "${host_os}" == "Linux" && -n "${qemu_path}" ]]; then
    server_cmd+=(--qemu="${qemu_path}")
  fi
  if [[ "${host_os}" == "Linux" ]]; then
    server_cmd+=(--qemu-machine="${ACTIOND_VM_QEMU_MACHINE:-q35}")
    server_cmd+=(--guest-executor-timing-logs="${guest_executor_timing_logs}")
  fi
  if [[ "${host_os}" == "Linux" && "${ACTIOND_VM_ALLOW_TCG:-0}" == "1" ]]; then
    server_cmd+=(--allow-tcg)
  fi
  if [[ "${host_os}" == "Linux" ]]; then
    server_cmd+=(--qemu-cache="${ACTIOND_VM_QEMU_CACHE:-none}")
    if [[ -n "${ACTIOND_VM_QEMU_AIO:-}" ]]; then
      server_cmd+=(--qemu-aio="${ACTIOND_VM_QEMU_AIO}")
    fi
    if [[ -n "${ACTIOND_VM_QEMU_BLOCK_QUEUES:-}" ]]; then
      server_cmd+=(--qemu-block-queues="${ACTIOND_VM_QEMU_BLOCK_QUEUES}")
    fi
  fi
  if [[ "${host_os}" == "Linux" ]] && command -v setsid >/dev/null 2>&1; then
    setsid "${server_cmd[@]}" >"${server_log}" 2>&1 &
    server_process_group=1
  else
    "${server_cmd[@]}" >"${server_log}" 2>&1 &
    server_process_group=0
  fi
  server_pid="$!"

  wait_for_port 90
  if [[ "${executor_timing_logs}" == "1" ]]; then
    wait_for_guest_ready "${output_root}/actiondfs_stats.txt" 120
  fi

  if ! ACTIOND_LLVM_SMOKE_EXECUTOR="grpc://${endpoint}" \
    ACTIOND_LLVM_SMOKE_CACHE="grpc://${endpoint}" \
    ACTIOND_LLVM_SMOKE_JOBS="${jobs}" \
    ACTIOND_VM_QEMU_CACHE="${ACTIOND_VM_QEMU_CACHE:-none}" \
    ACTIOND_VM_QEMU_AIO="${ACTIOND_VM_QEMU_AIO:-}" \
    ACTIOND_VM_QEMU_BLOCK_QUEUES="${ACTIOND_VM_QEMU_BLOCK_QUEUES:-}" \
    ACTIOND_LLVM_SMOKE_WORKSPACE="${workspace}" \
    ACTIOND_LLVM_SMOKE_TARGET="${smoke_target}" \
    ACTIOND_LLVM_SMOKE_WARMUP_TARGET="${warmup_target}" \
    ACTIOND_LLVM_SMOKE_TARGET_PLATFORM="${target_platform}" \
    ACTIOND_LLVM_SMOKE_HOST_PLATFORM="${host_platform}" \
    ACTIOND_LLVM_SMOKE_EXEC_PLATFORM="${exec_platform}" \
    ACTIOND_LLVM_SMOKE_SERVER_LOG="${server_log}" \
    ACTIOND_LLVM_SMOKE_MEASURED_SERVER_LOG="${measured_server_log}" \
    ACTIOND_LLVM_SMOKE_REMOTE_GRPC_LOG="${remote_grpc_log}" \
    ACTIOND_LLVM_SMOKE_OUTPUT_BASE="${llvm_output_base}" \
    ACTIOND_LLVM_SMOKE_SKIP_CLEAN=0 \
    "${repo_root}/e2e/llvm_tblgen_smoke.sh" >"${build_log}" 2>&1; then
    echo "LLVM smoke failed; build log: ${build_log}" >&2
    if [[ -n "${remote_grpc_log}" ]]; then
      echo "remote gRPC log: ${remote_grpc_log}" >&2
    fi
    tail -200 "${build_log}" >&2 || true
    return 1
  fi

  # Let the host's once-per-second stats poller capture the tail of the build
  # before the VM is torn down and the timing artifact is parsed.
  sleep 1.2

  elapsed="$(sed -n 's/.*Elapsed time: \([0-9.]*s\).*/\1/p' "${build_log}" | tail -n 1)"
  if [[ "${parse_vm_timings}" == "1" && ! -s "${measured_server_log}" ]]; then
    echo "measured VM log slice is empty; source log: ${server_log}" >&2
    return 1
  fi

  if [[ "${parse_vm_timings}" == "1" ]]; then
    "${repo_root}/test/parse_timings.py" "${measured_server_log}" \
      --mode "llvm-vm" \
      --command "ACTIOND_VM_CAS_IMAGE_SIZE_MIB=${cas_image_size_mib} ACTIOND_VM_MEMORY_MIB=${memory_mib} ACTIOND_VM_CPUS=${cpus} ACTIOND_LLVM_SMOKE_JOBS=${jobs} ACTIOND_VM_QEMU_MACHINE=${ACTIOND_VM_QEMU_MACHINE:-q35} ACTIOND_VM_QEMU_CACHE=${ACTIOND_VM_QEMU_CACHE:-none} ACTIOND_VM_QEMU_AIO=${ACTIOND_VM_QEMU_AIO:-io_uring} ACTIOND_VM_QEMU_BLOCK_QUEUES=${ACTIOND_VM_QEMU_BLOCK_QUEUES:-} ACTIOND_LLVM_SMOKE_EXECUTOR_TIMING_LOGS=${executor_timing_logs} ACTIOND_VM_EXECUTOR_TIMING_LOGS=${guest_executor_timing_logs} e2e/run_llvm_vm_smoke.sh" \
      --bazel-elapsed "${elapsed:-unknown}" \
      --workload "${smoke_target}, warmup=${warmup_target:-none}, jobs=${jobs_label}" \
      --output "${timings}"
  else
    cat >"${timings}" <<EOF
# LLVM VM Smoke Timing

Mode: llvm-vm
Workload: ${smoke_target}, warmup=${warmup_target:-none}, jobs=${jobs_label}
Command: ACTIOND_VM_CAS_IMAGE_SIZE_MIB=${cas_image_size_mib} ACTIOND_VM_MEMORY_MIB=${memory_mib} ACTIOND_VM_CPUS=${cpus} ACTIOND_LLVM_SMOKE_JOBS=${jobs} ACTIOND_VM_QEMU_MACHINE=${ACTIOND_VM_QEMU_MACHINE:-q35} ACTIOND_VM_QEMU_CACHE=${ACTIOND_VM_QEMU_CACHE:-none} ACTIOND_VM_QEMU_AIO=${ACTIOND_VM_QEMU_AIO:-io_uring} ACTIOND_VM_QEMU_BLOCK_QUEUES=${ACTIOND_VM_QEMU_BLOCK_QUEUES:-} ACTIOND_VM_EXECUTOR_TIMING_LOGS=${guest_executor_timing_logs} ACTIOND_LLVM_SMOKE_PARSE_TIMINGS=0 e2e/run_llvm_vm_smoke.sh
Bazel elapsed: ${elapsed:-unknown}
Executor timing logs: ${guest_executor_timing_logs}
Server log: ${server_log}
Measured server log: ${measured_server_log}
Actiondfs stats: ${output_root}/actiondfs_stats.txt
EOF
  fi

  cleanup_server 0
  if [[ "${executor_timing_logs}" == "1" ]]; then
    echo "timing summary: ${timings}" >&2
  else
    echo "timing summary: skipped; executor timing logs are compiled out" >&2
  fi
  if [[ "${executor_timing_logs}" == "1" ]]; then
    echo "actiondfs stats: ${output_root}/actiondfs_stats.txt" >&2
  fi
}

run_mac_host_smoke() {
  local warmup_log="${output_root}/llvm_tblgen_mac_host_warmup.log"
  local build_log="${output_root}/llvm_tblgen_mac_host.log"
  local timings="${output_root}/mac_host_timings.md"
  local elapsed
  local startup_flags=()
  if [[ -n "${llvm_output_base}" ]]; then
    mkdir -p "${llvm_output_base}"
    startup_flags=(--output_base="${llvm_output_base}")
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "mac-host LLVM smoke must run on macOS" >&2
    return 1
  fi

  (
    cd "${workspace}"
    bazel "${startup_flags[@]}" clean --expunge
  ) >"${build_log}.clean" 2>&1

  if [[ -n "${warmup_target}" ]]; then
    if ! (
      cd "${workspace}"
      bazel "${startup_flags[@]}" build "${warmup_target}" \
        "${build_mode_flags[@]}" \
        --bes_backend= \
        --platforms="${target_platform}" \
        --remote_executor= \
        --remote_cache= \
        --experimental_remote_downloader= \
        --experimental_remote_downloader_local_fallback=true \
        --noremote_cache_compression \
        --noremote_accept_cached \
        --remote_upload_local_results=false \
        --disk_cache= \
        "${jobs_flags[@]}"
    ) >"${warmup_log}" 2>&1; then
      echo "LLVM mac-host warmup failed; build log: ${warmup_log}" >&2
      tail -200 "${warmup_log}" >&2 || true
      return 1
    fi
  fi

  if ! (
    cd "${workspace}"
    bazel "${startup_flags[@]}" build "${smoke_target}" \
      "${build_mode_flags[@]}" \
      --bes_backend= \
      --platforms="${target_platform}" \
      --remote_executor= \
      --remote_cache= \
      --experimental_remote_downloader= \
      --experimental_remote_downloader_local_fallback=true \
      --noremote_cache_compression \
      --noremote_accept_cached \
      --remote_upload_local_results=false \
      --disk_cache= \
      "${jobs_flags[@]}"
  ) >"${build_log}" 2>&1; then
    echo "LLVM mac-host smoke failed; build log: ${build_log}" >&2
    tail -200 "${build_log}" >&2 || true
    return 1
  fi

  elapsed="$(sed -n 's/.*Elapsed time: \([0-9.]*s\).*/\1/p' "${build_log}" | tail -n 1)"
  cat >"${timings}" <<EOF
# LLVM Mac-Host Smoke Timing

- Generated: \`$(date '+%Y-%m-%d %H:%M:%S %Z')\`
- Command: \`e2e/run_llvm_vm_smoke.sh\`
- Warmup log: \`${warmup_log}\`
- Source log: \`${build_log}\`
- Workload: \`${smoke_target}\`, warmup=${warmup_target:-none}, jobs=${jobs_label}
- Target platform: \`${target_platform}\`
- Host platform: default macOS host platform
- Platform note: target actions compile for Linux musl; local exec/host tools remain macOS binaries so Bazel can run them locally.
- Build mode: \`-c opt --strip=always --stripopt=--strip-all\`
- Bazel elapsed: \`${elapsed:-unknown}\`
EOF

  echo "mac-host timing summary: ${timings}" >&2
}

if [[ "${host_os}" != "Darwin" && "${host_os}" != "Linux" ]]; then
  echo "LLVM VM smoke must run on macOS or Linux" >&2
  exit 1
fi

mkdir -p "${output_root}"
echo "smoke output: ${output_root}" >&2
if [[ "${run_vm}" == "1" ]]; then
  run_smoke
fi
if [[ "${run_mac_host}" == "1" ]]; then
  run_mac_host_smoke
fi

printf '%s\n' "${output_root}" >/tmp/actiond-last-llvm-vm-smoke-path
