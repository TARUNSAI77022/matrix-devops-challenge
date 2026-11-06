from http.server import BaseHTTPRequestHandler, HTTPServer
import hashlib
import json
import os
import time

ENGINE_PATH = os.environ.get("ENGINE_PATH", "/app/models/eo_detector_fp16.engine")
MANIFEST_PATH = os.environ.get("MANIFEST_PATH", "/app/models/manifest.json")
CACHE_DIR = os.environ.get("TRT_CACHE_DIR", "/app/models/.trt_cache")
PORT = int(os.environ.get("WORKER_PORT", "9000"))
WARMUP_SECONDS = float(os.environ.get("ENGINE_WARMUP_SEC", "2.0"))


def verify_engine():
    if not os.path.exists(ENGINE_PATH) or not os.path.exists(MANIFEST_PATH):
        return False, "missing_files", ""
    with open(MANIFEST_PATH, "r", encoding="utf-8") as mf:
        manifest = json.load(mf)
    expected = manifest.get("sha256", "")
    with open(ENGINE_PATH, "rb") as ef:
        actual = hashlib.sha256(ef.read()).hexdigest()
    if actual != expected:
        return False, expected, actual
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        lock_file = os.path.join(CACHE_DIR, "fp16_execution_context.lock")
        with open(lock_file, "w", encoding="utf-8") as lf:
            lf.write(actual)
    except OSError as exc:
        print(f"[inference_worker] ERROR: cannot write TRT execution cache in {CACHE_DIR}: {exc}", flush=True)
        return False, expected, actual
    return True, expected, actual


class WorkerHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        valid, expected, actual = verify_engine()
        if self.path == "/status":
            code = 200 if valid else 500
            body = json.dumps({
                "service": "inference_worker",
                "engine_loaded": os.path.exists(ENGINE_PATH),
                "checksum_valid": valid,
                "expected_sha256": expected,
                "actual_sha256": actual,
            }).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    time.sleep(WARMUP_SECONDS)
    ok, exp, act = verify_engine()
    print(f"[inference_worker] engine checksum valid={ok} (expected={exp[:12]}..., actual={act[:12]}...)", flush=True)
    HTTPServer(("0.0.0.0", PORT), WorkerHandler).serve_forever()
