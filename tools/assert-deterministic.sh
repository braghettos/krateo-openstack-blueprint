#!/usr/bin/env bash
# Determinism gate: render a chart twice and assert byte-identical output.
# This is the reconcile-churn guard - any randAlphaNum/uuid/now reaching a rendered
# manifest makes the two renders differ and fails the gate.
#
# Usage: tools/assert-deterministic.sh [chart-dir] [values-overlay]
set -euo pipefail

CHART="${1:-distribution/identity-derive-poc}"
OVERLAY="${2:-$CHART/values-ci.yaml}"

a="$(mktemp)"; b="$(mktemp)"
trap 'rm -f "$a" "$b"' EXIT

helm template poc "$CHART" -f "$OVERLAY" > "$a"
helm template poc "$CHART" -f "$OVERLAY" > "$b"

if diff -u "$a" "$b" >/dev/null; then
  echo "DETERMINISTIC: two renders of $CHART are byte-identical ($(wc -l < "$a" | tr -d ' ') lines)"
else
  echo "NON-DETERMINISTIC: renders of $CHART differ:" >&2
  diff -u "$a" "$b" | head -40 >&2
  exit 1
fi
