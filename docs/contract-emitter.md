# Contract emitter — runtime usage & health emission

The umbrella chart's `serviceContract` stanza *declares* what this service
emits (`serviceContract.usage.metrics`, `serviceContract.health`). The
**contract emitter** is the runtime side of that declaration: two CronJobs
that poll the OpenStack APIs on the declared intervals and write normalized
rows to ClickHouse over its HTTP interface. Together with the descriptor
ConfigMap, the capability ClusterRoles and the SSO deep-link template, it
makes this blueprint a complete reference implementation of the service
integration contract.

Everything is chart-level and vendor-generic: a stdlib-only Python script
(`blueprints/openstack/chart/files/contract-emitter.py`) on a plain
`python:3-alpine` image, configured entirely from values. No controller, no
CRD, no platform-specific code.

## Enabling

Disabled by default (the chart must stay installable without a ClickHouse
data plane). The management platform enables it and points it at its own:

```yaml
contractEmitter:
  enabled: true
  org: my-org                       # stamped on every emitted record
  clickhouse:
    url: http://clickhouse.krateo-system.svc.cluster.local:8123
    database: krateo
```

OpenStack credentials come from the OpenStack-Helm admin openrc secret the
keystone component already creates (`keystone-keystone-admin`, keys
`OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, ...), so there is nothing to
wire on a default install.

## Usage records (`MODE=usage`)

One CronJob on `serviceContract.usage.interval`. Rows land in
`<database>.usage_records` (the normalized *UsageRecord* shape consumed
uniformly by dashboards and rating engines):

| column | value |
|---|---|
| `record_id` | deterministic hash of (service, metric, resource, window) — re-runs in the same window replace, never duplicate |
| `org` | `contractEmitter.org` |
| `tenant` | Keystone project name (empty for org-level capacity) |
| `service` | `serviceContract.service.name` |
| `resource_id` | project id / `hypervisors` / `cinder-pools` |
| `metric`, `quantity`, `unit` | as declared in `serviceContract.usage.metrics` |
| `window_start`, `window_end` | interval-aligned UTC window |
| `tags` | the Keystone **project tags** (tag governance / per-tag showback) |
| `source` | `openstack-blueprint` |

Collectors (all best-effort — a missing service skips its metrics):

- **Nova** `GET /limits?tenant_id=` → `instances.count`, `vcpu.used`, `ram.used`
- **Nova** `GET /os-hypervisors/statistics` → `vcpu.capacity`, `ram.capacity`
- **Cinder** `GET /os-quota-sets/<id>?usage=True` → `storage.used`
- **Cinder** `GET /scheduler-stats/get_pools` → `storage.capacity`
- **Neutron** `GET /v2.0/floatingips` → `floating_ips.count`

## Health records (`MODE=health`)

One CronJob on `serviceContract.health.interval`. Every service in the
Keystone catalog is probed and mapped onto **exactly**
`OK | Warning | Critical | Unknown`:

- `2xx/3xx/401/403` → `OK` (the API answers; auth-required is healthy)
- `5xx` / connection error → `Critical`
- other `4xx` → `Warning`
- timeout → `Unknown`

A consolidated `_service` row (worst component wins) gives aggregators a
single per-service signal. Rows land in `<database>.health_records`
(`CREATE TABLE IF NOT EXISTS` bootstrap is on by default,
`clickhouse.bootstrapHealthTable`).

## SSO deep-link resolution

The descriptor's `serviceContract.sso.deepLink.urlTemplate` (Skyline console,
`{project}` placeholder, Keystone token-rescope pre-redirect) is what a portal
resolves per caller context. `tools/resolve-deeplink.sh` performs the same
substitution stand-alone — used by CI to assert the template resolves, and
with `--check` to probe a live console:

```console
$ tools/resolve-deeplink.sh --from-chart --project demo
https://skyline.openstack.example.com/demo
```
