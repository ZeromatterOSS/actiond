#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "LLVM Linux smoke must run on Linux" >&2
  exit 1
fi

mode="${ACTIOND_LLVM_LINUX_MODE:-fuse}"
workspace="${ACTIOND_LLVM_SMOKE_WORKSPACE:-${repo_root}}"
smoke_target="${ACTIOND_LLVM_SMOKE_TARGET:-@llvm-project//llvm:llvm-tblgen}"
warmup_target="${ACTIOND_LLVM_SMOKE_WARMUP_TARGET-//e2e:llvm_exec_warmup}"
target_platform="${ACTIOND_LLVM_SMOKE_TARGET_PLATFORM:-@llvm//platforms:linux_x86_64_musl}"
host_platform="${ACTIOND_LLVM_SMOKE_HOST_PLATFORM:-${target_platform}}"
exec_platform="${ACTIOND_LLVM_SMOKE_EXEC_PLATFORM:-//e2e:actiond_linux_x86_64_musl_exec}"
host="${ACTIOND_LLVM_LINUX_SMOKE_HOST:-127.0.0.1}"
port="${ACTIOND_LLVM_LINUX_SMOKE_PORT:-8997}"
endpoint="${host}:${port}"
jobs="${ACTIOND_LLVM_SMOKE_JOBS-16}"
jobs_label="${jobs:-bazel default}"
output_root="${ACTIOND_LLVM_LINUX_SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/actiond-llvm-linux-smoke.XXXXXX")}"
server_script_path="${ACTIOND_LLVM_SMOKE_SERVER_SCRIPT_PATH:-${TMPDIR:-/tmp}/actiond-llvm-linux-smoke-server-${BASHPID}/linux-actiond-standalone}"
prebuilt_server_script_path="${ACTIOND_LLVM_SMOKE_PREBUILT_SERVER_SCRIPT:-}"
prebuilt_fuse_helper="${ACTIOND_LLVM_SMOKE_FUSE_HELPER:-}"
server_sudo="${ACTIOND_LLVM_LINUX_SMOKE_SERVER_SUDO:-1}"
server_label="linux-actiond-${mode}"
build_mode_flags=(
  -c opt
  --strip=always
  --stripopt=--strip-all
)
benchmark_zig_bazel_flags=(
  --@rules_zig//zig/settings:mode=release_fast
  --@rules_zig//zig/settings:zigopt=-mcpu=native
)
bazel_build_flags=()
if [[ -n "${ACTIOND_BAZEL_BUILD_FLAGS:-}" ]]; then
  read -r -a bazel_build_flags <<<"${ACTIOND_BAZEL_BUILD_FLAGS}"
fi

server_pid=""
server_log=""
server_process_group=0

cleanup_server() {
  local status="${1:-$?}"
  if [[ "${mode}" == "fuse" && -n "${output_root:-}" ]]; then
    sudo -n umount -l "${output_root}/server/cas/actiondfs-stage/.persistent/mount" >/dev/null 2>&1 || true
    sleep 0.2
  fi
  if [[ -n "${server_pid}" ]]; then
    if [[ "${server_process_group}" == "1" ]]; then
      kill -TERM -- "-${server_pid}" >/dev/null 2>&1 || true
      sleep 0.2
      kill -KILL -- "-${server_pid}" >/dev/null 2>&1 || true
    else
      kill -TERM "${server_pid}" >/dev/null 2>&1 || true
    fi
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  sudo -n umount -l "${output_root}/server/runtimes" >/dev/null 2>&1 || true
  if [[ "${mode}" == "fuse" ]] && command -v actiond-kill-bench-helpers >/dev/null 2>&1; then
    sudo -n actiond-kill-bench-helpers >/dev/null 2>&1 || true
  fi
  if [[ "${status}" -ne 0 && -n "${server_log}" && -f "${server_log}" ]]; then
    echo "----- ${server_label} log (${server_log}) -----" >&2
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

prepare_server() {
  local copied_server="${server_script_path}"
  mkdir -p "$(dirname "${copied_server}")"

  if [[ -n "${prebuilt_server_script_path}" ]]; then
    if [[ ! -x "${prebuilt_server_script_path}" ]]; then
      echo "prebuilt standalone script is not executable: ${prebuilt_server_script_path}" >&2
      return 1
    fi
    cp "${prebuilt_server_script_path}" "${copied_server}"
    chmod +x "${copied_server}"
    printf '%s\n' "${copied_server}"
    return 0
  fi

  (
    cd "${repo_root}"
    bazel build --config=remote \
      "${build_mode_flags[@]}" \
      ${bazel_build_flags[@]+"${bazel_build_flags[@]}"} \
      "${benchmark_zig_bazel_flags[@]}" \
      //cmd/linux_actiond:linux-actiond-standalone_pkg >&2
  ) >&2
  local built_server
  built_server="$(
    cd "${repo_root}"
    bazel cquery --config=remote -c opt \
      ${bazel_build_flags[@]+"${bazel_build_flags[@]}"} \
      "${benchmark_zig_bazel_flags[@]}" \
      --output=files //cmd/linux_actiond:linux-actiond-standalone_pkg | tail -n 1
  )"
  cp "${repo_root}/${built_server}" "${copied_server}"
  chmod +x "${copied_server}"
  printf '%s\n' "${copied_server}"
}

prepare_fuse_helper() {
  local copied_helper="${output_root}/actiondfs_fuse"

  if [[ -n "${prebuilt_fuse_helper}" ]]; then
    if [[ ! -x "${prebuilt_fuse_helper}" ]]; then
      echo "prebuilt FUSE helper is not executable: ${prebuilt_fuse_helper}" >&2
      return 1
    fi
    cp "${prebuilt_fuse_helper}" "${copied_helper}"
    chmod +x "${copied_helper}"
    finalize_fuse_helper "${copied_helper}"
    printf '%s\n' "${copied_helper}"
    return 0
  fi

  (
    cd "${repo_root}"
    bazel build --config=remote \
      "${build_mode_flags[@]}" \
      ${bazel_build_flags[@]+"${bazel_build_flags[@]}"} \
      "${benchmark_zig_bazel_flags[@]}" \
      //tools:actiondfs_fuse >&2
  )
  local built_helper
  built_helper="$(
    cd "${repo_root}"
    bazel cquery --config=remote -c opt \
      ${bazel_build_flags[@]+"${bazel_build_flags[@]}"} \
      "${benchmark_zig_bazel_flags[@]}" \
      --output=files //tools:actiondfs_fuse | tail -n 1
  )"
  cp "${repo_root}/${built_helper}" "${copied_helper}"
  chmod +x "${copied_helper}"
  finalize_fuse_helper "${copied_helper}"
  printf '%s\n' "${copied_helper}"
}

finalize_fuse_helper() {
  local copied_helper="$1"
  local threads="${ACTIOND_ACTIONDFS_FUSE_THREADS:-}"
  local zero_open="${ACTIOND_ACTIONDFS_FUSE_ZERO_OPEN:-}"
  local negative_lookup="${ACTIOND_ACTIONDFS_FUSE_NEGATIVE_LOOKUP:-}"
  local enable_stats="${ACTIOND_ACTIONDFS_FUSE_STATS:-}"
  local disable_stats="${ACTIOND_ACTIONDFS_FUSE_DISABLE_STATS:-}"
  local splice_min="${ACTIOND_ACTIONDFS_FUSE_SPLICE_MIN_BYTES:-}"
  if [[ -z "${threads}" && -z "${zero_open}" && -z "${negative_lookup}" && -z "${enable_stats}" && -z "${disable_stats}" && -z "${splice_min}" ]]; then
    return 0
  fi
  if [[ -n "${threads}" && ! "${threads}" =~ ^[0-9]+$ ]]; then
    echo "ACTIOND_ACTIONDFS_FUSE_THREADS must be a positive integer" >&2
    return 1
  fi
  if [[ -n "${splice_min}" && ! "${splice_min}" =~ ^[0-9]+$ ]]; then
    echo "ACTIOND_ACTIONDFS_FUSE_SPLICE_MIN_BYTES must be a non-negative integer" >&2
    return 1
  fi
  local copied_binary="${copied_helper}.bin"
  mv "${copied_helper}" "${copied_binary}"
  {
    printf '#!/usr/bin/env bash\n'
    if [[ -n "${threads}" ]]; then
      printf 'export ACTIOND_ACTIONDFS_FUSE_THREADS=%s\n' "${threads}"
    fi
    if [[ -n "${zero_open}" ]]; then
      printf 'export ACTIOND_ACTIONDFS_FUSE_ZERO_OPEN=%q\n' "${zero_open}"
    fi
    if [[ -n "${negative_lookup}" ]]; then
      printf 'export ACTIOND_ACTIONDFS_FUSE_NEGATIVE_LOOKUP=%q\n' "${negative_lookup}"
    fi
    if [[ -n "${enable_stats}" ]]; then
      printf 'export ACTIOND_ACTIONDFS_FUSE_STATS=%q\n' "${enable_stats}"
    fi
    if [[ -n "${disable_stats}" ]]; then
      printf 'export ACTIOND_ACTIONDFS_FUSE_DISABLE_STATS=%q\n' "${disable_stats}"
    fi
    if [[ -n "${splice_min}" ]]; then
      printf 'export ACTIOND_ACTIONDFS_FUSE_SPLICE_MIN_BYTES=%s\n' "${splice_min}"
    fi
    printf 'exec "%s" "$@"\n' "${copied_binary}"
  } >"${copied_helper}"
  chmod +x "${copied_helper}"
}

run_smoke() {
  case "${mode}" in
    materialized|fuse) ;;
    *)
      echo "unknown ACTIOND_LLVM_LINUX_MODE: ${mode}" >&2
      return 1
      ;;
  esac

  local build_log="${output_root}/llvm_tblgen_smoke.log"
  local measured_server_log="${output_root}/${server_label}.measured.log"
  local remote_grpc_log="${ACTIOND_LLVM_SMOKE_REMOTE_GRPC_LOG:-}"
  local timings="${output_root}/timings.md"
  local server helper elapsed

  mkdir -p "${output_root}"
  server="$(prepare_server)"
  server_log="${output_root}/${server_label}.log"

  local -a server_cmd=(
    "${server}" serve
    --listen="${endpoint}"
    --root="${output_root}/server"
  )
  if [[ "${mode}" == "fuse" ]]; then
    helper="$(prepare_fuse_helper)"
    server_cmd+=(--actiondfs-fuse-helper="${helper}")
  fi

  if [[ "${server_sudo}" == "1" ]]; then
    if command -v setsid >/dev/null 2>&1; then
      setsid sudo -n "${server_cmd[@]}" >"${server_log}" 2>&1 &
      server_process_group=1
    else
      sudo -n "${server_cmd[@]}" >"${server_log}" 2>&1 &
      server_process_group=0
    fi
  else
    if command -v setsid >/dev/null 2>&1; then
      setsid "${server_cmd[@]}" >"${server_log}" 2>&1 &
      server_process_group=1
    else
      "${server_cmd[@]}" >"${server_log}" 2>&1 &
      server_process_group=0
    fi
  fi
  server_pid="$!"

  wait_for_port 90

  if ! ACTIOND_LLVM_SMOKE_EXECUTOR="grpc://${endpoint}" \
    ACTIOND_LLVM_SMOKE_CACHE="grpc://${endpoint}" \
    ACTIOND_LLVM_SMOKE_JOBS="${jobs}" \
    ACTIOND_LLVM_SMOKE_WORKSPACE="${workspace}" \
    ACTIOND_LLVM_SMOKE_TARGET="${smoke_target}" \
    ACTIOND_LLVM_SMOKE_WARMUP_TARGET="${warmup_target}" \
    ACTIOND_LLVM_SMOKE_TARGET_PLATFORM="${target_platform}" \
    ACTIOND_LLVM_SMOKE_HOST_PLATFORM="${host_platform}" \
    ACTIOND_LLVM_SMOKE_EXEC_PLATFORM="${exec_platform}" \
    ACTIOND_LLVM_SMOKE_SERVER_LOG="${server_log}" \
    ACTIOND_LLVM_SMOKE_MEASURED_SERVER_LOG="${measured_server_log}" \
    ACTIOND_LLVM_SMOKE_REMOTE_GRPC_LOG="${remote_grpc_log}" \
    ACTIOND_LLVM_SMOKE_SKIP_CLEAN="${ACTIOND_LLVM_SMOKE_SKIP_CLEAN:-0}" \
    "${repo_root}/e2e/llvm_tblgen_smoke.sh" >"${build_log}" 2>&1; then
    echo "LLVM Linux smoke failed; build log: ${build_log}" >&2
    tail -200 "${build_log}" >&2 || true
    return 1
  fi

  elapsed="$(sed -n 's/.*Elapsed time: \([0-9.]*s\).*/\1/p' "${build_log}" | tail -n 1)"
  if [[ ! -s "${measured_server_log}" ]]; then
    echo "measured Linux actiond log slice is empty; source log: ${server_log}" >&2
    return 1
  fi

  local summary_command="ACTIOND_LLVM_LINUX_MODE=${mode} ACTIOND_LLVM_SMOKE_JOBS=${jobs}"
  if [[ -n "${ACTIOND_ACTIONDFS_FUSE_THREADS:-}" ]]; then
    summary_command+=" ACTIOND_ACTIONDFS_FUSE_THREADS=${ACTIOND_ACTIONDFS_FUSE_THREADS}"
  fi
  if [[ -n "${ACTIOND_ACTIONDFS_FUSE_ZERO_OPEN:-}" ]]; then
    summary_command+=" ACTIOND_ACTIONDFS_FUSE_ZERO_OPEN=${ACTIOND_ACTIONDFS_FUSE_ZERO_OPEN}"
  fi
  if [[ -n "${ACTIOND_ACTIONDFS_FUSE_NEGATIVE_LOOKUP:-}" ]]; then
    summary_command+=" ACTIOND_ACTIONDFS_FUSE_NEGATIVE_LOOKUP=${ACTIOND_ACTIONDFS_FUSE_NEGATIVE_LOOKUP}"
  fi
  if [[ -n "${ACTIOND_ACTIONDFS_FUSE_STATS:-}" ]]; then
    summary_command+=" ACTIOND_ACTIONDFS_FUSE_STATS=${ACTIOND_ACTIONDFS_FUSE_STATS}"
  fi
  if [[ -n "${ACTIOND_ACTIONDFS_FUSE_DISABLE_STATS:-}" ]]; then
    summary_command+=" ACTIOND_ACTIONDFS_FUSE_DISABLE_STATS=${ACTIOND_ACTIONDFS_FUSE_DISABLE_STATS}"
  fi
  if [[ -n "${ACTIOND_ACTIONDFS_FUSE_SPLICE_MIN_BYTES:-}" ]]; then
    summary_command+=" ACTIOND_ACTIONDFS_FUSE_SPLICE_MIN_BYTES=${ACTIOND_ACTIONDFS_FUSE_SPLICE_MIN_BYTES}"
  fi
  if [[ -n "${ACTIOND_LLVM_SMOKE_BAZEL_STARTUP_FLAGS:-}" ]]; then
    summary_command+=" ACTIOND_LLVM_SMOKE_BAZEL_STARTUP_FLAGS=${ACTIOND_LLVM_SMOKE_BAZEL_STARTUP_FLAGS}"
  fi
  if [[ "${ACTIOND_LLVM_SMOKE_SKIP_CLEAN:-0}" == "1" ]]; then
    summary_command+=" ACTIOND_LLVM_SMOKE_SKIP_CLEAN=1"
  fi
  summary_command+=" e2e/run_llvm_linux_smoke.sh"

  "${repo_root}/test/parse_timings.py" "${measured_server_log}" \
    --mode "llvm-linux-${mode}" \
    --command "${summary_command}" \
    --bazel-elapsed "${elapsed:-unknown}" \
    --workload "${smoke_target}, warmup=${warmup_target:-none}, jobs=${jobs_label}" \
    --output "${timings}"

  cleanup_server 0
  echo "timing summary: ${timings}" >&2
}

mkdir -p "${output_root}"
echo "smoke output: ${output_root}" >&2
run_smoke
printf '%s\n' "${output_root}" >/tmp/actiond-last-llvm-linux-smoke-path
