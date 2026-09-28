# syntax=docker/dockerfile:1
# Sentinel Eye for Linux hosts. Multi-arch: build with
#   docker buildx build --platform linux/amd64,linux/arm64 .
# The AI frame enhancer is not included (its dependencies stay commented out in requirements.txt).

# go2rtc is a single static binary per arch; fetch it on the build machine's own platform.
FROM --platform=$BUILDPLATFORM alpine:3.22 AS go2rtc
ARG TARGETARCH
ARG GO2RTC_VERSION=v1.9.14
RUN apk add --no-cache curl \
 && case "$TARGETARCH" in amd64|arm64) ;; \
      *) echo "go2rtc: unsupported TARGETARCH '$TARGETARCH' (amd64, arm64)" >&2; exit 1 ;; esac \
 && curl -fsSL -o /go2rtc \
      "https://github.com/AlexxIT/go2rtc/releases/download/${GO2RTC_VERSION}/go2rtc_linux_${TARGETARCH}" \
 && chmod 755 /go2rtc

FROM python:3.14-slim
# ffmpeg/ffprobe: hikrelay, thumbnails, exports, timebase; libx264 is the H.265->H.264 encoder off macOS.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid 1000 sentinel \
 && useradd --uid 1000 --gid 1000 --no-create-home --shell /usr/sbin/nologin sentinel \
 && mkdir /data && chown 1000:1000 /data

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
COPY web/ web/
COPY --from=go2rtc /go2rtc bin/go2rtc

ENV SENTINEL_DATA=/data \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
USER sentinel
EXPOSE 8007
# Fail fast with a fix-it message if anything in the bind-mounted data dir isn't readable and writable by
# us (usually root-owned: Docker created ./data itself, or data/ was copied with sudo), instead of
# crash-looping on a PermissionError. Access, not ownership: Docker Desktop's bind mounts report other
# owners yet allow writes. find's own "Permission denied" output counts as a finding too.
CMD bad=$(find /data \( ! -readable -o ! -writable \) -print -quit 2>&1); \
    if [ -n "$bad" ]; then \
      echo "sentinel-eye: ${bad} is not writable by UID $(id -u). On the host run: sudo chown -R 1000:1000 data" >&2; \
      exit 1; \
    fi; \
    exec uvicorn --app-dir app server:app --host "${SENTINEL_HOST:-0.0.0.0}" --port "${SENTINEL_PORT:-8007}"
