#!/usr/bin/env bash
# Sourced by the Apple and Docker setup scripts.

QUARTUS_RUN=QuartusLiteSetup-17.0.0.595-linux.run
CYCLONEV_QDZ=cyclonev-17.0.0.595.qdz
QUARTUS_URL="${QUARTUS_17_0_RUN_URL:-https://downloads.intel.com/akdlm/software/acdsinst/17.0std/595/ib_installers/$QUARTUS_RUN}"
CYCLONEV_URL="${QUARTUS_17_0_CYCLONEV_QDZ_URL:-https://downloads.intel.com/akdlm/software/acdsinst/17.0std/595/ib_installers/$CYCLONEV_QDZ}"

download() {
  local destination="$1" url="$2"
  if [[ ! -f "$destination" ]]; then
    curl --fail --location --retry 5 --output "$destination.partial" "$url" || {
      # Intel no longer serves the 17.0.0 files at their original URLs.
      echo "Download failed: $url" >&2
      echo "Copy the file to $destination, or set QUARTUS_17_0_RUN_URL and" >&2
      echo "QUARTUS_17_0_CYCLONEV_QDZ_URL to a mirror you control." >&2
      exit 1
    }
    mv "$destination.partial" "$destination"
  fi
}

verify_sha1() {
  local path="$1" expected="$2" actual
  if command -v sha1sum >/dev/null 2>&1; then
    actual="$(sha1sum "$path" | awk '{print $1}')"
  else
    actual="$(shasum -a 1 "$path" | awk '{print $1}')"
  fi
  [[ "$actual" == "$expected" ]] || {
    echo "SHA-1 mismatch for $path: expected $expected, got $actual" >&2
    exit 1
  }
}

prepare_quartus_downloads() {
  [[ "${QUARTUS_ACCEPT_EULA:-}" == 1 ]] || {
    echo "Accept Intel's Quartus terms, then set QUARTUS_ACCEPT_EULA=1" >&2
    exit 1
  }
  mkdir -p "$CACHE_DIR"
  download "$CACHE_DIR/$QUARTUS_RUN" "$QUARTUS_URL"
  download "$CACHE_DIR/$CYCLONEV_QDZ" "$CYCLONEV_URL"
  verify_sha1 "$CACHE_DIR/$QUARTUS_RUN" 99ccfb15962febceba64de2dc9b28c47e5a3b8df
  verify_sha1 "$CACHE_DIR/$CYCLONEV_QDZ" 2198dedb99866f38d43ff6c029d4bd668e2bbb59
}
