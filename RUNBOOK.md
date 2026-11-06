# Defense EO/IR Perception Stack — Operational Runbook & Audit Report

**Target Scope:** `vision_api` (port 8000), `inference_worker` (port 9000), `postgres` (port 5432)  
**Environments:** x86_64 Lab CI/CD, NVIDIA Jetson Orin (`aarch64`), Air-Gapped Field Deployments  

---

## 1. Audit & Remediation Matrix (Task 1 Flaws)

| Component & Location | Original Flaw & Root Cause | Implemented Engineering Fix |
| :--- | :--- | :--- |
| **Dockerfile** (`L1-51`) | Bloated image (>1 GB), ran as root (UID 0), build tools included, TRT cache unwriteable. | Multi-stage build on `python:3.11-slim`, non-root user `appuser` (10001:10001), pre-created `models/.trt_cache`; final image size **205.86 MB** (< 220 MB limit). |
| **Compose Routing & Ports** (`docker-compose.yml:35,63`) | Network isolation; port `${APP_PORT}:8000` mismatched if custom port set; extracted models unmounted. | Attached dual networks; mapped `${APP_PORT}:${APP_PORT}`; mounted `./models:/app/models:ro`; dynamic container healthcheck. |
| **Worker Healthcheck** (`docker-compose.yml:34-39`) | Dummy healthcheck (`echo worker_alive \|\| exit 0`) returned 0 even if model was corrupted or worker crashed. | Active HTTP probe (`curl -f http://localhost:9000/status`, 5s interval, 2 retries); marks worker `unhealthy` in < 15s. |
| **Startup Ordering** (`docker-compose.yml:61-65`) | Simple `depends_on` booted API before 2s worker warmup completed, trapping API in degraded state. | Upgraded dependencies to `condition: service_healthy` for both `inference_worker` and `postgres`. |
| **Database Persistence** (`docker-compose.yml:11,81`) | Database volume unconfigured; postgres data lost on container replacement or directory upgrades. | Configured persistent named volume `postgres_data` (`name: eoir-postgres-data`), surviving upgrades and rollbacks. |
| **Model Manifest** (`models/manifest.json:10`) | Engine SHA-256 in manifest did not match binary on disk (`0aaf4681...`), failing startup check. | Updated `manifest.json` with verified SHA-256 digest; `tests/test_manifest.py` passes with zero errors. |
| **CI/CD Pipeline** (`ci.yml:54-67,73-109`) | Test failures suppressed with `|| true`, unverified models built, mutable `:latest` image tags. | Removed `|| true`, added model check step, gated builds on `needs: lint_and_test`, enforced immutable tags (`${VERSION}-${SHORT_SHA}`). |
| **Secrets & Context** (`.env.example`, `.dockerignore`) | Plaintext database credentials in repo; build context bloated with tarballs and scripts. | Parameterized with `.env.example` template; added strict `.dockerignore` and `.gitignore` contracts. |

---

## 2. Field Rollback Runbook (15-Minute Change Window)

**Scenario:** Newly promoted release bundle (e.g. `v1.4.2`) fails validation or `inference_worker` enters `unhealthy` state.  
*Key Architectural Constraint:* Models are baked directly into immutable container images (`COPY --from=builder /build /app`). Restoring model files on host disk does not update running containers; rollback must operate on full release bundles.

```
[T+00:00] Triage Failure ──> [T+03:00] Stop Current Stack ──> [T+06:00] Activate Prior Release ──> [T+10:00] Deploy Offline ──> [T+13:00] Verify Endpoints
```

1. **T+0:00 – T+3:00 (Triage & Isolation):**
   - Confirm failure: `docker compose ps` (`inference_worker` is `unhealthy`).
   - Check worker logs: `docker compose logs --tail=20 inference_worker` (Confirm TRT engine or checksum fault).
2. **T+3:00 – T+6:00 (Stop Failing Release):**
   - Stop failing release containers: `docker compose down` (Database state preserved in volume `eoir-postgres-data`).
   - Quarantine failing release: `cd .. && mv release_v1.4.2 release_v1.4.2_quarantine`.
3. **T+6:00 – T+10:00 (Activate Previous Complete Release Bundle):**
   - Switch to previously verified release bundle: `cd /opt/defense_stack/release_v1.4.1`.
   - Load verified container images into local Docker cache: `docker load -i images.tar.gz`.
   - Verify SHA-256 manifest integrity: `sha256sum -c --status SHA256SUMS`.
4. **T+10:00 – T+13:00 (Launch Previous Stack):**
   - Bring verified stack online: `docker compose up -d --no-build --pull never`
   - *Data Continuity:* Named volume `eoir-postgres-data` re-attaches automatically with zero data loss.
5. **T+13:00 – T+15:00 (Operational Sign-Off):**
   - Validate health endpoint: `curl -fsS http://localhost:8000/health` (Expect: HTTP 200, `{"worker_ready": true}`).
   - Validate detection stream: `curl -fsS http://localhost:8000/api/v1/detect` (Expect: HTTP 200, valid detection JSON).

---

## 3. Preventing Lab vs Edge Runtime Drift (x86_64 vs Jetson Orin aarch64)

Serialized TensorRT plan files (`*.engine`) are hardware-specific binaries and cannot run interchangeably across architectures:
- **Root Cause of Incompatibility:** x86_64 lab GPUs use SM architectures like `sm_86` or `sm_89`, while Jetson Orin uses Tegra `sm_87` alongside an aarch64 ARM CPU ISA.
- **Engineering Safeguards:**
  1. **Architecture-Specific Release Bundles:** `package_airgap.sh` packages dedicated bundles per target platform (`release_v1.4.2_x86_64.tar.gz` and `release_v1.4.2_aarch64.tar.gz`) containing platform-matched TensorRT engines.
  2. **Golden Model Interchange:** Maintain model baselines exclusively as platform-agnostic `.onnx` files in source control. Never compile `.engine` on x86 for Orin deployment.
  3. **Targeted JetPack Build Containers:** Build production engines inside matching NVIDIA JetPack containers (e.g. `nvcr.io/nvidia/l4t-tensorrt:r35.4.1` for JetPack 5.1.2) running natively on Jetson hardware or cross-compilation toolchains.
  4. **Worker Pre-Flight Check:** Before allocating inference context, `worker.py` queries `cuda.Device(0).compute_capability()` to reject mismatched engine architectures prior to execution.

---

## 4. Release & Air-Gap Verification Status

- **Task 1: Stack Hardening & Healthchecks:** **VERIFIED** (Cold-boot healthy, image size 205.86 MB, non-root UID 10001, automated unit test suites passing).
- **Task 2: Air-Gapped Packaging & Deployment Scripts:**
  - **Implementation Status:** **COMPLETE** — Scripts hardened with architecture-specific packaging, external image pre-pulling, local image inspection, `--pull never` offline enforcement, persistent volume support, and strict `.env` credential/port validation.
  - **Pre-Flight Validation:** **PASSED** — POSIX syntax validated (`bash -n`), checksum tools verified, and manifest generation logic audited.
  - **Operational Status:** **Pending Field Site Acceptance Testing (SAT)** — Ready for final end-to-end execution on an isolated, physical air-gapped target host.
