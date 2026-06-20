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
AUTO_TP="${AUTO_TP:-true}"
TP_OVERRIDE="${TP_OVERRIDE:-${VLLM_TP_SIZE:-}}"

# Default vLLM command used when the container is started without explicit args.
# Every default can be overridden with env vars, so Vast/RunPod templates do not
# need to create a separate on-start script just to pass the vLLM command.
VLLM_MODEL="${VLLM_MODEL:-${MODEL:-Qwen/Qwen3.6-35B-A3B-FP8}}"
VLLM_SERVED_MODEL_NAME="${VLLM_SERVED_MODEL_NAME:-qwen3p6}"
VLLM_HOST="${VLLM_HOST:-0.0.0.0}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-${MAX_MODEL_LEN:-131072}}"
VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-${GPU_MEMORY_UTILIZATION:-0.92}}"
VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-${MAX_NUM_SEQS:-1}}"
VLLM_MAX_NUM_BATCHED_TOKENS="${VLLM_MAX_NUM_BATCHED_TOKENS:-${MAX_NUM_BATCHED_TOKENS:-8192}}"
VLLM_KV_CACHE_DTYPE="${VLLM_KV_CACHE_DTYPE:-fp8}"
VLLM_REASONING_PARSER="${VLLM_REASONING_PARSER:-qwen3}"
VLLM_TOOL_CALL_PARSER="${VLLM_TOOL_CALL_PARSER:-qwen3_coder}"
VLLM_SAFETENSORS_LOAD_STRATEGY="${VLLM_SAFETENSORS_LOAD_STRATEGY:-prefetch}"
VLLM_GENERATION_CONFIG="${VLLM_GENERATION_CONFIG:-vllm}"
DEFAULT_LIMIT_MM_PER_PROMPT='{"image":3,"video":0}'
VLLM_LIMIT_MM_PER_PROMPT="${VLLM_LIMIT_MM_PER_PROMPT:-${LIMIT_MM_PER_PROMPT:-$DEFAULT_LIMIT_MM_PER_PROMPT}}"

VLLM_ENABLE_CHUNKED_PREFILL="${VLLM_ENABLE_CHUNKED_PREFILL:-true}"
VLLM_ENABLE_PREFIX_CACHING="${VLLM_ENABLE_PREFIX_CACHING:-true}"
VLLM_ENABLE_AUTO_TOOL_CHOICE="${VLLM_ENABLE_AUTO_TOOL_CHOICE:-true}"

has_arg() {
  local key="$1"
  shift

  for arg in "$@"; do
    if [[ "$arg" == "$key" || "$arg" == "$key="* ]]; then
      return 0
    fi
  done

  return 1
}

count_csv_devices() {
  python3 - "$1" <<'PY'
import sys

value = sys.argv[1].strip()
items = [item.strip() for item in value.split(",") if item.strip()]
print(len(items))
PY
}

detect_gpu_count() {
  if [[ -n "${CUDA_VISIBLE_DEVICES:-}" \
        && "${CUDA_VISIBLE_DEVICES}" != "all" \
        && "${CUDA_VISIBLE_DEVICES}" != "none" \
        && "${CUDA_VISIBLE_DEVICES}" != "void" ]]; then
    count_csv_devices "${CUDA_VISIBLE_DEVICES}"
    return
  fi

  if [[ -n "${NVIDIA_VISIBLE_DEVICES:-}" \
        && "${NVIDIA_VISIBLE_DEVICES}" != "all" \
        && "${NVIDIA_VISIBLE_DEVICES}" != "none" \
        && "${NVIDIA_VISIBLE_DEVICES}" != "void" ]]; then
    count_csv_devices "${NVIDIA_VISIBLE_DEVICES}"
    return
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index --format=csv,noheader | grep -c '^[0-9]' || true
    return
  fi

  python3 - <<'PY'
try:
    import torch
    print(torch.cuda.device_count())
except Exception:
    print(0)
PY
}

choose_tensor_parallel_size() {
  local gpu_count="$1"

  case "$gpu_count" in
    1) echo 1 ;;
    2) echo 2 ;;
    3) echo 2 ;;
    4) echo 4 ;;
    5|6|7) echo 4 ;;
    8) echo 8 ;;
    *) echo 8 ;;
  esac
}

# RunPod/Vast may pass the whole start command as one string.
# This converts it into normal argv tokens while preserving quoted JSON args.
if [[ "$#" -eq 1 && "$1" == *" "* ]]; then
  echo "Detected single-string start command. Expanding arguments..."
  eval "set -- $1"
fi

if [[ "$#" -eq 0 ]]; then
  echo "No explicit vLLM args provided. Building default Qwen3.6 command from environment."

  VLLM_ARGS=(
    "$VLLM_MODEL"
    --served-model-name "$VLLM_SERVED_MODEL_NAME"
    --host "$VLLM_HOST"
    --port "$VLLM_PORT"
    --max-model-len "$VLLM_MAX_MODEL_LEN"
    --gpu-memory-utilization "$VLLM_GPU_MEMORY_UTILIZATION"
    --max-num-seqs "$VLLM_MAX_NUM_SEQS"
    --max-num-batched-tokens "$VLLM_MAX_NUM_BATCHED_TOKENS"
    --kv-cache-dtype "$VLLM_KV_CACHE_DTYPE"
    --reasoning-parser "$VLLM_REASONING_PARSER"
    --tool-call-parser "$VLLM_TOOL_CALL_PARSER"
    --limit-mm-per-prompt "$VLLM_LIMIT_MM_PER_PROMPT"
    --safetensors-load-strategy "$VLLM_SAFETENSORS_LOAD_STRATEGY"
    --generation-config "$VLLM_GENERATION_CONFIG"
  )

  if [[ "$VLLM_ENABLE_CHUNKED_PREFILL" == "true" ]]; then
    VLLM_ARGS+=(--enable-chunked-prefill)
  fi

  if [[ "$VLLM_ENABLE_PREFIX_CACHING" == "true" ]]; then
    VLLM_ARGS+=(--enable-prefix-caching)
  fi

  if [[ "$VLLM_ENABLE_AUTO_TOOL_CHOICE" == "true" ]]; then
    VLLM_ARGS+=(--enable-auto-tool-choice)
  fi
else
  VLLM_ARGS=("$@")
fi

if [[ "${AUTO_TP}" == "true" ]]; then
  if has_arg "--tensor-parallel-size" "${VLLM_ARGS[@]}" || has_arg "--tp" "${VLLM_ARGS[@]}"; then
    echo "Tensor parallel size already provided in start command. Keeping user value."
  else
    GPU_COUNT="$(detect_gpu_count)"

    if [[ -z "${GPU_COUNT}" || "${GPU_COUNT}" -lt 1 ]]; then
      echo "ERROR: No GPU detected. Cannot choose tensor parallel size."
      exit 1
    fi

    if [[ -n "${TP_OVERRIDE}" ]]; then
      TP_SIZE="${TP_OVERRIDE}"
      echo "Using TP_OVERRIDE=${TP_SIZE}"
    else
      TP_SIZE="$(choose_tensor_parallel_size "${GPU_COUNT}")"
      echo "Detected GPU_COUNT=${GPU_COUNT}; using auto tensor_parallel_size=${TP_SIZE}"
    fi

    VLLM_ARGS+=(--tensor-parallel-size "${TP_SIZE}")
  fi
else
  echo "AUTO_TP=false; not modifying tensor parallel size."
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
for arg in "${VLLM_ARGS[@]}"; do
  if [[ "$arg" == "--api-key" || "$arg" == "--api-key="* ]]; then
    HAS_API_KEY_ARG="true"
  fi
done

if [[ "$HAS_API_KEY_ARG" == "true" ]]; then
  echo "WARNING: --api-key was already provided in start command. Prefer VLLM_API_KEY env var instead."
  vllm serve "${VLLM_ARGS[@]}" &
else
  vllm serve "${VLLM_ARGS[@]}" --api-key "$VLLM_API_KEY" &
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
