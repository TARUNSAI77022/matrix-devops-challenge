# Defense EO/IR Perception Stack — Operational Runbook & Audit Report

**Target Scope:** `vision_api` (port 8000), `inference_worker` (port 9000), `postgres` (port 5432)  
**Environments:** x86_64 Lab CI/CD, NVIDIA Jetson Orin (`aarch64`), Air-Gapped Field Deployments  

---

## 1. Audit & Remediation Matrix (Task 1 Flaws)

| Component & Location | Original Flaw & Root Cause | Implemented Engineering Fix |
| :--- | :--- | :--- |
| **Dockerfile** (`L1-51`) | Bloated image (>1 GB), ran as root (UID 0), build tools included, TRT cache unwriteable. | Multi-stage build on `python:3.11-slim`, non-root user `appuser` (10001:10001), pre-created `models/.trt_cache`; final image size **205.86 MB** (< 220 MB limit). |
| **Compose Network** (`docker-compose.yml:14,37,70`) | `vision_api` isolated on `edge_dmz`, unable to reach worker/db on `sensor_backplane`; URL set to `localhost:9001`. | Attached `vision_api` to both networks; corrected worker address to internal DNS `http://inference_worker:9000`. |
| **Worker Healthcheck** (`docker-compose.yml:31-36`) | Dummy healthcheck (`echo worker_alive \|\| exit 0`) returned 0 even if model was corrupted or worker crashed. | Active HTTP probe (`curl -f http://localhost:9000/status`, 5s interval, 2 retries); marks worker `unhealthy` in < 15s. |
| **Startup Ordering** (`docker-compose.yml:58-62`) | Simple `depends_on` booted API before 2s worker warmup completed, trapping API in degraded state. | Upgraded dependencies to `condition: service_healthy` for both `inference_worker` and `postgres`. |
| **Session Resilience** (`vision_api/app.py:33-37`) | Static boolean `STARTUP_SESSION_VALID` evaluated once; API locked at HTTP 503 if boot handshake missed. | Added dynamic readiness re-evaluation in request handler; self-heals immediately upon worker recovery. |
| **Model Manifest** (`models/manifest.json:10`) | Engine SHA-256 in manifest did not match binary on disk (`0aaf4681...`), failing startup check. | Updated `manifest.json` with verified SHA-256 digest; `tests/test_manifest.py` passes with zero errors. |
| **CI/CD Pipeline** (`ci.yml:54-67,73-109`) | Test failures suppressed with `|| true`, unverified models built, mutable `:latest` image tags. | Removed `|| true`, added model check step, gated builds on `needs: lint_and_test`, enforced immutable tags (`${VERSION}-${SHORT_SHA}`). |
| **Secrets & Context** (`.env.example`, `.dockerignore`) | Plaintext database password and dummy keys hardcoded in Compose; secrets committed to Git. | Extracted secrets to `.env.example` / `.env` contract; added `.dockerignore` and `.gitignore` to prevent secret leaks. |

---

## 2. Field Rollback Runbook (15-Minute Change Window)

**Scenario:** Newly promoted `eo_detector_fp16.engine` causes `inference_worker` to enter `unhealthy` state on an air-gapped node.

```
[T+00:00] Triage Failure ──> [T+03:00] Isolate Services ──> [T+06:00] Revert Model ──> [T+09:00] Restart Stack ──> [T+12:00] Verification
```

1. **T+0:00 – T+3:00 (Triage):**
   - Check container health: `docker compose ps` (Worker indicates `unhealthy`).
   - Confirm failure cause: `docker compose logs --tail=20 inference_worker` (Look for `checksum_valid=False` or TRT initialization error).
2. **T+3:00 – T+6:00 (Service Isolation):**
   - Stop perception services while preserving database state:
     `docker compose stop vision_api inference_worker`
3. **T+6:00 – T+9:00 (Artifact Reversion):**
   - Quarantine failing model and restore previous verified baseline (v1.4.1):
     `mv models/eo_detector_fp16.engine models/eo_detector_fp16.engine.bad`  
     `cp /opt/defense_stack/backups/v1.4.1/eo_detector_fp16.engine models/`  
     `cp /opt/defense_stack/backups/v1.4.1/manifest.json models/`  
     `rm -rf models/.trt_cache/*`
4. **T+9:00 – T+12:00 (Relaunch Services):**
   - Verify checksum: `sha256sum models/eo_detector_fp16.engine` (Verify hash matches restored manifest).
   - Bring services back online: `docker compose up -d inference_worker vision_api`
5. **T+12:00 – T+15:00 (Operational Sign-Off):**
   - Validate health endpoint: `curl -fsS http://localhost:8000/health` (Expect: HTTP 200, `{"worker_ready": true}`).
   - Validate detection stream: `curl -fsS http://localhost:8000/api/v1/detect` (Expect: HTTP 200, valid detection JSON).

---

## 3. Preventing Lab vs Edge Runtime Drift (x86_64 vs Jetson Orin aarch64)

Serialized TensorRT plan files (`*.engine`) are hardware-specific binaries and cannot run interchangeably across architectures:
- **Root Cause of Incompatibility:** x86_64 lab GPUs use SM architectures like `sm_86` or `sm_89`, while Jetson Orin uses Tegra `sm_87` alongside an aarch64 ARM CPU ISA.
- **Engineering Safeguards:**
  1. **Golden Model Interchange:** Maintain model baselines exclusively as platform-agnostic `.onnx` files in source control. Never ship lab-compiled `.engine` binaries to Jetson targets.
  2. **Targeted Compilation Environments:** Build production engines inside matching NVIDIA JetPack containers (e.g. `nvcr.io/nvidia/l4t-tensorrt:r35.4.1` for JetPack 5.1.2) running natively on Jetson hardware or cross-compilation toolchains.
  3. **Manifest Hardware Binding:** Bind `target_arch: "aarch64"`, `compute_capability: "sm_87"`, and `tensorrt_version` directly in `models/manifest.json`.
  4. **Worker Pre-Flight Check:** Before allocating inference context, `worker.py` queries `cuda.Device(0).compute_capability()` to reject incompatible engine architectures before kernel execution.

---

## 4. Release & Air-Gap Verification Status

- **Task 1: Stack Hardening & Healthchecks:** **VERIFIED** (Cold-boot healthy, image size 205.86 MB, non-root UID 10001, automated unit test suites passing).
- **Task 2: Air-Gapped Packaging & Deployment Scripts:**
  - **Implementation Status:** **COMPLETE** — Scripts hardened with external image pre-pulling, local image inspection, `--pull never` offline enforcement, and `.env` secret validation.
  - **Pre-Flight Validation:** **PASSED** — POSIX syntax validated (`bash -n`), checksum tools verified, and manifest generation logic audited.
  - **Operational Status:** **Pending Field Site Acceptance Testing (SAT)** — Ready for final end-to-end execution on an isolated, physical air-gapped target host.
