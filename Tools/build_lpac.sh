#!/bin/zsh

set -euo pipefail
setopt null_glob

ROOT_DIR="${0:A:h:h}"
LPAC_ROOT="${ROOT_DIR}/ThirdParty/lpac"
OUTPUT="${1:-${ROOT_DIR}/.build/lpac/lpac}"
DEVELOPER_ROOT="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
CLANG="${DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
SDK="${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"
MINIMUM_VERSION="26.0"

if [[ ! -x "${CLANG}" ]]; then
    print -u2 "Clang toolchain not found: ${CLANG}"
    exit 1
fi

if [[ ! -f "${LPAC_ROOT}/REUSE.toml" ]]; then
    print -u2 "Pinned lpac source not found: ${LPAC_ROOT}"
    exit 1
fi

sources=(
    "${LPAC_ROOT}/cjson/cJSON.c"
    "${LPAC_ROOT}/cjson/cJSON_ex.c"
    "${LPAC_ROOT}"/euicc/*.c
    "${LPAC_ROOT}/utils/lpac/utils.c"
    "${LPAC_ROOT}/driver/driver.c"
    "${LPAC_ROOT}/driver/apdu/stdio.c"
    "${LPAC_ROOT}/driver/http/stdio.c"
    "${LPAC_ROOT}/driver/http/curl.c"
    "${LPAC_ROOT}"/src/*.c
    "${LPAC_ROOT}"/src/applet/**/*.c
)

/bin/mkdir -p "${OUTPUT:h}"
BUILD_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ec25-lpac.XXXXXX")"
trap '/bin/rm -rf "${BUILD_ROOT}"' EXIT

ARM64_OUTPUT="${BUILD_ROOT}/lpac-arm64"
SDKROOT="${SDK}" "${CLANG}" \
    -arch arm64 \
    -mmacosx-version-min="${MINIMUM_VERSION}" \
    -std=c99 \
    -O2 \
    -DLPAC_WITH_HTTP_CURL \
    '-DLPAC_VERSION="v2.3.0"' \
    -I"${LPAC_ROOT}" \
    -I"${LPAC_ROOT}/cjson" \
    -I"${LPAC_ROOT}/driver" \
    -I"${LPAC_ROOT}/euicc" \
    -I"${LPAC_ROOT}/utils" \
    -I"${LPAC_ROOT}/src" \
    "${sources[@]}" \
    -lcurl \
    -o "${ARM64_OUTPUT}"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ARM64_OUTPUT}" "${OUTPUT}"
/bin/chmod 755 "${OUTPUT}"

version="$(${OUTPUT} version)"
if [[ "${version}" != *'"data":"v2.3.0"'* ]]; then
    print -u2 "Unexpected lpac version output: ${version}"
    exit 1
fi

print "Built bundled lpac v2.3.0 for arm64: ${OUTPUT}"
