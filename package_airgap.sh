#!/usr/bin/env bash
# ==============================================================================
# package_airgap.sh
# Creates an immutable, self-contained air-gapped release bundle for deployment.
# Output: release_v<VERSION>.tar.gz with complete SHA256SUMS manifest.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_succ() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
log_err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

# 1. Determine release version from models/manifest.json
if [ ! -f "models/manifest.json" ]; then
    log_err "models/manifest.json not found!"
    exit 1
fi

VERSION=$(python3 -c "import json; print(json.load(open('models/manifest.json'))['version'])" 2>/dev/null || \
          python -c "import json; print(json.load(open('models/manifest.json'))['version'])" 2>/dev/null || \
          grep -o '"version"[^,]*' models/manifest.json | cut -d'"' -f4 || echo "1.4.2")

# Determine target architecture (x86_64 vs aarch64 NVIDIA Jetson Orin)
TARGET_ARCH="${1:-${TARGET_ARCH:-$(uname -m)}}"
case "${TARGET_ARCH}" in
    x86_64|amd64)
        TARGET_ARCH="x86_64"
        DOCKER_PLATFORM="linux/amd64"
        ;;
    aarch64|arm64)
        TARGET_ARCH="aarch64"
        DOCKER_PLATFORM="linux/arm64"
        ;;
    *)
        TARGET_ARCH="$(uname -m)"
        DOCKER_PLATFORM="linux/${TARGET_ARCH}"
        ;;
esac

BUNDLE_NAME="release_v${VERSION}_${TARGET_ARCH}"
TAR_FILE="${BUNDLE_NAME}.tar.gz"
STAGING_DIR="dist/${BUNDLE_NAME}"

log_info "Packaging air-gapped release bundle: ${BUNDLE_NAME} (Target Arch: ${TARGET_ARCH}, Platform: ${DOCKER_PLATFORM})"

# 2. Verify model integrity locally before packaging
MODEL_MANIFEST="models/manifest.json"
if [ -f "models/${TARGET_ARCH}/manifest.json" ]; then
    MODEL_MANIFEST="models/${TARGET_ARCH}/manifest.json"
    log_info "Selected architecture-specific manifest: ${MODEL_MANIFEST}"
fi

MODEL_ENGINE="models/eo_detector_fp16.engine"
if [ -f "models/${TARGET_ARCH}/eo_detector_fp16.engine" ]; then
    MODEL_ENGINE="models/${TARGET_ARCH}/eo_detector_fp16.engine"
    log_info "Selected architecture-specific engine: ${MODEL_ENGINE}"
fi

log_info "Verifying model engine SHA256 against ${MODEL_MANIFEST}..."
EXPECTED_SHA=$(python3 -c "import json; print(json.load(open('${MODEL_MANIFEST}'))['sha256'])" 2>/dev/null || \
               python -c "import json; print(json.load(open('${MODEL_MANIFEST}'))['sha256'])" 2>/dev/null || \
               grep -o '"sha256"[^,]*' "${MODEL_MANIFEST}" | cut -d'"' -f4)

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA=$(sha256sum "${MODEL_ENGINE}" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA=$(shasum -a 256 "${MODEL_ENGINE}" | awk '{print $1}')
else
    ACTUAL_SHA=$(python3 -c "import hashlib; print(hashlib.sha256(open('${MODEL_ENGINE}','rb').read()).hexdigest())")
fi

if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
    log_err "Model engine checksum mismatch! Refusing to package unverified model."
    log_err "Expected: ${EXPECTED_SHA}"
    log_err "Actual:   ${ACTUAL_SHA}"
    exit 1
fi
log_succ "Model checksum verified: ${ACTUAL_SHA:0:16}..."

# 3. Build container images with release tags for target architecture
log_info "Building container images for release v${VERSION} on ${DOCKER_PLATFORM}..."
DOCKER_DEFAULT_PLATFORM="${DOCKER_PLATFORM}" docker compose build

# Tag images explicitly for export
IMAGE_WORKER="devops_challenge-inference_worker:v${VERSION}"
IMAGE_API="devops_challenge-vision_api:v${VERSION}"
IMAGE_PG="postgres:15-alpine"

# Pull PostgreSQL base image for target platform before exporting it (fail if unavailable)
log_info "Pulling PostgreSQL base image (${IMAGE_PG}) for ${DOCKER_PLATFORM}..."
if ! docker pull --platform "${DOCKER_PLATFORM}" "${IMAGE_PG}"; then
    log_err "Failed to pull PostgreSQL image for target platform ${DOCKER_PLATFORM}! Aborting packaging."
    exit 1
fi

# Verify all required images exist before packaging
log_info "Verifying all required container images exist locally..."
for img in "${IMAGE_WORKER}" "${IMAGE_API}" "${IMAGE_PG}"; do
    if ! docker image inspect "${img}" >/dev/null 2>&1; then
        log_err "Required container image ${img} not found locally! Packaging aborted."
        exit 1
    fi
    log_succ "Verified image: ${img}"
done

# 4. Prepare fresh staging directory
log_info "Preparing staging directory at ${STAGING_DIR}..."
rm -rf "dist"
mkdir -p "${STAGING_DIR}/models"

# 5. Export container images to compressed archive
log_info "Exporting container images to ${STAGING_DIR}/images.tar.gz..."
docker save "${IMAGE_WORKER}" "${IMAGE_API}" "${IMAGE_PG}" | gzip -c > "${STAGING_DIR}/images.tar.gz"

# 6. Copy orchestration and deployment files
log_info "Copying configuration, models, and deployment runbooks..."
cp "docker-compose.yml" "${STAGING_DIR}/"
cp ".env.example" "${STAGING_DIR}/"
cp "${MODEL_MANIFEST}" "${STAGING_DIR}/models/manifest.json"
cp "${MODEL_ENGINE}" "${STAGING_DIR}/models/eo_detector_fp16.engine"
cp "deploy_airgap.sh" "${STAGING_DIR}/"
chmod +x "${STAGING_DIR}/deploy_airgap.sh"
echo "${TARGET_ARCH}" > "${STAGING_DIR}/.release_arch"

# 7. Generate SHA256SUMS checksum manifest covering every payload file
log_info "Validating checksum generation utilities..."
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    log_err "Neither 'sha256sum' nor 'shasum' is installed! Cannot generate SHA256SUMS manifest."
    exit 1
fi

log_info "Generating SHA256SUMS manifest..."
(
    cd "${STAGING_DIR}"
    # Generate checksums for all files relative to bundle root
    find . -type f ! -name "SHA256SUMS" | sort | while read -r f; do
        # Strip leading ./ for clean POSIX paths
        CLEAN_PATH="${f#./}"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "${CLEAN_PATH}"
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "${CLEAN_PATH}"
        fi
    done > "SHA256SUMS"
)

if [ ! -s "${STAGING_DIR}/SHA256SUMS" ]; then
    log_err "Generated SHA256SUMS manifest is empty or missing! Aborting packaging."
    exit 1
fi
log_succ "SHA256SUMS manifest generated successfully:"
sed 's/^/  /' "${STAGING_DIR}/SHA256SUMS"

# 8. Create compressed tarball bundle
log_info "Creating final air-gapped bundle: ${TAR_FILE}..."
tar -czf "${TAR_FILE}" -C dist "${BUNDLE_NAME}"

BUNDLE_SIZE=$(du -h "${TAR_FILE}" | cut -f1)
log_succ "Air-gapped release bundle created successfully!"
echo "------------------------------------------------------------------------"
echo "  Release Archive: ${TAR_FILE} (${BUNDLE_SIZE})"
echo "  Target Extract:  tar -xzf ${TAR_FILE}"
echo "  Target Deploy:   cd ${BUNDLE_NAME} && ./deploy_airgap.sh"
echo "------------------------------------------------------------------------"

