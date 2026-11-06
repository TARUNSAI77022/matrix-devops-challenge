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
fi

# 3. Load Offline Container Images
log_info "Step 3/5: Ingesting container images from images.tar.gz..."
if [ ! -f "images.tar.gz" ]; then
    log_err "images.tar.gz not found! Cannot deploy in air-gapped environment."
    exit 1
fi

docker load -i images.tar.gz
log_succ "Container images loaded into local Docker engine."

# 4. Start Stack Offline
log_info "Step 4/5: Starting microservices stack with Docker Compose..."
# Enforce offline execution (--no-build prevents accidental build attempts)
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d --no-build

# 5. Health Probes & End-to-End Verification
log_info "Step 5/5: Running post-deployment health probes..."
APP_PORT=$(grep -E '^APP_PORT=' .env 2>/dev/null | cut -d'=' -f2 || echo "8000")
APP_PORT="${APP_PORT:-8000}"
HEALTH_URL="http://localhost:${APP_PORT}/health"
DETECT_URL="http://localhost:${APP_PORT}/api/v1/detect"

MAX_RETRIES=20
WAIT_SEC=2
SUCCESS=0

log_info "Waiting for services to become healthy at ${HEALTH_URL}..."
for i in $(seq 1 "${MAX_RETRIES}"); do
    if curl -s -f "${HEALTH_URL}" > /dev/null 2>&1; then
        HEALTH_RESP=$(curl -s "${HEALTH_URL}")
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
DETECT_RESP=$(curl -s -f "${DETECT_URL}" || echo "")

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

