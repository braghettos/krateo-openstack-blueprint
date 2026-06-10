# identity-derive-poc — Phase 1+3 proof of concept

Proves the kolla-ansible "few inputs → full config" thesis on the openstack-helm stack,
**offline, with no cluster**. Scope: the identity tier (keystone + its mariadb / memcached /
rabbitmq endpoints).

## What it shows

1. **Derivation (Phase 1).** A small `global:` block (the `globals.yml` analog) drives
   `osh-derive.*` helpers that generate the full openstack-helm `endpoints:` tree keystone
   would otherwise hand-write. Measured amplification: **11 operator input leaf-values →
   45 generated endpoint leaf-values (4.1×) for one service**. Nine of the eleven inputs
   (`namespace`, `clusterDomain`, `region`, `protocol`, `passwords`) are shared, so each
   additional service costs ~1 input (its port) to generate ~45 keys.

2. **Generate-once secrets (Phase 3).** `secret-passwords.yaml` mirrors `kolla-genpwd`:
   in `generate` mode it `lookup`s the existing Secret and reuses every present key,
   generating only missing ones; `helm.sh/resource-policy: keep` makes the Secret survive
   uninstall, so credentials are created once and reused forever.

3. **Determinism (the reconcile-churn guard).** The `memcache_secret_key` and
   `rabbitmq replicas: 1` fixes are baked into the derivation so they cannot be
   hand-reintroduced. `tools/assert-deterministic.sh` renders twice and asserts
   byte-identical output.

## Run

```sh
helm lint distribution/identity-derive-poc
helm template poc distribution/identity-derive-poc            # generate mode (random secrets)
tools/assert-deterministic.sh                                 # provided/CI mode, byte-stable
helm template poc distribution/identity-derive-poc \
  --show-only templates/derived-endpoints.yaml                # inspect the generated tree
```

## The one honest caveat

`lookup` is empty during `helm template`/dry-run, so **generate mode is intentionally
non-deterministic at render time** (it stabilises at apply-time via `resource-policy: keep`).
CI determinism therefore runs in `provided` mode (`values-ci.yaml`), where passwords come
from `global.passwords.provided`. This is the documented price of zero-config generation.

## Phase 2 — the real chart consumes the derived values (proven, non-invasive)

`osh-derive.keystone.overlay` emits the *structural* endpoint keys derived from `global`;
helm's deep-merge (`-f`) lays them over the **unmodified** vendored `blueprints/keystone/chart`,
so the chart is never edited (align-upstream rule preserved):

```sh
# render the derived overlay from global, then drive the real chart with it
helm template poc distribution/identity-derive-poc \
  --show-only templates/keystone-osh-overlay.yaml \
  | python3 -c "import sys,yaml;print(yaml.safe_load(sys.stdin)['data']['values.yaml'])" \
  > /tmp/ks-endpoints-overlay.yaml
helm template ks blueprints/keystone/chart -f /tmp/ks-endpoints-overlay.yaml   # chart version must be set
```

Result: a single `global.namespace` input propagates through the entire chart —
`endpt=http://keystone-api.openstack.svc.cluster.local:5000/v3` and every
kubernetes-entrypoint dependency list (`openstack:memcached,openstack:mariadb`) follow it;
changing `global.endpoints.identity.port` to 5001 moves the rendered port. The full
3312-line real-chart render is **byte-identical across two passes** (determinism holds on
the vendored chart, confirming the `memcache_secret_key`/rabbitmq pins).

In production this overlay is produced once per service by the umbrella/Krateo layer and
fed to each component Composition — the documented "generate values, then deploy" two-pass
model (Helm cannot compute-then-inject across sibling subcharts in one pass).

## Not yet done (later phases)

The stateful-datastore bootstrap, lifecycle-DAG ordering, HA/clustering, TLS/cert-manager
and ironic boot-infra deltas are Phases 5–9 in
`docs/kolla-ansible-audit-and-helm-plan.md`. Phase 3's generate-once Secret still needs the
auth passwords wired into the overlay (currently the chart keeps its default `password`
literals); that is the next increment.
