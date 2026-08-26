#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# waybill SBOM Action - Download and execute waybill
# =============================================================================

WAYBILL_VERSION="${INPUT_WAYBILL_VERSION:-v0.2.0}"
SCAN_PATH="${INPUT_PATH}"
SCAN_IMAGE="${INPUT_IMAGE}"
FORMAT="${INPUT_FORMAT:-cyclonedx-json}"
OUTPUT_FILE="${INPUT_OUTPUT_FILE:-sbom.json}"
INCLUDE_DEV="${INPUT_INCLUDE_DEV:-false}"
OFFLINE="${INPUT_OFFLINE:-false}"
IMAGE_SRC="${INPUT_IMAGE_SRC:-}"

# --- Validate inputs ---------------------------------------------------------

if [[ -z "${SCAN_PATH}" && -z "${SCAN_IMAGE}" ]]; then
  SCAN_PATH="."
fi

if [[ -n "${SCAN_PATH}" && -n "${SCAN_IMAGE}" ]]; then
  echo "::error::Both 'path' and 'image' inputs are set. They are mutually exclusive."
  exit 1
fi

# --- Detect platform ----------------------------------------------------------

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "${OS}" in
  linux)  PLATFORM_OS="unknown-linux-gnu" ;;
  darwin) PLATFORM_OS="apple-darwin" ;;
  *)
    echo "::error::Unsupported OS: ${OS}"
    exit 1
    ;;
esac

case "${ARCH}" in
  x86_64|amd64)   PLATFORM_ARCH="x86_64" ;;
  aarch64|arm64)   PLATFORM_ARCH="aarch64" ;;
  *)
    echo "::error::Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

BINARY_NAME="waybill-${WAYBILL_VERSION}-${PLATFORM_ARCH}-${PLATFORM_OS}"
DOWNLOAD_URL="https://github.com/kusari-oss/waybill/releases/download/${WAYBILL_VERSION}/${BINARY_NAME}.tar.gz"
CHECKSUM_URL="https://github.com/kusari-oss/waybill/releases/download/${WAYBILL_VERSION}/SHA256SUMS"

# --- Download and verify ------------------------------------------------------

INSTALL_DIR="${RUNNER_TEMP:-/tmp}/waybill"
mkdir -p "${INSTALL_DIR}"

echo "::group::Downloading waybill ${WAYBILL_VERSION} (${PLATFORM_ARCH}-${PLATFORM_OS})"
echo "URL: ${DOWNLOAD_URL}"

curl -fsSL --retry 3 -o "${INSTALL_DIR}/${BINARY_NAME}.tar.gz" "${DOWNLOAD_URL}"
curl -fsSL --retry 3 -o "${INSTALL_DIR}/SHA256SUMS" "${CHECKSUM_URL}"

echo "Verifying SHA256 checksum..."
cd "${INSTALL_DIR}"
if command -v sha256sum &>/dev/null; then
  grep "${BINARY_NAME}.tar.gz" SHA256SUMS | sha256sum --check --strict
elif command -v shasum &>/dev/null; then
  grep "${BINARY_NAME}.tar.gz" SHA256SUMS | shasum -a 256 --check --strict
else
  echo "::warning::No sha256sum or shasum available — skipping checksum verification"
fi

echo "Extracting..."
tar -xzf "${BINARY_NAME}.tar.gz"
chmod +x "${BINARY_NAME}/waybill"
mv "${BINARY_NAME}/waybill" ./waybill
cd - >/dev/null

WAYBILL="${INSTALL_DIR}/waybill"
echo "waybill installed at: ${WAYBILL}"
"${WAYBILL}" --version || true
echo "::endgroup::"

# --- Build command ------------------------------------------------------------

CMD=("${WAYBILL}")

# Global flags
if [[ "${OFFLINE}" == "true" ]]; then
  CMD+=("--offline")
fi

# waybill includes all scopes by default; exclude dev/build/test unless requested
if [[ "${INCLUDE_DEV}" != "true" ]]; then
  CMD+=("--exclude-scope" "dev,build,test")
fi

CMD+=("sbom" "scan")

# Scan target
if [[ -n "${SCAN_PATH}" ]]; then
  CMD+=("--path" "${SCAN_PATH}")
elif [[ -n "${SCAN_IMAGE}" ]]; then
  CMD+=("--image" "${SCAN_IMAGE}")
  if [[ -n "${IMAGE_SRC}" ]]; then
    CMD+=("--image-src" "${IMAGE_SRC}")
  fi
fi

# Output format and file
CMD+=("--format" "${FORMAT}")
CMD+=("--output" "${OUTPUT_FILE}")

# --- Execute ------------------------------------------------------------------

echo "::group::Running waybill SBOM scan"
echo "Command: ${CMD[*]}"
"${CMD[@]}"
echo "::endgroup::"

# --- Set outputs --------------------------------------------------------------

SBOM_ABSOLUTE_PATH="$(realpath "${OUTPUT_FILE}")"
echo "sbom-path=${SBOM_ABSOLUTE_PATH}" >> "${GITHUB_OUTPUT}"

echo "::notice::SBOM generated successfully at ${SBOM_ABSOLUTE_PATH}"


