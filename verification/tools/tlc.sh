#!/usr/bin/env bash
# Run the TLC model checker with pinned TLA+ tools.
#
# Usage: verification/tools/tlc.sh [TLC options] -config <cfg> <spec.tla>
#        verification/tools/tlc.sh --fetch-only
#
# The tools come from the official TLA+ VS Code extension on Open VSX, which
# bundles tla2tools.jar and CommunityModules-deps.jar. (nightly.tlapl.us and
# GitHub release downloads are not reachable from every environment.)
# Every download is checked against the SHA-256 sums below.
#
# Environment:
#   TLA_CACHE     where the jars and TLC state go (default: verification/.cache)
#   TLC_JAVA_OPTS extra JVM options (default: -XX:+UseParallelGC)

set -euo pipefail

EXT_VERSION="2026.10.60203" # TLC build 2026.10.06 (rev 94d0c50)
EXT_SHA256="7f7bfdaa61f26cd83a837e85b92f36ce00ee47eed344f464087cce7877d2c551"
TLA2TOOLS_SHA256="7beec0f04818732a62fa193731711a99aa4f11279499b2360a7d156c519ea78d"
COMMUNITY_SHA256="dddb19c3d7596913d92c43073b60d1408ac8f6d86716af4d19dd6861a95bfb7d"
EXT_URL="https://open-vsx.org/api/tlaplus/vscode-ide/${EXT_VERSION}/file/tlaplus.vscode-ide-${EXT_VERSION}.vsix"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${TLA_CACHE:-${ROOT}/.cache}"
TOOLS="${CACHE}/tools/${EXT_VERSION}"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

check() { # file expected-sha
  local got
  got="$(sha256 "$1")"
  if [[ "${got}" != "$2" ]]; then
    echo "tlc.sh: checksum mismatch for $1: got ${got}, want $2" >&2
    return 1
  fi
}

fetch() {
  if [[ -f "${TOOLS}/tla2tools.jar" && -f "${TOOLS}/CommunityModules-deps.jar" ]] &&
    check "${TOOLS}/tla2tools.jar" "${TLA2TOOLS_SHA256}" &&
    check "${TOOLS}/CommunityModules-deps.jar" "${COMMUNITY_SHA256}"; then
    return
  fi
  mkdir -p "${TOOLS}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  echo "tlc.sh: downloading TLA+ tools ${EXT_VERSION}" >&2
  curl -fsSL --retry 4 -o "${tmp}/ext.vsix" "${EXT_URL}"
  check "${tmp}/ext.vsix" "${EXT_SHA256}"
  unzip -q -j -o "${tmp}/ext.vsix" \
    extension/tools/tla2tools.jar extension/tools/CommunityModules-deps.jar -d "${tmp}"
  check "${tmp}/tla2tools.jar" "${TLA2TOOLS_SHA256}"
  check "${tmp}/CommunityModules-deps.jar" "${COMMUNITY_SHA256}"
  mv "${tmp}/tla2tools.jar" "${tmp}/CommunityModules-deps.jar" "${TOOLS}/"
}

fetch
if [[ "${1:-}" == "--fetch-only" ]]; then
  exit 0
fi

META="${CACHE}/states/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "${META}"
# shellcheck disable=SC2086
exec java ${TLC_JAVA_OPTS:--XX:+UseParallelGC} \
  -cp "${TOOLS}/tla2tools.jar:${TOOLS}/CommunityModules-deps.jar" \
  tlc2.TLC -metadir "${META}" "$@"
