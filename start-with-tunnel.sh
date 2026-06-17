#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== ArbitraIQ RunPod vLLM Tunnel Starter ==="

: "${VLLM_API_KEY:?VLLM_API_KEY missing}"
: "${RUNPOD_TUNNEL_PRIVATE_KEY_B64:?RUNPOD_TUNNEL_PRIVATE_KEY_B64 missing}"
: "${VPS_HOST:?VPS_HOST missing}"
: "${VPS_USER:?VPS_USER missing}"

VPS_PORT="${VPS_PORT:-22}"
VPS_REMOTE_PORT="${VPS_REMOTE_PORT:-18080}"
VLLM_PORT="${VLLM_PORT:-8000}"

# RunPod may pass the whole start command as one string.
# This converts it into normal argv tokens while preserving quoted JSON args.
if [[ "$#" -eq 1 && "$1" == *"--model"* ]]; then
  echo "Detected single-string start command. Expanding arguments..."
  eval "set -- $1"
fi

echo "Preparing SSH key..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

echo "$RUNPOD_TUNNEL_PRIVATE_KEY_B64" | base64 -d > /root/.ssh/runpod_tunnel_key
chmod 600 /root/.ssh/runpod_tunnel_key

echo "Adding VPS host key..."
ssh-keyscan -p "$VPS_PORT" -H "$VPS_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true

echo "Starting vLLM on port ${VLLM_PORT}..."

HAS_API_KEY_ARG="false"
for arg in "$@"; do
  if [[ "$arg" == "--api-key" ]]; then
    HAS_API_KEY_ARG="true"
  fi
done

if [[ "$HAS_API_KEY_ARG" == "true" ]]; then
  echo "WARNING: --api-key was already provided in start command. Prefer VLLM_API_KEY env var instead."
  vllm serve "$@" &
else
  vllm serve "$@" --api-key "$VLLM_API_KEY" &
fi

VLLM_PID=$!

cleanup() {
  echo "Stopping..."
  kill "$VLLM_PID" 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT

echo "Waiting for vLLM health endpoint..."
until curl -fsS "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null 2>&1; do
  if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    echo "vLLM exited before becoming healthy."
    wait "$VLLM_PID"
    exit 1
  fi
  sleep 3
done

echo "vLLM is healthy."
echo "Starting reverse SSH tunnel:"
echo "VPS 127.0.0.1:${VPS_REMOTE_PORT} -> RunPod 127.0.0.1:${VLLM_PORT}"

while true; do
  ssh -i /root/.ssh/runpod_tunnel_key \
    -N -T \
    -p "$VPS_PORT" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "127.0.0.1:${VPS_REMOTE_PORT}:127.0.0.1:${VLLM_PORT}" \
    "${VPS_USER}@${VPS_HOST}" &

  TUNNEL_PID=$!
  echo "Tunnel PID: ${TUNNEL_PID}"

  wait "$TUNNEL_PID" || true
  echo "Tunnel disconnected. Reconnecting in 5 seconds..."

  if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    echo "vLLM exited. Stopping container."
    wait "$VLLM_PID"
    exit 1
  fi

  sleep 5
done
