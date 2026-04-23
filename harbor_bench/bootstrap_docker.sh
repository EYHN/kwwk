#!/usr/bin/env bash
# One-shot Docker bring-up for restricted hosts (e.g. cloud sandboxes) where default
# bridge+iptables+overlay is blocked. Uses vfs storage and no userland NAT.
# Run with: sudo ./harbor_bench/bootstrap_docker.sh
set -euo pipefail

update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

install -d /etc/docker
cat >/etc/docker/daemon.json <<'JSON'
{
  "storage-driver": "vfs",
  "iptables": false,
  "ip-forward": false,
  "bridge": "none"
}
JSON

# Clear stale run state; keeps images under /var/lib/docker when not deleting it.
# Comment out the next two lines if you need to preserve local images.
rm -rf /var/run/docker
mkdir -p /var/lib/docker

pkill -9 dockerd 2>/dev/null || true
sleep 1
nohup dockerd >>/var/log/dockerd-harbor.log 2>&1 &
sleep 5

# Allow the primary login user to use docker without newgrp
MAIN_USER="${SUDO_USER:-${USER:-ubuntu}}"
if id -u "$MAIN_USER" &>/dev/null; then
  usermod -aG docker "$MAIN_USER" || true
  chmod 666 /var/run/docker.sock 2>/dev/null || true
fi

echo "docker info (first lines):"
docker info 2>&1 | head -12
echo "ok — run: docker run --rm hello-world"
