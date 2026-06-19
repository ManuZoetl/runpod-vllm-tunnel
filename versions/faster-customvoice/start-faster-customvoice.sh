#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Jarvis Faster CustomVoice Stack ==="

# Fixed per-image runtime. Do not pass model/mode through RunPod env.
ASR_MODEL="Qwen/Qwen3-ASR-0.6B"
ASR_SERVED_MODEL_NAME="qwen3-asr"
TTS_MODEL="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
TTS_SERVED_MODEL_NAME="qwen3-tts-faster-customvoice"

: "${VLLM_API_KEY:?VLLM_API_KEY missing}"
: "${RUNPOD_TUNNEL_PRIVATE_KEY_B64:?RUNPOD_TUNNEL_PRIVATE_KEY_B64 missing}"
: "${VPS_HOST:?VPS_HOST missing}"
: "${VPS_USER:?VPS_USER missing}"

VPS_PORT="${VPS_PORT:-22}"
ASR_PORT="8000"
TTS_PORT="8091"
VPS_ASR_REMOTE_PORT="${VPS_ASR_REMOTE_PORT:-18081}"
VPS_TTS_REMOTE_PORT="${VPS_TTS_REMOTE_PORT:-18082}"
JARVIS_TTS_DEFAULT_SPEAKER="${JARVIS_TTS_DEFAULT_SPEAKER:-aiden}"
JARVIS_TTS_DEFAULT_LANGUAGE="${JARVIS_TTS_DEFAULT_LANGUAGE:-German}"
ASR_GPU_MEMORY_UTILIZATION="${ASR_GPU_MEMORY_UTILIZATION:-0.22}"

echo "== Fixed runtime =="
echo "ASR_MODEL=${ASR_MODEL}"
echo "ASR_SERVED_MODEL_NAME=${ASR_SERVED_MODEL_NAME}"
echo "TTS_MODEL=${TTS_MODEL}"
echo "TTS_SERVED_MODEL_NAME=${TTS_SERVED_MODEL_NAME}"
echo "TTS_DEFAULT_SPEAKER=${JARVIS_TTS_DEFAULT_SPEAKER}"
echo "TTS_DEFAULT_LANGUAGE=${JARVIS_TTS_DEFAULT_LANGUAGE}"

echo "== Prepare SSH key =="
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "$RUNPOD_TUNNEL_PRIVATE_KEY_B64" | base64 -d > /root/.ssh/runpod_tunnel_key
chmod 600 /root/.ssh/runpod_tunnel_key

echo "== Add VPS host key =="
ssh-keyscan -p "$VPS_PORT" -H "$VPS_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true

echo "== Stop old voice processes =="
pkill -f "vllm serve" 2>/dev/null || true
pkill -f "faster_customvoice_server.py" 2>/dev/null || true
sleep 2

ASR_PID=""
TTS_PID=""
TUNNEL_PID=""

cleanup() {
  echo "Stopping Jarvis faster customvoice stack..."
  if [[ -n "${TUNNEL_PID}" ]]; then kill "${TUNNEL_PID}" 2>/dev/null || true; fi
  if [[ -n "${TTS_PID}" ]]; then kill "${TTS_PID}" 2>/dev/null || true; fi
  if [[ -n "${ASR_PID}" ]]; then kill "${ASR_PID}" 2>/dev/null || true; fi
}
trap cleanup SIGTERM SIGINT EXIT

echo "== Start ASR on ${ASR_PORT} =="
vllm serve "${ASR_MODEL}" \
  --served-model-name "${ASR_SERVED_MODEL_NAME}" \
  --host 127.0.0.1 \
  --port "${ASR_PORT}" \
  --api-key "${VLLM_API_KEY}" \
  --max-model-len 1024 \
  --gpu-memory-utilization "${ASR_GPU_MEMORY_UTILIZATION}" \
  --max-num-seqs 1 \
  --trust-remote-code \
  > /tmp/jarvis-asr.log 2>&1 &
ASR_PID=$!

echo "== Wait for ASR =="
until curl -fsS "http://127.0.0.1:${ASR_PORT}/health" >/dev/null 2>&1; do
  if ! kill -0 "${ASR_PID}" 2>/dev/null; then
    echo "ASR exited before becoming healthy. Last log lines:"
    tail -120 /tmp/jarvis-asr.log || true
    exit 1
  fi
  sleep 3
done
echo "ASR ready"

echo "== Start Faster Qwen3-TTS CustomVoice on ${TTS_PORT} =="
python3 /opt/jarvis/faster_customvoice_server.py \
  --host 127.0.0.1 \
  --port "${TTS_PORT}" \
  --model "${TTS_MODEL}" \
  --served-model-name "${TTS_SERVED_MODEL_NAME}" \
  --speaker "${JARVIS_TTS_DEFAULT_SPEAKER}" \
  --language "${JARVIS_TTS_DEFAULT_LANGUAGE}" \
  > /tmp/jarvis-tts.log 2>&1 &
TTS_PID=$!

echo "== Wait for TTS =="
until curl -fsS "http://127.0.0.1:${TTS_PORT}/health" >/dev/null 2>&1; do
  if ! kill -0 "${TTS_PID}" 2>/dev/null; then
    echo "TTS exited before becoming healthy. Last log lines:"
    tail -160 /tmp/jarvis-tts.log || true
    exit 1
  fi
  sleep 3
done
echo "TTS ready"

echo "== Status =="
echo "-- ASR models --"
curl -fsS "http://127.0.0.1:${ASR_PORT}/v1/models" -H "Authorization: Bearer ${VLLM_API_KEY}" || true
echo
echo "-- TTS models --"
curl -fsS "http://127.0.0.1:${TTS_PORT}/v1/models" || true
echo
echo "-- TTS voices --"
curl -fsS "http://127.0.0.1:${TTS_PORT}/v1/audio/voices" || true
echo
echo "-- GPU --"
nvidia-smi || true

echo "Voice stack ready."
echo "ASR internal: http://127.0.0.1:${ASR_PORT}/v1/audio/transcriptions"
echo "TTS internal: http://127.0.0.1:${TTS_PORT}/v1/audio/speech"

echo "== Start reverse SSH tunnels =="
echo "VPS 127.0.0.1:${VPS_ASR_REMOTE_PORT} -> RunPod 127.0.0.1:${ASR_PORT}"
echo "VPS 127.0.0.1:${VPS_TTS_REMOTE_PORT} -> RunPod 127.0.0.1:${TTS_PORT}"

while true; do
  ssh -i /root/.ssh/runpod_tunnel_key \
    -N -T \
    -p "${VPS_PORT}" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "127.0.0.1:${VPS_ASR_REMOTE_PORT}:127.0.0.1:${ASR_PORT}" \
    -R "127.0.0.1:${VPS_TTS_REMOTE_PORT}:127.0.0.1:${TTS_PORT}" \
    "${VPS_USER}@${VPS_HOST}" &

  TUNNEL_PID=$!
  echo "Tunnel PID: ${TUNNEL_PID}"

  wait "${TUNNEL_PID}" || true
  echo "Tunnel disconnected. Reconnecting in 5 seconds..."

  if ! kill -0 "${ASR_PID}" 2>/dev/null; then
    echo "ASR exited. Last log lines:"
    tail -120 /tmp/jarvis-asr.log || true
    exit 1
  fi
  if ! kill -0 "${TTS_PID}" 2>/dev/null; then
    echo "TTS exited. Last log lines:"
    tail -160 /tmp/jarvis-tts.log || true
    exit 1
  fi

  sleep 5
done
