#!/usr/bin/env bash
#
# Pre-load every image the openstack-installer chart uses into a kind cluster as
# linux/amd64.
#
# Why this is needed: the OpenStack-Helm images are published amd64-only, and
# several are multi-arch manifest LISTS that contain only amd64. On an arm64 kind
# node (Apple Silicon) containerd refuses those at pull time ("no match for
# platform in manifest"). Pulling them explicitly as linux/amd64 on the host and
# `kind load`-ing them into the node sidesteps the platform check; the chart pulls
# with IfNotPresent so the pre-loaded image is used and then runs under Rosetta/
# qemu emulation.
#
# On a NATIVE amd64 Kubernetes cluster this script is unnecessary — the images
# pull normally. It exists purely to make local testing on Apple Silicon work.
#
# Usage: tools/kind-load-images.sh [kind-cluster-name]   (default: openstack)
set -euo pipefail

CLUSTER="${1:-openstack}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHART="${HERE}/chart"

# helm needs a valid version; stamp a throwaway one into a temp copy.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R "$CHART" "$TMP/chart"
sed -i.bak 's/CHART_VERSION/0.0.0-load/' "$TMP/chart/Chart.yaml"

echo ">> Rendering chart to collect image references..."
# Render with all optional components on, so every possible image is covered.
IMAGES="$(helm template load "$TMP/chart" \
            --set rabbitmq.enabled=true \
            --set glance.enabled=true \
            --set horizon.enabled=true 2>/dev/null \
          | grep -oE 'image: .*' \
          | sed -E 's/image:\s*"?([^"]+)"?/\1/' \
          | sort -u)"

echo ">> Images to pre-load:"
echo "$IMAGES" | sed 's/^/   /'

for img in $IMAGES; do
  echo ">> docker pull --platform=linux/amd64 $img"
  docker pull --platform=linux/amd64 "$img"
  echo ">> kind load docker-image $img --name $CLUSTER"
  kind load docker-image "$img" --name "$CLUSTER"
done

echo ">> Done. All chart images are present in kind cluster '$CLUSTER' as amd64."
