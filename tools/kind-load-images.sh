#!/usr/bin/env bash
#
# Pre-load every image the OpenStack identity-plane blueprints use into a kind
# cluster as linux/amd64.
#
# Why: the OpenStack-Helm images are amd64-only, and several are multi-arch
# manifest LISTS that contain only amd64, which an arm64 kind node (Apple Silicon)
# refuses at pull time. Pulling them explicitly as linux/amd64 and `kind load`-ing
# them sidesteps the platform check; the charts pull with IfNotPresent so the
# pre-loaded image is used and runs under Rosetta/qemu emulation. On a native
# amd64 cluster (e.g. GKE) this script is unnecessary.
#
# Usage: tools/kind-load-images.sh [kind-cluster-name]   (default: openstack)
set -euo pipefail
CLUSTER="${1:-openstack}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Identity-plane blueprints are the ones that run on kind (compute needs KVM/OVS).
COMPONENTS="mariadb memcached keystone glance horizon"

collect() {
  for c in $COMPONENTS; do
    local d; d="$(mktemp -d)"; cp -R "$HERE/blueprints/$c/chart" "$d/chart"
    sed -i.bak 's/CHART_VERSION/0.0.0-load/' "$d/chart/Chart.yaml"
    helm template load "$d/chart" 2>/dev/null | grep -oE 'image: .*' | sed -E 's/image:\s*"?([^"]+)"?/\1/'
    rm -rf "$d"
  done | sort -u
}

IMAGES="$(collect)"
echo ">> Pre-loading $(echo "$IMAGES" | wc -l | tr -d ' ') images into kind cluster '$CLUSTER' as amd64:"
for img in $IMAGES; do
  echo "   $img"
  docker pull --platform=linux/amd64 "$img"
  kind load docker-image "$img" --name "$CLUSTER"
done
echo ">> Done."
