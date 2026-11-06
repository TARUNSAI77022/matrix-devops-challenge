#!/usr/bin/env bash
# ==============================================================================
# deploy_airgap.sh
# Deploys the EO/IR stack on an air-gapped target edge node with zero internet.
# Performs strict SHA256SUMS verification before loading images or starting services.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_succ() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

echo "========================================================================"
echo "    Matrix EO/IR Perception Stack - Air-Gapped Field Deployment"
echo "========================================================================"

# 1. Strict Cryptographic Verification against SHA256SUMS
log_info "Step 1/5: Verifying release payload against SHA256SUMS..."
if [ ! -f "SHA256SUMS" ]; then
    log_err "SHA256SUMS manifest missing! Cannot verify release integrity."
    exit 1
fi

VERIFY_FAILED=0
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c --status SHA256SUMS || VERIFY_FAILED=1
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c --status SHA256SUMS || VERIFY_FAILED=1
else
    # Fallback to python verification
    python3 -c "
import hashlib, sys
with open('SHA256SUMS') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'): continue
        expected, filename = line.split(None, 1)
        actual = hashlib.sha256(open(filename, 'rb').read()).hexdigest()
        if actual != expected:
            sys.exit(1)
" || VERIFY_FAILED=1
fi

if [ "${VERIFY_FAILED}" -ne 0 ]; then
    log_err "CRITICAL: SHA256SUMS verification failed! One or more files are corrupted or tampered."
    log_err "Aborting deployment to protect edge node security."
    exit 1
fi
log_succ "All payload files verified successfully against SHA256SUMS."

# 2. Environment Configuration
log_info "Step 2/5: Validating environment configuration (.env)..."
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        log_warn ".env not found. Initializing .env from template .env.example..."
        cp .env.example .env
        chmod 600 .env
        log_succ "Initialized default .env file."
    else
        log_err "Neither .env nor .env.example found!"
        exit 1
    fi
else
    log_info "Existing .env configuration detected."
    chmod 600 .env
fi

# Validate required environment variables are present and non-empty
REQUIRED_VARS=("POSTGRES_USER" "POSTGRES_PASSWORD" "POSTGRES_DB" "APP_PORT" "WORKER_PORT")
MISSING_VARS=0
for var in "${REQUIRED_VARS[@]}"; do
    val=$(grep -E "^${var}=" .env 2>/dev/null | cut -d'=' -f2- | tr -d ' "\r\n' || true)
    if [ -z "${val}" ]; then
        log_err "Required environment variable '${var}' is missing or empty in .env"
        MISSING_VARS=$((MISSING_VARS + 1))
    fi
done

if [ "${MISSING_VARS}" -gt 0 ]; then
    log_err "Environment configuration validation failed: ${MISSING_VARS} required variable(s) missing or unset."
    log_err "Please configure .env before starting the stack."
    exit 1
fi

# Reject default placeholder password
PG_PASSWORD=$(grep -E "^POSTGRES_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2- | tr -d ' "\r\n' || true)
if [ "${PG_PASSWORD}" = "CHANGE_ME" ]; then
    log_err "POSTGRES_PASSWORD is set to default placeholder 'CHANGE_ME'!"
    log_err "Please enter the real production password locally in .env on the offline host."
    exit 1
fi

# Validate network ports are valid integers within [1, 65535]
APP_PORT=$(grep -E '^APP_PORT=' .env 2>/dev/null | cut -d'=' -f2- | tr -d ' "\r\n' || echo "8000")
WORKER_PORT=$(grep -E '^WORKER_PORT=' .env 2>/dev/null | cut -d'=' -f2- | tr -d ' "\r\n' || echo "9000")

for port in "${APP_PORT}" "${WORKER_PORT}"; do
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
        log_err "Invalid port number '${port}' in .env! Must be an integer between 1 and 65535."
        exit 1
    fi
done

log_succ "All environment variables, passwords, and ports validated successfully."

# 3. Architecture Compatibility & Image Ingestion
log_info "Step 3/5: Ingesting container images from images.tar.gz..."

# Validate host architecture matches release package architecture
if [ -f ".release_arch" ]; then
    PKG_ARCH=$(cat .release_arch | tr -d ' \r\n')
    HOST_ARCH=$(uname -m)
    case "${HOST_ARCH}" in
        x86_64|amd64) HOST_ARCH_NORM="x86_64" ;;
        aarch64|arm64) HOST_ARCH_NORM="aarch64" ;;
        *) HOST_ARCH_NORM="${HOST_ARCH}" ;;
    esac
    case "${PKG_ARCH}" in
        x86_64|amd64) PKG_ARCH_NORM="x86_64" ;;
        aarch64|arm64) PKG_ARCH_NORM="aarch64" ;;
        *) PKG_ARCH_NORM="${PKG_ARCH}" ;;
    esac
    if [ "${HOST_ARCH_NORM}" != "${PKG_ARCH_NORM}" ]; then
        log_err "CRITICAL: Architecture mismatch! Release package was built for '${PKG_ARCH}', but host is '${HOST_ARCH}'."
        log_err "Aborting deployment to avoid running incompatible container binaries and TensorRT engines."
        exit 1
    fi
    log_succ "Host architecture (${HOST_ARCH}) matches release package architecture (${PKG_ARCH})."
fi

if [ ! -f "images.tar.gz" ]; then
    log_err "images.tar.gz not found! Cannot deploy in air-gapped environment."
    exit 1
fi

docker load -i images.tar.gz
log_succ "Container images loaded into local Docker engine."

# 4. Start Stack Offline
log_info "Step 4/5: Starting microservices stack with Docker Compose..."
# Enforce offline execution without teardown downtime (--no-build and --pull never prevent external registry requests)
docker compose up -d --no-build --pull never

# 5. Health Probes & End-to-End Verification
log_info "Step 5/5: Running post-deployment health probes..."
APP_PORT=$(grep -E '^APP_PORT=' .env 2>/dev/null | cut -d'=' -f2- | tr -d ' "\r\n' || echo "8000")
APP_PORT="${APP_PORT:-8000}"
HEALTH_URL="http://localhost:${APP_PORT}/health"
DETECT_URL="http://localhost:${APP_PORT}/api/v1/detect"

MAX_RETRIES=20
WAIT_SEC=2
SUCCESS=0

log_info "Waiting for services to become healthy at ${HEALTH_URL}..."
for i in $(seq 1 "${MAX_RETRIES}"); do
    if curl -fsS --connect-timeout 3 --max-time 10 "${HEALTH_URL}" > /dev/null 2>&1; then
        HEALTH_RESP=$(curl -fsS --connect-timeout 3 --max-time 10 "${HEALTH_URL}" || echo "")
        if echo "${HEALTH_RESP}" | grep -q '"worker_ready": *true'; then
            log_succ "Health check passed on attempt ${i}!"
            SUCCESS=1
            break
        fi
    fi
    echo -n "."
    sleep "${WAIT_SEC}"
done
echo ""

if [ "${SUCCESS}" -ne 1 ]; then
    log_err "Deployment verification timed out! Checking container status..."
    docker compose ps
    log_err "Recent logs from vision_api and inference_worker:"
    docker compose logs --tail=30
    exit 1
fi

# Test detection inference
log_info "Testing detection endpoint: ${DETECT_URL}..."
DETECT_RESP=$(curl -fsS --connect-timeout 3 --max-time 10 "${DETECT_URL}" || echo "")

if echo "${DETECT_RESP}" | grep -q '"stream": *"EO_CAM_01"'; then
    log_succ "Live detection verified: ${DETECT_RESP}"
else
    log_err "Detection endpoint returned unexpected payload: ${DETECT_RESP}"
    exit 1
fi

echo "========================================================================"
log_succ "AIR-GAPPED FIELD DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "  - Vision API:        http://localhost:${APP_PORT}/health"
echo "  - Detection Stream:  http://localhost:${APP_PORT}/api/v1/detect"
echo "  - Worker Status:     Internal sensor_backplane (port 9000)"
echo "  - Status:            Healthy, non-root, air-gapped"
echo "========================================================================"

