{{/*
osh-derive: kolla-style derivation helpers.

Each template takes a dict with a "global" key and emits a full openstack-helm
endpoints subtree (block-style YAML) from the small global input. This is the
helm-toolkit analog of kolla's kolla_url / kolla_address filters + the per-service
endpoint six-liners in group_vars/all/<service>.yml.

Passwords are referenced by "<secret>/<key>" so the derivation stays byte-stable;
the values themselves live in the generate-once Secret (secret-passwords.yaml).
*/}}

{{- define "osh-derive.endpoints.identity" -}}
{{- $g := .global -}}
{{- $proto := (($g.protocol).internal) | default "http" -}}
{{- $port := (($g.endpoints).identity).port | default 5000 -}}
name: keystone
namespace: {{ $g.namespace }}
hosts:
  default: keystone
  internal: keystone-api
host_fqdn_override:
  default: null
path:
  default: /v3
  healthcheck: /healthcheck
scheme:
  default: {{ $proto }}
  service: {{ $proto }}
port:
  api:
    default: 80
    internal: {{ $port }}
    service: {{ $port }}
auth:
  admin:
    region_name: {{ $g.region }}
    username: admin
    password_secret: identity-passwords/keystone_admin
    project_name: admin
    user_domain_name: default
    project_domain_name: default
    default_domain_id: default
{{- end -}}

{{- define "osh-derive.endpoints.oslo_db" -}}
{{- $g := .global -}}
{{- $port := (($g.endpoints).oslo_db).port | default 3306 -}}
hosts:
  default: mariadb
host_fqdn_override:
  default: null
namespace: {{ $g.namespace }}
path: /keystone
scheme: mysql+pymysql
port:
  mysql:
    default: {{ $port }}
auth:
  admin:
    username: root
    password_secret: identity-passwords/mariadb_root
  keystone:
    username: keystone
    password_secret: identity-passwords/keystone_db
{{- end -}}

{{- define "osh-derive.endpoints.oslo_cache" -}}
{{- $g := .global -}}
{{- $port := (($g.endpoints).oslo_cache).port | default 11211 -}}
hosts:
  default: memcached
host_fqdn_override:
  default: null
namespace: {{ $g.namespace }}
port:
  memcache:
    default: {{ $port }}
auth:
  # Pinned via the kept Secret - never re-randomised at render. This is the
  # determinism fix for the memcache_secret_key reconcile-churn baked into the
  # derivation so it cannot be reintroduced by hand.
  memcache_secret_key_secret: identity-passwords/memcache_secret_key
{{- end -}}

{{- define "osh-derive.endpoints.oslo_messaging" -}}
{{- $g := .global -}}
{{- $port := (($g.endpoints).oslo_messaging).port | default 5672 -}}
hosts:
  default: rabbitmq
host_fqdn_override:
  default: null
namespace: {{ $g.namespace }}
path: /keystone
scheme: rabbit
port:
  amqp:
    default: {{ $port }}
  http:
    default: 15672
statefulset:
  # Pinned to a single advertised host - prevents the rabbitmq-rabbitmq-1 ghost-host
  # transport_url regression documented in the determinism fixes.
  name: rabbitmq-rabbitmq
  replicas: 1
auth:
  keystone:
    username: keystone
    password_secret: identity-passwords/rabbitmq
{{- end -}}

{{/*
osh-derive.keystone.overlay: the STRUCTURAL endpoint keys to merge (-f) over the real
vendored keystone chart's values.yaml. Only the keys derived from global are emitted;
helm's deep-merge leaves every other chart default intact, so the vendored chart is
never edited (align-upstream rule preserved). This is the Phase-2 "chart consumes
derived values" bridge.
*/}}
{{- define "osh-derive.keystone.overlay" -}}
{{- $g := .global -}}
endpoints:
  cluster_domain_suffix: {{ $g.clusterDomain }}
  identity:
    namespace: {{ $g.namespace }}
    port:
      api:
        internal: {{ ($g.endpoints).identity.port | default 5000 }}
        service: {{ ($g.endpoints).identity.port | default 5000 }}
  oslo_db:
    namespace: {{ $g.namespace }}
    port:
      mysql:
        default: {{ ($g.endpoints).oslo_db.port | default 3306 }}
  oslo_cache:
    namespace: {{ $g.namespace }}
    port:
      memcache:
        default: {{ ($g.endpoints).oslo_cache.port | default 11211 }}
  oslo_messaging:
    namespace: {{ $g.namespace }}
    port:
      amqp:
        default: {{ ($g.endpoints).oslo_messaging.port | default 5672 }}
    statefulset:
      replicas: 1
{{- end -}}

{{/* Aggregate: the full endpoints tree keystone's chart would otherwise hand-write. */}}
{{- define "osh-derive.endpoints.all" -}}
identity:
{{ include "osh-derive.endpoints.identity" . | indent 2 }}
oslo_db:
{{ include "osh-derive.endpoints.oslo_db" . | indent 2 }}
oslo_cache:
{{ include "osh-derive.endpoints.oslo_cache" . | indent 2 }}
oslo_messaging:
{{ include "osh-derive.endpoints.oslo_messaging" . | indent 2 }}
{{- end -}}
