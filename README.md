# DevOps Engineer Challenge — EO/IR Stack Packaging, Hardening & Air-Gapped Release

**Timebox:** 48 hours  
**Runs on:** Any laptop with Docker & Docker Compose (Windows / macOS / Linux, ~400 MB RAM, no GPU required).

---

## Scenario

You are preparing a field release of a two-service perception stack (`vision_api` + `inference_worker` + `postgres`) for an on-site defence deployment. The previous engineer left a broken repository that appears to start under `docker compose up`, and `inference_worker` even reports `healthy` in `docker ps` — yet calling `GET http://localhost:8000/api/v1/detect` returns `503 Service Unavailable`.

Audit the repository end-to-end (container build, runtime permissions, service networking, startup ordering, artifact integrity, secret management, and CI/CD pipeline) and resolve every operational, security, and release-gating flaw.

---

## Tasks

### Task 1 — Diagnose, Harden & Fix the Stack
1. Make `docker compose up -d --build` bring up the full stack cleanly from a cold start so that:
   - `GET http://localhost:8000/health` returns HTTP `200` with `{"status": "healthy", "worker_ready": true}`.
   - `GET http://localhost:8000/api/v1/detect` returns HTTP `200`.
   - If `eo_detector_fp16.engine` is corrupted or `inference_worker` crashes, Docker's healthcheck **must actually mark `inference_worker` as `unhealthy`** within 15 seconds.
2. Refactor the container build (slim/multi-stage base, `.dockerignore`, non-root runtime user) so the final image is **under 220 MB** and runs without root privileges while still passing all runtime checks.
3. Remove hardcoded secrets from version-controlled orchestration files into an `.env.example` template + uncommitted `.env` contract.
4. Harden the CI workflow so failing tests or unverified model artifacts block image build and promotion, and image tags are immutable (never bare `:latest`).

### Task 2 — Air-Gapped Bundle & Rollback Runbook
1. Write two POSIX/Bash scripts (`package_airgap.sh` and `deploy_airgap.sh`) that:
   - Export the built container images, compose configuration, and `models/` into a single versioned release bundle (`release_v1.4.2.tar.gz`) with a `SHA256SUMS` manifest covering every file.
   - Verify `SHA256SUMS` on the target side before loading images and starting the stack with zero internet access.
2. Write a 1-page `RUNBOOK.md` covering:
   - Every flaw you identified and fixed in Task 1 (file, line, root cause, and fix).
   - Step-by-step **field rollback** if a newly promoted `eo_detector_fp16.engine` causes `inference_worker` to fail on site during a 15-minute change window.
   - How you prevent CUDA / TensorRT runtime drift between an `x86_64` lab GPU server and an `aarch64` NVIDIA Jetson Orin edge node.

---

## Submission

Reply with a link (OneDrive / Google Drive / private GitHub repo) containing:
1. Your fixed repository, air-gap packaging/deployment scripts, and `RUNBOOK.md`.
2. Be prepared to **demo the stack live** during your review session: `docker images`, `docker compose up -d`, `curl http://localhost:8000/health` and `curl http://localhost:8000/api/v1/detect`, the `docker ps` transition to `unhealthy` when `eo_detector_fp16.engine` is corrupted or the worker is stopped — plus a verbal walkthrough of every flaw you found and fixed.
