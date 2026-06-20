#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== ArbitraIQ container entrypoint wrapper ==="

start_container_sshd_if_requested() {
  if [[ "${ENABLE_CONTAINER_SSH:-true}" != "true" ]]; then
    echo "Container SSH disabled."
    return
  fi

  if ! command -v /usr/sbin/sshd >/dev/null 2>&1; then
    echo "WARNING: ENABLE_CONTAINER_SSH=true but /usr/sbin/sshd is not available."
    return
  fi

  echo "Preparing container SSH..."

  mkdir -p /run/sshd /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  if [[ -n "${EXTRA_SSH_PUBLIC_KEY:-}" ]]; then
    if ! grep -qxF "${EXTRA_SSH_PUBLIC_KEY}" /root/.ssh/authorized_keys; then
      echo "${EXTRA_SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
      echo "Installed EXTRA_SSH_PUBLIC_KEY for root login."
    else
      echo "EXTRA_SSH_PUBLIC_KEY already installed."
    fi
  else
    echo "No EXTRA_SSH_PUBLIC_KEY provided. Container SSH may still work if the provider injected keys."
  fi

  if [[ ! -s /root/.ssh/authorized_keys ]]; then
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
