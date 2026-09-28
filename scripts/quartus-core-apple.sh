#!/usr/bin/env bash
# Compile any Quartus 17 project (such as a MiSTer core) in the Apple runtime
# container installed by scripts/quartus-apple.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="${QUARTUS_CACHE_DIR:-$ROOT/build/quartus}/intelFPGA_lite"
IMAGE=docker.io/library/quartus17-runtime:apple-amd64
# The fitter slows sharply under Rosetta above about 8 threads. The thread
# count also changes placement, so use the same value wherever bits must match.
FIT_THREADS="${QUARTUS_FIT_THREADS:-8}"
CPUS="${QUARTUS_CPUS:-$(sysctl -n hw.ncpu)}"
MEMORY="${QUARTUS_MEMORY:-16g}"

usage() {
  echo "usage: scripts/quartus-core-apple.sh <project-dir> [project] [revision]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 3 ]] || usage
PROJECT_DIR="$(cd "$1" && pwd)"
if [[ $# -ge 2 ]]; then
  PROJECT="$2"
else
  qpfs=("$PROJECT_DIR"/*.qpf)
  [[ ${#qpfs[@]} == 1 && -f "${qpfs[0]}" ]] || {
    echo "expected exactly one .qpf in $PROJECT_DIR; pass the project name" >&2
    exit 2
  }
  PROJECT="$(basename "${qpfs[0]}" .qpf)"
fi
REVISION="${3:-$PROJECT}"

command -v container >/dev/null 2>&1 || {
  echo "Apple container is required: https://github.com/apple/container" >&2
  exit 1
}
[[ -x "$INSTALL_ROOT/17.0/quartus/bin/quartus_sh" ]] || {
  echo "Quartus is not installed; run scripts/quartus-apple.sh first" >&2
  exit 1
}

# Mirror `quartus_sh --flow compile` one stage at a time; see the README for
# why synthesis runs with --parallel=1. The stepwise flow skips flow hooks, so
# run the PRE_FLOW_SCRIPT_FILE (MiSTer's build_id.tcl) explicitly.
container run --arch amd64 --rm --cpus "$CPUS" --memory "$MEMORY" \
  --mount "type=bind,source=$INSTALL_ROOT,target=/opt/intelFPGA_lite,readonly" \
  --mount "type=bind,source=$PROJECT_DIR,target=/work" \
  --workdir /work "$IMAGE" \
  sh -euc '
    project="$1" revision="$2" fit_threads="$3"
    hook=$(sed -n "s/^set_global_assignment -name PRE_FLOW_SCRIPT_FILE \"quartus_sh:\(.*\)\"$/\1/p" \
      "$revision.qsf")
    if [ -n "$hook" ]; then
      quartus_sh -t "$hook" compile "$project" "$revision"
    fi
    quartus_map --parallel=1 "$project" -c "$revision"
    quartus_fit --parallel="$fit_threads" "$project" -c "$revision"
    quartus_asm "$project" -c "$revision"
    quartus_sta "$project" -c "$revision"
  ' sh "$PROJECT" "$REVISION" "$FIT_THREADS"
