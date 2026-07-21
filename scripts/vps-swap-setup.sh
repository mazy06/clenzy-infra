#!/bin/bash
# ===========================================
# Baitly — Setup swap VPS (a lancer UNE FOIS en root)
# ===========================================
# Audit perf 2026-07-21 : le VPS (7.6GB RAM, ~71% utilises par les JVM)
# tournait sans aucun swap — en cas de pic memoire, l'OOM killer peut tuer
# postgres ou une JVM. Ce script cree un swapfile de 4GB en filet de
# securite, avec vm.swappiness=10 (le swap ne sert qu'en derniere extremite,
# pas de swapping proactif qui degraderait les perfs).
#
# Usage : ssh root@<vps> 'bash -s' < scripts/vps-swap-setup.sh
# Idempotent : ne fait rien si /swapfile existe deja.

set -euo pipefail

if swapon --show | grep -q '/swapfile'; then
  echo "✅ Swap deja actif :"
  swapon --show
  exit 0
fi

if [ ! -f /swapfile ]; then
  echo "==> Creation du swapfile 4G..."
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
fi

echo "==> Activation..."
swapon /swapfile

if ! grep -q '^/swapfile' /etc/fstab; then
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  echo "==> Entree fstab ajoutee (persistant au reboot)."
fi

echo "==> vm.swappiness=10..."
sysctl vm.swappiness=10
printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-baitly-swap.conf

echo "✅ Swap configure :"
free -h
