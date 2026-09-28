#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
INSTALL_ROOT="${QUARTUS_CACHE_DIR:-$ROOT/build/quartus}/intelFPGA_lite"
QSF="$ROOT/fpga/example.qsf"

usage() {
  echo "usage: scripts/quartus-build.sh apple|docker" >&2
  exit 2
}

[[ "$MODE" == apple || "$MODE" == docker ]] || usage
[[ -x "$INSTALL_ROOT/17.0/quartus/bin/quartus_sh" ]] || {
  echo "Quartus is not installed; run the matching quartus setup script first" >&2
  exit 1
}

# A CI-comparable build must identify one committed source tree, not an
# unrecorded mixture of working-copy files.
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
  echo "Quartus parity builds require a clean committed checkout" >&2
  exit 1
fi

require_qsf() {
  local assignment="$1"
  [[ "$(grep -Fxc "$assignment" "$QSF")" == 1 ]] || {
    echo "missing canonical Quartus assignment: $assignment" >&2
    exit 1
  }
}

require_qsf 'set_global_assignment -name SEED 2'
require_qsf 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 4'
require_qsf 'set_global_assignment -name PARALLEL_SYNTHESIS OFF'
require_qsf 'set_global_assignment -name AUTO_PARALLEL_SYNTHESIS OFF'

# The stepwise flow below does not run flow hooks such as MiSTer's build_id.tcl;
# run those explicitly before building rather than silently skipping them.
if grep -Eq '^set_global_assignment -name (PRE|POST)_FLOW_SCRIPT_FILE' "$QSF"; then
  echo "flow script assignments are not run by the stepwise flow" >&2
  exit 1
fi

if [[ "$MODE" == apple ]]; then
  command -v container >/dev/null 2>&1 || {
    echo "Apple container is required" >&2
    exit 1
  }
  IMAGE=docker.io/library/quartus17-runtime:apple-amd64
  RUN=(
    container run --arch amd64 --rm --cpus 4 --memory 12g
    --mount "type=bind,source=$INSTALL_ROOT,target=/opt/intelFPGA_lite,readonly"
    --mount "type=bind,source=$ROOT/fpga,target=/work"
    --workdir /work "$IMAGE"
  )
else
  command -v docker >/dev/null 2>&1 || {
    echo "Docker is required" >&2
    exit 1
  }
  IMAGE=quartus17-runtime:docker-amd64
  RUN=(
    docker run --platform linux/amd64 --rm --cpus 4 --memory 12g
    --volume "$INSTALL_ROOT:/opt/intelFPGA_lite:ro"
    --volume "$ROOT/fpga:/work"
    --workdir /work "$IMAGE"
  )
fi

version="$("${RUN[@]}" quartus_sh --version)"
version_line="$(printf '%s\n' "$version" | grep -m1 'Version 17\.0\.0.*Build 595' || true)"
[[ -n "$version_line" ]] || {
  echo "runtime is not Quartus 17.0.0 Build 595" >&2
  exit 1
}

# Run each stage directly instead of `quartus_sh --flow compile`. Under Rosetta,
# quartus_map's RTL helper processes deadlock with their parent during larger
# syntheses even with PARALLEL_SYNTHESIS OFF; --parallel=1 prevents the
# helpers. The fitter keeps the pinned NUM_PARALLEL_PROCESSORS, which changes
# placement and must match between local and CI builds. Docker uses the same
# stages so both lanes run one flow.
"${RUN[@]}" quartus_map --parallel=1 example
"${RUN[@]}" quartus_fit example
"${RUN[@]}" quartus_asm example
"${RUN[@]}" quartus_sta example
RBF="$ROOT/fpga/output_files/example.rbf"
[[ -f "$RBF" ]] || {
  echo "Quartus completed without output_files/example.rbf" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

MANIFEST="$ROOT/fpga/output_files/build-manifest.txt"
{
  echo "format=apple-containers-example-quartus-v1"
  echo "source_commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "quartus_version=$version_line"
  echo "quartus_flow=map(parallel=1),fit,asm,sta"
  echo "quartus_seed=2"
  echo "quartus_processors=4"
  echo "parallel_synthesis=off"
  echo "installer_sha1=99ccfb15962febceba64de2dc9b28c47e5a3b8df"
  echo "cyclonev_sha1=2198dedb99866f38d43ff6c029d4bd668e2bbb59"
  for relative in \
    containers/quartus/runtime.Containerfile \
    scripts/quartus-build.sh \
    scripts/quartus-downloads.sh \
    fpga/example.qpf \
    fpga/example.qsf \
    fpga/example.v \
    fpga/output_files/example.rbf
  do
    echo "sha256.$relative=$(sha256_file "$ROOT/$relative")"
  done
} > "$MANIFEST"

echo "$RBF"
echo "$MANIFEST"
