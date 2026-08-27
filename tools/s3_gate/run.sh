#!/bin/sh
# S3 backend gate runner: starts a throwaway MinIO server, runs the
# `s3-integration` build step against it, and always tears the server down.
# Invoked by the mise task `s3-integration`, which puts the pinned MinIO
# binary on PATH. The server must run outside the test executable; MinIO
# started from inside a Zig test binary hangs on this host platform.

set -u

PORT=19080
ENDPOINT="127.0.0.1:$PORT"
DATA_DIR=".zig-cache/s3-gate"
PID_FILE=".zig-cache/s3-gate.pid"
LOG_FILE=".zig-cache/s3-gate.log"

export MINIO_ROOT_USER=tester
export MINIO_ROOT_PASSWORD=tester-secret-and-long-enough
export MINIO_BROWSER=off

TLS_PORT=19443
CERT_DIR="$(pwd)/.zig-cache/s3-gate-certs"
CERT_ABS="$CERT_DIR"
TLS_DATA_DIR=".zig-cache/s3-gate-tls"
TLS_PID_FILE=".zig-cache/s3-gate-tls.pid"
TLS_LOG_FILE=".zig-cache/s3-gate-tls.log"

# Not every CI image ships lsof; fall back to the pid file alone.
kill_port() {
    if command -v lsof > /dev/null 2>&1; then
        lsof -ti "tcp:$1" | xargs kill -9 2>/dev/null || true
    fi
}

cleanup() {
    if [ -f "$PID_FILE" ]; then
        kill -9 "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
    if [ -f "$TLS_PID_FILE" ]; then
        kill -9 "$(cat "$TLS_PID_FILE")" 2>/dev/null || true
    fi
    kill_port "$PORT"
    kill_port "$TLS_PORT"
    rm -rf "$DATA_DIR" "$PID_FILE" "$LOG_FILE" \
        "$TLS_DATA_DIR" "$TLS_PID_FILE" "$TLS_LOG_FILE"
}
trap cleanup EXIT INT TERM

# Clear any stale instance from an interrupted earlier run.
kill_port "$PORT"
rm -rf "$DATA_DIR"
mkdir -p .zig-cache

nohup minio server "$DATA_DIR" --address "$ENDPOINT" > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

ready=0
i=0
while [ "$i" -lt 60 ]; do
    if curl -sf "http://$ENDPOINT/minio/health/live" > /dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
    i=$((i + 1))
done
if [ "$ready" -ne 1 ]; then
    echo "minio did not become healthy; server log:" >&2
    cat "$LOG_FILE" >&2 || true
    exit 1
fi

# TLS lane: a second MinIO with a self-signed certificate. The client
# validates it through the CA file, exercising the https path end to end.
rm -rf "$CERT_DIR" "$TLS_DATA_DIR"
mkdir -p "$CERT_DIR/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -keyout "$CERT_DIR/certs/private.key" \
    -out "$CERT_DIR/certs/public.crt" > /dev/null 2>&1 || { echo "openssl cert generation failed" >&2; exit 1; }
cp "$CERT_DIR/certs/public.crt" "$CERT_DIR/ca.crt";

nohup minio server "$TLS_DATA_DIR" \
    --address "localhost:$TLS_PORT" \
    --certs-dir "$CERT_DIR/certs" > "$TLS_LOG_FILE" 2>&1 &
echo $! > "$TLS_PID_FILE"

tls_ready=0
i=0
while [ "$i" -lt 60 ]; do
    if curl -sf "https://localhost:$TLS_PORT/minio/health/live" \
        --cacert "$CERT_DIR/ca.crt" > /dev/null 2>&1; then
        tls_ready=1
        break
    fi
    sleep 0.5
    i=$((i + 1))
done
if [ "$tls_ready" -ne 1 ]; then
    echo "minio TLS did not become healthy; server log:" >&2
    cat "$TLS_LOG_FILE" >&2 || true
    exit 1
fi

zig build s3-integration -Doptimize=ReleaseSafe \
    -Dminio-ca="$CERT_DIR/ca.crt" -Dminio-tls-port="$TLS_PORT"
