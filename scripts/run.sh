#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# waybill SBOM Action: download waybill, verify it, scan, sign.
# =============================================================================

WAYBILL_REPO="kusari-oss/waybill"
WAYBILL_RELEASE_WORKFLOW="${WAYBILL_REPO}/.github/workflows/release.yml"

SCAN_PATH="${INPUT_PATH:-}"
SCAN_IMAGE="${INPUT_IMAGE:-}"
FORMATS="${INPUT_FORMAT:-cyclonedx-json}"
OUTPUT_FILE="${INPUT_OUTPUT_FILE:-}"
OUTPUT_DIR="${INPUT_OUTPUT_DIR:-.}"
SIGN="${INPUT_SIGN:-keyless}"
SIGN_KEY="${INPUT_SIGN_KEY:-}"
WAYBILL_VERSION="${INPUT_WAYBILL_VERSION:-latest}"
VERIFY_PROVENANCE="${INPUT_VERIFY_PROVENANCE:-true}"
INCLUDE_DEV="${INPUT_INCLUDE_DEV:-false}"
OFFLINE="${INPUT_OFFLINE:-false}"
IMAGE_SRC="${INPUT_IMAGE_SRC:-}"
EXTRA_ARGS="${INPUT_ARGS:-}"

fail() {
  echo "::error::$*"
  exit 1
}

# --- Validate inputs (before downloading anything) ---------------------------

if [[ -z "${SCAN_PATH}" && -z "${SCAN_IMAGE}" ]]; then
  SCAN_PATH="."
fi
if [[ -n "${SCAN_PATH}" && -n "${SCAN_IMAGE}" ]]; then
  fail "Both 'path' and 'image' are set. They are mutually exclusive."
fi

IFS=',' read -r -a FORMAT_LIST <<< "${FORMATS// /}"
[[ ${#FORMAT_LIST[@]} -gt 0 ]] || fail "'format' is empty."
# A function, not an associative array: macOS ships bash 3.2.
default_name() {
  case "$1" in
    cyclonedx-json) echo "sbom.cdx.json" ;;
    spdx-2.3-json)  echo "sbom.spdx.json" ;;
    spdx-3-json)    echo "sbom.spdx3.json" ;;
    *) return 1 ;;
  esac
}
for f in "${FORMAT_LIST[@]}"; do
  default_name "${f}" >/dev/null || fail "Unknown format '${f}'. Use cyclonedx-json, spdx-2.3-json or spdx-3-json."
done

OUTPUTS=()
if [[ ${#FORMAT_LIST[@]} -eq 1 ]]; then
  OUTPUTS+=("${OUTPUT_FILE:-sbom.json}")
else
  [[ -z "${OUTPUT_FILE}" ]] || fail "'output-file' names one file, but ${#FORMAT_LIST[@]} formats were requested; use 'output-dir'."
  for f in "${FORMAT_LIST[@]}"; do
    OUTPUTS+=("${OUTPUT_DIR%/}/$(default_name "${f}")")
  done
fi
for o in "${OUTPUTS[@]}"; do
  mkdir -p "$(dirname "${o}")"
done

case "${SIGN}" in
  keyless)
    if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
      fail "sign: keyless needs an OIDC token, and this job has none. Grant it with 'permissions: id-token: write'. Pull requests from forks never receive one; for those, set sign: none, e.g. sign: \${{ github.event.pull_request.head.repo.fork && 'none' || 'keyless' }}"
    fi
    ;;
  key)
    [[ -n "${SIGN_KEY}" ]] || fail "sign: key needs 'sign-key' (a PEM private key file)."
    [[ -f "${SIGN_KEY}" ]] || fail "sign-key '${SIGN_KEY}' does not exist."
    ;;
  none)
    echo "::warning::sign: none. The SBOMs will not be signed."
    ;;
  *)
    fail "Unknown sign mode '${SIGN}'. Use keyless, key or none."
    ;;
esac

case "${VERIFY_PROVENANCE}" in
  true|false) ;;
  *) fail "verify-provenance must be true or false." ;;
esac

HAVE_GH=false
if command -v gh >/dev/null 2>&1; then
  HAVE_GH=true
fi
if [[ "${VERIFY_PROVENANCE}" == "true" && "${HAVE_GH}" != "true" ]]; then
  fail "verify-provenance needs the gh CLI, which this runner does not have. Install it, or set verify-provenance: false to rely on the SHA256SUMS check alone."
fi

# --- Resolve the waybill release ---------------------------------------------

if [[ "${WAYBILL_VERSION}" == "latest" ]]; then
  if [[ "${HAVE_GH}" == "true" ]]; then
    WAYBILL_VERSION="$(gh api "repos/${WAYBILL_REPO}/releases/latest" --jq .tag_name)"
  else
    WAYBILL_VERSION="$(curl -fsSL --retry 3 "https://api.github.com/repos/${WAYBILL_REPO}/releases/latest" \
      | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  fi
fi
if [[ ! "${WAYBILL_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  fail "waybill-version '${WAYBILL_VERSION}' is not 'latest' or a release tag such as v0.10.0."
fi

# --- Detect platform ----------------------------------------------------------

case "$(uname -s)" in
  Linux)                  PLATFORM_OS="unknown-linux-gnu"; EXT="tar.gz"; EXE="waybill" ;;
  Darwin)                 PLATFORM_OS="apple-darwin";      EXT="tar.gz"; EXE="waybill" ;;
  MINGW*|MSYS*|CYGWIN*)   PLATFORM_OS="pc-windows-msvc";   EXT="zip";    EXE="waybill.exe" ;;
  *) fail "Unsupported OS: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  PLATFORM_ARCH="x86_64" ;;
  aarch64|arm64) PLATFORM_ARCH="aarch64" ;;
  *) fail "Unsupported architecture: $(uname -m)" ;;
esac

ASSET_DIR="waybill-${WAYBILL_VERSION}-${PLATFORM_ARCH}-${PLATFORM_OS}"
ASSET="${ASSET_DIR}.${EXT}"

# --- Download and verify ------------------------------------------------------

INSTALL_DIR="${RUNNER_TEMP:-/tmp}/waybill-${WAYBILL_VERSION}"
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

echo "::group::Downloading waybill ${WAYBILL_VERSION} (${PLATFORM_ARCH}-${PLATFORM_OS})"
if [[ "${HAVE_GH}" == "true" ]]; then
  gh release download "${WAYBILL_VERSION}" --repo "${WAYBILL_REPO}" \
    --pattern "${ASSET}" --pattern SHA256SUMS --dir "${INSTALL_DIR}" \
    || fail "Could not download ${ASSET} from ${WAYBILL_REPO} ${WAYBILL_VERSION}; this platform may have no build in that release."
else
  base="https://github.com/${WAYBILL_REPO}/releases/download/${WAYBILL_VERSION}"
  curl -fsSL --retry 3 -o "${INSTALL_DIR}/${ASSET}" "${base}/${ASSET}" \
    || fail "Could not download ${base}/${ASSET}."
  curl -fsSL --retry 3 -o "${INSTALL_DIR}/SHA256SUMS" "${base}/SHA256SUMS"
fi

cd "${INSTALL_DIR}"
echo "Verifying SHA-256 against SHA256SUMS..."
expected="$(awk -v a="${ASSET}" '$2 == a {print $1}' SHA256SUMS)"
[[ -n "${expected}" ]] || fail "${ASSET} is not listed in SHA256SUMS."
# Computed and compared here: GNU, BSD (macOS) and Git Bash checksum tools
# disagree on their --check flags.
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${ASSET}" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "${ASSET}" | awk '{print $1}')"
fi
[[ "${actual}" == "${expected}" ]] || fail "SHA-256 mismatch for ${ASSET}: expected ${expected}, got ${actual}."
echo "${ASSET}: OK"

if [[ "${VERIFY_PROVENANCE}" == "true" ]]; then
  # Releases are built from their tag; nightlies by the same workflow from main.
  SOURCE_REF="refs/tags/${WAYBILL_VERSION}"
  if [[ "${WAYBILL_VERSION}" == *-nightly.* ]]; then
    SOURCE_REF="refs/heads/main"
  fi
  echo "Verifying SLSA provenance: built by ${WAYBILL_RELEASE_WORKFLOW} from ${SOURCE_REF}..."
  gh attestation verify "${ASSET}" \
    --repo "${WAYBILL_REPO}" \
    --signer-workflow "${WAYBILL_RELEASE_WORKFLOW}" \
    --source-ref "${SOURCE_REF}" \
    || fail "${ASSET} has no valid provenance from ${WAYBILL_RELEASE_WORKFLOW} at ${SOURCE_REF}. Not running it."
fi

if [[ "${EXT}" == "zip" ]]; then
  unzip -q "${ASSET}"
else
  tar -xzf "${ASSET}"
fi
WAYBILL="${INSTALL_DIR}/${ASSET_DIR}/${EXE}"
[[ -f "${WAYBILL}" ]] || fail "${ASSET} does not contain ${ASSET_DIR}/${EXE}."
chmod +x "${WAYBILL}"
cd - >/dev/null
"${WAYBILL}" --version
echo "::endgroup::"

# --- Build the command --------------------------------------------------------

CMD=("${WAYBILL}")
if [[ "${OFFLINE}" == "true" ]]; then
  CMD+=("--offline")
fi
# waybill includes every scope by default; exclude dev/build/test unless asked.
if [[ "${INCLUDE_DEV}" != "true" ]]; then
  CMD+=("--exclude-scope" "dev,build,test")
fi

CMD+=("sbom" "scan")
if [[ -n "${SCAN_PATH}" ]]; then
  CMD+=("--path" "${SCAN_PATH}")
else
  CMD+=("--image" "${SCAN_IMAGE}")
  if [[ -n "${IMAGE_SRC}" ]]; then
    CMD+=("--image-src" "${IMAGE_SRC}")
  fi
fi

CMD+=("--format" "$(IFS=,; echo "${FORMAT_LIST[*]}")")
for i in "${!FORMAT_LIST[@]}"; do
  CMD+=("--output" "${FORMAT_LIST[$i]}=${OUTPUTS[$i]}")
done

case "${SIGN}" in
  keyless) CMD+=("--sign") ;;
  key)     CMD+=("--sign-key" "${SIGN_KEY}") ;;
esac

if [[ -n "${EXTRA_ARGS}" ]]; then
  while IFS= read -r arg; do
    [[ -n "${arg}" ]] && CMD+=("${arg}")
  done <<< "${EXTRA_ARGS}"
fi

# --- Run ----------------------------------------------------------------------

STDERR_LOG="${RUNNER_TEMP:-/tmp}/waybill-stderr.log"
echo "::group::waybill sbom scan"
echo "Command: ${CMD[*]}"
set +e
"${CMD[@]}" 2>&1 | tee "${STDERR_LOG}"
status=${PIPESTATUS[0]}
set -e
echo "::endgroup::"
[[ ${status} -eq 0 ]] || fail "waybill exited with status ${status}."

# --- Collect outputs ------------------------------------------------------------

abspath() {
  local p
  p="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "${p}"
  else
    echo "${p}"
  fi
}

SBOM_PATHS=()
SIG_PATHS=()
for i in "${!FORMAT_LIST[@]}"; do
  out="${OUTPUTS[$i]}"
  [[ -f "${out}" ]] || fail "waybill reported success but ${out} was not written."
  SBOM_PATHS+=("$(abspath "${out}")")
  sig=""
  case "${SIGN}" in
    keyless) sig="${out}.sig.bundle.json" ;;
    # A static key signs CycloneDX in the document itself (JSF); SPDX gets a
    # DSSE sidecar.
    key) [[ "${FORMAT_LIST[$i]}" == "cyclonedx-json" ]] || sig="${out}.sig.json" ;;
  esac
  if [[ -n "${sig}" ]]; then
    [[ -f "${sig}" ]] || fail "Signing was requested but ${sig} was not written."
    SIG_PATHS+=("$(abspath "${sig}")")
  fi
done

# waybill prints the exact verification command for each keyless signature.
IDENTITY=""
VERIFY_CMD=""
if [[ "${SIGN}" == "keyless" ]]; then
  IDENTITY="$(sed -n "s/.*--certificate-identity '\([^']*\)'.*/\1/p" "${STDERR_LOG}" | head -n1)"
  VERIFY_CMD="$(awk '/^To verify/{grab=1; next} grab && NF==0{exit} grab' "${STDERR_LOG}")"
fi

multiline() {
  local name="$1"; shift
  local delim
  delim="EOF_${RANDOM}${RANDOM}${RANDOM}"
  {
    echo "${name}<<${delim}"
    printf '%s\n' "$@"
    echo "${delim}"
  } >> "${GITHUB_OUTPUT}"
}

{
  echo "sbom-path=${SBOM_PATHS[0]}"
  echo "signing-identity=${IDENTITY}"
  echo "waybill-version=${WAYBILL_VERSION}"
} >> "${GITHUB_OUTPUT}"
multiline sbom-paths "${SBOM_PATHS[@]}"
multiline signature-paths "${SIG_PATHS[@]+"${SIG_PATHS[@]}"}"
multiline artifact-paths "${SBOM_PATHS[@]}" "${SIG_PATHS[@]+"${SIG_PATHS[@]}"}"
multiline verify-command "${VERIFY_CMD}"

# --- Job summary ----------------------------------------------------------------

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### SBOM generated with waybill ${WAYBILL_VERSION}"
    echo
    echo "| SBOM | Signature |"
    echo "|---|---|"
    for i in "${!OUTPUTS[@]}"; do
      sig="unsigned"
      case "${SIGN}" in
        keyless) sig="\`$(basename "${OUTPUTS[$i]}").sig.bundle.json\` (Sigstore keyless)" ;;
        key)
          if [[ "${FORMAT_LIST[$i]}" == "cyclonedx-json" ]]; then
            sig="in the document (JSF)"
          else
            sig="\`$(basename "${OUTPUTS[$i]}").sig.json\` (DSSE)"
          fi
          ;;
      esac
      echo "| \`${OUTPUTS[$i]}\` | ${sig} |"
    done
    if [[ -n "${IDENTITY}" ]]; then
      echo
      echo "Signed as \`${IDENTITY}\`. To verify:"
      echo
      echo '```sh'
      echo "${VERIFY_CMD}"
      echo '```'
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi

echo "::notice::Generated ${#SBOM_PATHS[@]} SBOM(s) with waybill ${WAYBILL_VERSION}; signing: ${SIGN}."
