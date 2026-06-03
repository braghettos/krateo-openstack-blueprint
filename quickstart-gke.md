# Quickstart (GKE) — OpenStack with compute (Nova/QEMU)

kind on Apple Silicon cannot run compute (no `/dev/kvm`, arm64-only images). A **disposable GKE
cluster** with **Ubuntu** nodes runs the amd64 OpenStack images natively and provides the Open
vSwitch kernel datapath Neutron needs, with Nova using **QEMU** software virtualization (no KVM).

## 1. Disposable cluster

A single Ubuntu node with the OVS/vxlan kernel modules is enough.

```sh
gcloud container clusters create osh --zone us-central1-a --num-nodes 1 \
  --machine-type e2-standard-8 --image-type UBUNTU_CONTAINERD \
  --disk-type pd-standard --disk-size 100 --no-enable-autoupgrade --no-enable-autorepair
gcloud container clusters get-credentials osh --zone us-central1-a

# Label the node for all OpenStack roles
kubectl label --overwrite nodes --all \
  openstack-control-plane=enabled openstack-compute-node=enabled \
  openvswitch=enabled l3-agent=enabled
```

The Ubuntu node image already has the `openvswitch` and `vxlan` kernel modules; the OVS chart
loads them. The node's primary NIC is `ens4` — the default for `neutron.network.interface.tunnel`.

## 2. Krateo + register every blueprint

```sh
helm repo add jetstack https://charts.jetstack.io
helm repo add krateo https://charts.krateo.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager \
  --create-namespace --set crds.enabled=true --wait
helm upgrade --install core-provider krateo/core-provider \
  --version 1.0.0 -n krateo-system --create-namespace --wait

kubectl create namespace openstack-system
for c in mariadb memcached keystone glance horizon rabbitmq placement openvswitch libvirt nova neutron; do
  kubectl apply -f blueprints/$c/compositiondefinition.yaml
done
```

No image pre-loading is needed — GKE nodes are amd64, so the OpenStack images pull and run natively.

## 3. Deploy one OpenStack install (Composition set)

```sh
kubectl create namespace openstack
kubectl apply -f examples/01-identity.yaml      # mariadb, memcached, keystone, glance, horizon
kubectl apply -f examples/02-compute.yaml       # rabbitmq, placement, ovs, libvirt, nova, neutron
```

The compute Compositions inherit the validated defaults: Nova `virt_type: qemu`, Neutron single-node
ML2/OVS over VXLAN on `ens4`, no external provider bridge. To override per Composition, e.g.:

```yaml
apiVersion: composition.krateo.io/v0-1-0
kind: OpenstackNeutron
metadata: { name: openstack-neutron, namespace: openstack }
spec:
  network: { interface: { tunnel: ens4 } }   # set to your node's primary NIC
```

## 4. Verify

Identity (works natively, no emulation):

```sh
kubectl -n openstack run osclient --restart=Never --image=quay.io/airshipit/openstack-client:2025.1-ubuntu_jammy \
  --env OS_AUTH_URL=http://keystone-api.openstack.svc.cluster.local:5000/v3 \
  --env OS_USERNAME=admin --env OS_PASSWORD=password --env OS_PROJECT_NAME=admin \
  --env OS_USER_DOMAIN_NAME=Default --env OS_PROJECT_DOMAIN_NAME=Default \
  --env OS_IDENTITY_API_VERSION=3 --env OS_REGION_NAME=RegionOne --env OS_INTERFACE=internal \
  --command -- sleep 1d
kubectl exec -n openstack osclient -- openstack token issue
```

Compute (after the compute Compositions converge):

```sh
kubectl exec -n openstack osclient -- openstack --os-interface internal compute service list
kubectl exec -n openstack osclient -- openstack --os-interface internal hypervisor list
kubectl exec -n openstack osclient -- openstack --os-interface internal network agent list
```

libvirt reports **QEMU 8.2.2** with `domain type='qemu'` (software virtualization). The OVS agent
brings up `br-int`/`br-tun`. Booting a CirrOS instance to `ACTIVE` (register image → create
network/subnet → `openstack server create`) is the last-mile step; Nova/Neutron agent
registration on GKE is being finalised.

## Teardown (important — this cluster costs money)

```sh
gcloud container clusters delete osh --zone us-central1-a --quiet
```
