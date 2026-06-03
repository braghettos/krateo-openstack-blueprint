# Krateo Blueprint — OpenStack

A [Krateo](https://krateo.io) blueprint that installs an **OpenStack identity control
plane** on a Kubernetes cluster using the upstream
[OpenStack-Helm](https://opendev.org/openstack/openstack-helm) charts. Once the
`CompositionDefinition` is applied, **every `OpenstackInstaller` Composition you create
becomes one OpenStack installation**.

## How it works

OpenStack-Helm ships **one chart per service** (keystone, glance, horizon, …) — there is
no single umbrella and no "all-in-one" chart. So "one OpenStack install" is really an
ordered *set* of charts. This blueprint bundles them into one self-contained umbrella
chart, `openstack-installer`, so a single Composition maps to a single install:

1. **A self-contained umbrella chart.** `chart/charts/` vendors the OpenStack-Helm
   subcharts (`mariadb`, `memcached`, `keystone`, and the optional `rabbitmq`, `glance`,
   `horizon`), each with `helm-toolkit` vendored inside it. Nothing is pulled from the
   upstream chart repo at install time — the blueprint is fully pinned (OpenStack release
   **2025.1 "Epoxy"**, `ubuntu_jammy` images).
2. **A curated `values.schema.json`.** Krateo's `core-provider` builds the Composition CRD
   **only** from the chart's `chart/values.schema.json` (it never reads `values.yaml`). The
   subcharts' own schemas are huge and use constructs `crdgen` can't express, so this chart
   exposes a small, flat, curated schema (component toggles, replica counts, Horizon
   NodePort) and keeps the working wiring in `values.yaml`.
3. **A working default profile.** With an empty spec you get the **identity control plane**:
   `MariaDB + Memcached + Keystone`. Keystone issues Fernet tokens and owns the service
   catalog. RabbitMQ, Glance and Horizon are optional (off by default).

> **Why the name `openstack-installer` (not `openstack`)?** The Kind becomes
> `OpenstackInstaller`, and the suffix keeps the release-named scaffolding RBAC that Krateo's
> chart-inspector creates while enumerating the chart from colliding with the services' own
> resources.

## Scope — what "functional" means here

This blueprint delivers a **functional OpenStack *identity* plane**: Keystone +
its datastore + cache. That is what makes an OpenStack "real" — every other service
authenticates against Keystone and registers in its catalog. Verified end-to-end:
`openstack token issue`, `openstack endpoint list`, `openstack service list`,
`openstack catalog list` all work.

**Compute (nova), networking (neutron) and live VMs are intentionally out of scope.** They
require `/dev/kvm` nested virtualization and the Open vSwitch kernel datapath, which `kind`
(and Docker Desktop on Apple Silicon) cannot provide; the OpenStack-Helm images are also
amd64-only. Glance (Image) and Horizon (Dashboard) **are** included as optional, runnable
control-plane components. To run compute, target a native amd64 cluster with KVM and extend
the chart with the `nova`/`neutron`/`libvirt`/`openvswitch` subcharts.

## Prerequisites

- A Kubernetes cluster with a default `StorageClass` (kind ships `rancher.io/local-path`).
- Krateo `core-provider` installed (tested with `1.0.0`).
- **On Apple Silicon / arm64 hosts:** the OpenStack images are amd64-only and some are
  manifest *lists* that omit arm64, which an arm64 node's containerd refuses. Pre-load them
  as amd64 once per cluster (they then run under Rosetta/qemu emulation):

  ```sh
  tools/kind-load-images.sh openstack      # docker pull --platform amd64 + kind load
  ```

  On a native amd64 cluster this step is unnecessary.

## Configuration

The Composition `spec` mirrors the (curated) chart values. Full schema in
[`chart/values.schema.json`](chart/values.schema.json). Highlights:

| Value                              | Default | Description                                            |
| ---------------------------------- | ------- | ------------------------------------------------------ |
| `keystone.pod.replicas.api`        | `1`     | Keystone API replicas (use `1` on kind).               |
| `mariadb.pod.replicas.server`      | `1`     | MariaDB servers (`1` on kind; `3` for HA).             |
| `rabbitmq.enabled`                 | `false` | Deploy the message bus (leave off on emulated kind).   |
| `glance.enabled`                   | `false` | Deploy the Glance image service.                       |
| `horizon.enabled`                  | `false` | Deploy the Horizon dashboard.                          |
| `horizon.network.node_port.port`   | `31000` | NodePort to expose Horizon on.                         |

## How to install

### 1. Register the blueprint

```sh
kubectl create namespace openstack-system
kubectl apply -f compositiondefinition.yaml
```

This publishes an `OpenstackInstaller` Composition type (`composition.krateo.io/v0-1-0`,
plural `openstackinstallers`). `compositiondefinition.yaml` pulls the chart from
`oci://ghcr.io/braghettos/charts/openstack-installer` (make that GHCR package public, or set
the `credentials` block).

### 2a. Create a Composition

Each Composition is one OpenStack install; give it its own namespace.

```sh
kubectl create namespace openstack
kubectl apply -f examples/composition.yaml
```

```yaml
apiVersion: composition.krateo.io/v0-1-0
kind: OpenstackInstaller
metadata:
  name: openstack
  namespace: openstack
spec:
  keystone:
    pod:
      replicas:
        api: 1
  # glance:  { enabled: true }
  # horizon: { enabled: true, network: { node_port: { port: 31000 } } }
```

### 2b. Or use the Krateo Composable Portal

```sh
kubectl apply -f customform.yaml
```

## The dashboard (Horizon)

With `horizon.enabled=true`, the OpenStack web dashboard is exposed on a NodePort. Logged in as
`admin` / `password` (domain `Default`), the Identity panels are fully populated by Keystone:

| Login | Identity → Projects (logged in as admin) |
| ----- | ---------------------------------------- |
| ![Horizon login](docs/horizon-login.png) | ![Horizon dashboard](docs/horizon-dashboard.png) |

(The default *Compute* landing panel reports "not authorized" because Nova is not part of this
identity-plane blueprint — see scope above. The Identity panels, backed by Keystone, work fully.)

## Accessing OpenStack

Keystone's public/admin endpoints are registered behind an Ingress host; from inside the
cluster use the **internal** interface (`keystone-api:5000`). Default admin credentials are
`admin` / `password` (project `admin`, domain `Default`, region `RegionOne`):

```sh
kubectl -n openstack run osclient --rm -it --restart=Never \
  --image=quay.io/airshipit/openstack-client:2025.1-ubuntu_jammy \
  --env OS_AUTH_URL=http://keystone-api.openstack.svc.cluster.local:5000/v3 \
  --env OS_USERNAME=admin --env OS_PASSWORD=password --env OS_PROJECT_NAME=admin \
  --env OS_USER_DOMAIN_NAME=Default --env OS_PROJECT_DOMAIN_NAME=Default \
  --env OS_IDENTITY_API_VERSION=3 --env OS_REGION_NAME=RegionOne --env OS_INTERFACE=internal \
  --command -- openstack token issue
```

A token in the output means OpenStack identity is functional. When `horizon.enabled=true`,
the dashboard is on the configured NodePort (e.g. `http://localhost:31000` with kind
`extraPortMappings`).

See [`quickstart.md`](quickstart.md) for the full end-to-end test on kind.

## Publishing (CI)

`.github/workflows/release-tag.yaml` builds the vendored dependencies, packages the chart and
pushes it to GHCR as an OCI Helm artifact on every semver tag
(`git tag 0.1.0 && git push origin 0.1.0` →
`oci://ghcr.io/braghettos/charts/openstack-installer:0.1.0`). `.github/workflows/lint.yaml`
runs `helm lint` + `helm template` (default and all-components profiles) on every PR.

## Notes / troubleshooting

- **Jobs are plain resources, not Helm hooks.** OpenStack-Helm ships its db/fernet/credential/
  bootstrap jobs as Helm hooks with `hook-delete-policy: before-hook-creation`. Krateo's
  composition-dynamic-controller runs under a least-privilege ServiceAccount that cannot
  `delete` Jobs, so the hooks fail. This blueprint strips the hook annotations so the jobs are
  ordinary, idempotent resources (OpenStack-Helm already orders them with
  `kubernetes-entrypoint` dep-checks; `release_uuid` is left empty so specs are stable across
  reconciles).
- **chart-inspector caches by chart version.** If you re-publish a *different* chart under the
  *same* version, restart the analyzers so the CDC RBAC is regenerated:
  `kubectl rollout restart deploy/core-provider deploy/core-provider-chart-inspector -n krateo-system`.
  A fresh `core-provider` install does not need this.

## Verified

End-to-end on a kind cluster (arm64 node, amd64 images under Rosetta/qemu emulation):

- `helm lint` / `helm template` (default and all-components) / `helm package`.
- The umbrella installs as a single release (`STATUS: deployed`); `MariaDB`, `Memcached` and
  `keystone-api` reach `Running`, and the Keystone bootstrap/db/fernet/credential jobs all
  `Completed`.
- **The full Krateo flow:** `CompositionDefinition` reconciles to `Ready=True`/`Synced=True` and
  generates the `OpenstackInstaller` CRD (`composition.krateo.io/v0-1-0`) with the curated spec
  schema; an `OpenstackInstaller` Composition reconciles to `Ready=True`/`Synced=True`, the CDC
  installs `oci://ghcr.io/braghettos/charts/openstack-installer:0.1.0`, and Keystone comes up.
- `openstack token issue` returns a Fernet token; `endpoint list` / `service list` /
  `user list` / `catalog list` are populated.
