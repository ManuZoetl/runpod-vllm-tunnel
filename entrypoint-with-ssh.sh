#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== ArbitraIQ Qwen3.6 container entrypoint ==="

install_ssh_public_key_line() {
  local key_line="${1:-}"

  # Trim leading/trailing whitespace around keys passed through env vars.
  key_line="${key_line#${key_line%%[![:space:]]*}}"
  key_line="${key_line%${key_line##*[![:space:]]}}"

  if [[ -z "$key_line" ]]; then
    return
  fi

  if ! grep -qxF "$key_line" /root/.ssh/authorized_keys; then
    echo "$key_line" >> /root/.ssh/authorized_keys
    echo "Installed SSH public key: ${key_line:0:48}..."
  fi
}

start_container_sshd_if_requested() {
  if [[ "${ENABLE_CONTAINER_SSH:-true}" != "true" ]]; then
    echo "Container SSH disabled."
    return
  fi

  if ! command -v /usr/sbin/sshd >/dev/null 2>&1; then
    echo "WARNING: ENABLE_CONTAINER_SSH=true but /usr/sbin/sshd is not available."
    return
  fi

  echo "== Prepare container SSH =="

  mkdir -p /run/sshd /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys

  # Vast can inject SSH keys here before Docker ENTRYPOINT starts.
  # Do not overwrite this file. Only add optional fallback keys.
  if [[ -n "${EXTRA_SSH_PUBLIC_KEY:-}" ]]; then
    install_ssh_public_key_line "$EXTRA_SSH_PUBLIC_KEY"
  fi

  if [[ -n "${EXTRA_SSH_PUBLIC_KEYS:-}" ]]; then
    IFS=';' read -ra SSH_KEYS <<< "$EXTRA_SSH_PUBLIC_KEYS"
    for key_line in "${SSH_KEYS[@]}"; do
      install_ssh_public_key_line "$key_line"
    done
  fi

  if [[ -s /root/.ssh/authorized_keys ]]; then
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
  fi
  chmod 600 /root/.ssh/authorized_keys

  echo "== Authorized SSH key fingerprints =="
  if [[ -s /root/.ssh/authorized_keys ]]; then
    ssh-keygen -lf /root/.ssh/authorized_keys || true
  else
    echo "WARNING: /root/.ssh/authorized_keys is empty. SSH login will fail unless keys are injected later."
  fi

  ssh-keygen -A >/dev/null 2>&1 || true

  sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
  sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true
  sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || true

  echo "Starting container sshd on port ${CONTAINER_SSH_PORT:-22}..."
  /usr/sbin/sshd -D -e -p "${CONTAINER_SSH_PORT:-22}" &
  echo "Container sshd PID: $!"
}

start_container_sshd_if_requested

exec /usr/local/bin/start-with-tunnel.sh "$@"
