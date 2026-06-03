# Quickstart — OpenStack blueprint on kind

End-to-end test of the blueprint on a local [kind](https://kind.sigs.k8s.io/) cluster. Two
paths are shown:

- **A. Chart only** — deploy the umbrella with Helm directly (fastest way to see OpenStack run).
- **B. Krateo** — register the `CompositionDefinition` and drive it as a Composition.

> **Apple Silicon note.** OpenStack images are amd64-only; some are manifest *lists* that omit
> arm64, which an arm64 node refuses at pull time. We run on a normal arm64 kind node and
> pre-load the images as amd64 (`tools/kind-load-images.sh`); they then run under Rosetta/qemu
> emulation. A full amd64 kind node is *not* used — kubeadm is too slow under whole-node
> emulation. On a native amd64 cluster, skip the pre-load step entirely.

## 0. Create the cluster

```sh
kind create cluster --config tools/kind-openstack.yaml      # node "openstack", Horizon NodePorts mapped
kubectl label --overwrite nodes --all openstack-control-plane=enabled
```

## A. Chart only

```sh
# Pre-load amd64 images (Apple Silicon only)
tools/kind-load-images.sh openstack

# Install the identity control plane
kubectl create namespace openstack
helm dependency build ./chart            # vendored deps; no network needed
# helm needs a real version; stamp one for local installs:
sed 's/CHART_VERSION/0.1.0/' chart/Chart.yaml > /tmp/Chart.yaml && cp /tmp/Chart.yaml chart/Chart.yaml
helm upgrade --install openstack ./chart --namespace openstack --timeout 900s

kubectl -n openstack rollout status deploy/keystone-api --timeout=600s
```

Verify OpenStack identity works:

```sh
kubectl -n openstack run osclient --rm -it --restart=Never \
  --image=quay.io/airshipit/openstack-client:2025.1-ubuntu_jammy \
  --env OS_AUTH_URL=http://keystone-api.openstack.svc.cluster.local:5000/v3 \
  --env OS_USERNAME=admin --env OS_PASSWORD=password --env OS_PROJECT_NAME=admin \
  --env OS_USER_DOMAIN_NAME=Default --env OS_PROJECT_DOMAIN_NAME=Default \
  --env OS_IDENTITY_API_VERSION=3 --env OS_REGION_NAME=RegionOne --env OS_INTERFACE=internal \
  --command -- openstack token issue
```

A token table is printed → identity is functional. Try also `openstack endpoint list`,
`openstack service list`, `openstack catalog list`.

Optional components:

```sh
helm upgrade openstack ./chart -n openstack \
  --reuse-values --set glance.enabled=true --set horizon.enabled=true
# Horizon dashboard: http://localhost:31000
```

## B. Krateo

Install just enough Krateo to reconcile a `CompositionDefinition`:

```sh
helm repo add krateo https://charts.krateo.io
helm repo update
helm upgrade --install core-provider krateo/core-provider \
  --version 1.0.0 -n krateo-system --create-namespace --wait
```

Register the blueprint (the chart must be published to
`oci://ghcr.io/braghettos/charts/openstack-installer:0.1.0` and the GHCR package made public,
or supply pull credentials in `compositiondefinition.yaml`):

```sh
kubectl create namespace openstack-system
kubectl apply -f compositiondefinition.yaml

# Wait for the Composition CRD to be generated
kubectl wait compositiondefinition/openstack -n openstack-system \
  --for=condition=Ready --timeout=180s
kubectl get crd openstackinstallers.composition.krateo.io
```

Create one OpenStack install:

```sh
kubectl create namespace openstack
tools/kind-load-images.sh openstack      # Apple Silicon only
kubectl apply -f examples/composition.yaml

kubectl wait openstackinstaller/openstack -n openstack \
  --for=condition=Ready --timeout=900s
```

Then verify with the same `osclient` token-issue command as in path A.

> If you re-publish a changed chart under the **same** version, restart the analyzers so the
> CDC RBAC is regenerated (a fresh install does not need this):
> `kubectl rollout restart deploy/core-provider deploy/core-provider-chart-inspector -n krateo-system`

## Teardown

```sh
kind delete cluster --name openstack
```
