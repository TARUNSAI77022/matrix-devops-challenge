# ==============================================================================
# Stage 1: Build & Preparation Stage
# ==============================================================================
FROM python:3.11-slim AS builder

WORKDIR /build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Copy source repository into builder
COPY . /build

# Pre-configure TRT cache directory and permissions
RUN mkdir -p /build/models/.trt_cache && \
    chmod 0755 /build /build/models && \
    chmod -R 0755 /build/models/.trt_cache

# ==============================================================================
# Stage 2: Hardened Runtime Stage (< 220 MB)
# ==============================================================================
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Install minimal healthcheck utility and clean apt cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Create dedicated non-privileged system user and group (UID/GID 10001)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -d /app -s /sbin/nologin -M appuser

# Copy prepared payload from builder stage with non-root ownership
COPY --from=builder --chown=appuser:appgroup /build /app

# Ensure non-root ownership and directory execution rights
RUN chown -R appuser:appgroup /app && \
    chmod 0755 /app && \
    chmod -R 0755 /app/models

# Run container as non-root user
USER 10001:10001

EXPOSE 8000 9000

CMD ["python", "vision_api/app.py"]
