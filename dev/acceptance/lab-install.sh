#!/usr/bin/env bash
# Lab-only installer hook for drill.sh (TF_TARGET_READY_HOOK).
#
# Writes the target-side registration into the dev lab's `target` container the way an operator
# would over ssh on real hardware: root-owned, mode 0600, content verbatim from the file drill.sh
# emitted. The container exec is a lab convenience, not part of the product path.
set -euo pipefail
name="$1" service_id="$2" registration="$3" target_path="$4"

cd "$(dirname "$0")/../acme-lab"
docker compose ps -q target | grep -q . || { echo "lab target container is not running"; exit 1; }
docker compose exec -T target sh -c \
    "umask 077; mkdir -p /etc/trustforge/services; cat > '$target_path'" < "$registration"
docker compose exec -T target sh -c \
    "chown root:root '$target_path'; ls -l '$target_path'; head -c 80 '$target_path'"
echo "installed $target_path for $name ($service_id)"
