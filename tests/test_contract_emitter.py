#!/usr/bin/env python3
"""Mock-based e2e conformance test for the contract emitter.

Runs collect_usage() / collect_health() against canned OpenStack API
responses (Keystone projects + catalog, Nova, Cinder, Neutron) and asserts:

  * usage rows are shape-exact against the showback ``usage_records`` schema
    (ddl/001_usage_records.sql: record_id, org, tenant, service, resource_id,
    metric, quantity Float64, unit, window_start/window_end DateTime,
    tags Map(String, String), source - ingested_at is a DB-side default);
  * record_id is byte-for-byte showback's deterministicID(org, tenant,
    service, resource, metric, window), so a direct ClickHouse insert and
    the same logical record ingested through the showback API converge on
    one id;
  * 'key:value' Keystone project tags land as real key -> value Map entries
    (bare tag -> {tag: ''} documented fallback) so per-tag GROUP BY works;
  * health rows use exactly the OK | Warning | Critical | Unknown enum,
    every probed HTTP outcome maps onto it, and the consolidated
    '_service' row carries the worst component status;
  * re-runs inside the same window are idempotent (identical record_ids).

Stdlib-only and fully offline: the emitter's request() is monkeypatched
with a URL router. Wired into .github/workflows/lint.yaml so contract
conformance is regression-guarded.

Run: python3 -m unittest discover -s tests -v
"""
import hashlib
import importlib.util
import io
import json
import pathlib
import re
import socket
import unittest
import urllib.error
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parent.parent
EMITTER_PATH = REPO / "blueprints" / "openstack" / "chart" / "files" / "contract-emitter.py"

_spec = importlib.util.spec_from_file_location("contract_emitter", EMITTER_PATH)
emitter = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(emitter)

# Frozen clock: 2026-01-01T00:02:03Z. With the default 5m usage interval the
# aligned window is exactly 2026-01-01T00:00:00Z -> 00:05:00Z.
FIXED_TS = 1767225723
WINDOW_START = "2026-01-01 00:00:00"
WINDOW_END = "2026-01-01 00:05:00"
WINDOW_START_RFC3339 = "2026-01-01T00:00:00Z"

# ---------------------------------------------------------------------------
# Expected shapes (mirror showback ddl/001_usage_records.sql and the health
# table bootstrapped by ch_bootstrap_health_table; ingested_at is DEFAULTed
# server-side so the emitter must not send it).
# ---------------------------------------------------------------------------
USAGE_COLUMNS = {
    "record_id", "org", "tenant", "service", "resource_id", "metric",
    "quantity", "unit", "window_start", "window_end", "tags", "source",
}
HEALTH_COLUMNS = {
    "record_id", "org", "tenant", "service", "component", "status",
    "reason", "checked_at",
}
HEALTH_ENUM = {"OK", "Warning", "Critical", "Unknown"}
DATETIME_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")
RECORD_ID_RE = re.compile(r"^[0-9a-f]{32}$")


def showback_deterministic_id(*parts):
    """Independent reference reimplementation of showback's deterministicID
    (internal/store): sha256 over NUL-terminated parts, first 32 hex chars,
    window formatted as Go time.RFC3339Nano (whole seconds -> no fraction)."""
    h = hashlib.sha256()
    for p in parts:
        h.update(p.encode())
        h.update(b"\x00")
    return h.hexdigest()[:32]


# ---------------------------------------------------------------------------
# Mocked OpenStack control plane
# ---------------------------------------------------------------------------
AUTH_URL = "http://keystone.mock/v3"
CATALOG = [
    {"type": "identity", "name": "keystone",
     "endpoints": [{"interface": "internal", "url": "http://keystone.mock/v3"}]},
    {"type": "compute", "name": "nova",
     "endpoints": [{"interface": "internal", "url": "http://nova.mock/v2.1"}]},
    {"type": "volumev3", "name": "cinder",
     "endpoints": [{"interface": "internal", "url": "http://cinder.mock/v3"}]},
    {"type": "network", "name": "neutron",
     "endpoints": [{"interface": "internal", "url": "http://neutron.mock"}]},
]

USAGE_ROUTES = {
    "http://keystone.mock/v3/projects": {
        "projects": [
            {"id": "p1", "name": "tenant-a",
             "tags": ["env:prod", "gpu", "cost-center:cc-42"]},
            {"id": "p2", "name": "tenant-b", "tags": []},
        ]
    },
    "http://neutron.mock/v2.0/floatingips": {
        "floatingips": [{"project_id": "p1"}, {"project_id": "p1"},
                        {"project_id": "p2"}]
    },
    "http://nova.mock/v2.1/limits?tenant_id=p1": {
        "limits": {"absolute": {"totalInstancesUsed": 3,
                                "totalCoresUsed": 8,
                                "totalRAMUsed": 16384}}
    },
    "http://nova.mock/v2.1/limits?tenant_id=p2": {
        "limits": {"absolute": {"totalInstancesUsed": 1,
                                "totalCoresUsed": 2,
                                "totalRAMUsed": 2048}}
    },
    "http://cinder.mock/v3/os-quota-sets/p1?usage=True": {
        "quota_set": {"gigabytes": {"in_use": 120, "limit": 1000}}
    },
    "http://cinder.mock/v3/os-quota-sets/p2?usage=True": {
        "quota_set": {"gigabytes": {"in_use": 30, "limit": 1000}}
    },
    "http://nova.mock/v2.1/os-hypervisors/statistics": {
        "hypervisor_statistics": {"vcpus": 64, "memory_mb": 262144}
    },
    "http://cinder.mock/v3/scheduler-stats/get_pools?detail=True": {
        "pools": [{"capabilities": {"total_capacity_gb": 500.0}},
                  {"capabilities": {"total_capacity_gb": 250.0}}]
    },
}


def usage_request(method, url, token=None, body=None, headers=None, timeout=15):
    if url not in USAGE_ROUTES:
        raise AssertionError(f"unexpected URL requested: {method} {url}")
    return 200, {}, json.dumps(USAGE_ROUTES[url]).encode()


def health_request(method, url, token=None, body=None, headers=None, timeout=15):
    # One endpoint per branch of the contract's status mapping.
    if url.startswith("http://keystone.mock"):
        return 200, {}, b"{}"                                   # 2xx -> OK
    if url.startswith("http://nova.mock"):
        raise urllib.error.HTTPError(url, 503, "unavailable", {}, io.BytesIO())  # 5xx -> Critical
    if url.startswith("http://cinder.mock"):
        raise urllib.error.HTTPError(url, 404, "not found", {}, io.BytesIO())    # other 4xx -> Warning
    if url.startswith("http://neutron.mock"):
        raise socket.timeout("timed out")                        # timeout -> Unknown
    raise AssertionError(f"unexpected URL probed: {method} {url}")


class FrozenClock(unittest.TestCase):
    """Pin time.time() so windows are deterministic and assertable."""

    def setUp(self):
        patcher = mock.patch.object(emitter.time, "time", return_value=FIXED_TS)
        patcher.start()
        self.addCleanup(patcher.stop)
        env = mock.patch.dict(emitter.os.environ)
        env.start()
        self.addCleanup(env.stop)
        emitter.os.environ.pop("INTERVAL", None)      # default 5m / 1m
        emitter.os.environ.pop("OS_INTERFACE", None)  # default 'internal'


class TestUsageConformance(FrozenClock):
    def collect(self):
        with mock.patch.object(emitter, "request", usage_request):
            return emitter.collect_usage(AUTH_URL, "tok", CATALOG)

    def test_rows_are_shape_exact_against_usage_records_schema(self):
        rows = self.collect()
        self.assertTrue(rows, "collector emitted no rows")
        for r in rows:
            self.assertEqual(set(r), USAGE_COLUMNS, f"column drift in {r}")
            self.assertRegex(r["record_id"], RECORD_ID_RE)
            for col in ("org", "tenant", "service", "resource_id", "metric",
                        "unit", "source"):
                self.assertIsInstance(r[col], str, col)
            self.assertIsInstance(r["quantity"], float)   # Float64
            self.assertRegex(r["window_start"], DATETIME_RE)
            self.assertRegex(r["window_end"], DATETIME_RE)
            self.assertEqual(r["window_start"], WINDOW_START)
            self.assertEqual(r["window_end"], WINDOW_END)
            self.assertIsInstance(r["tags"], dict)        # Map(String, String)
            for k, v in r["tags"].items():
                self.assertIsInstance(k, str)
                self.assertIsInstance(v, str)
            json.dumps(r)  # must survive JSONEachRow serialization

    def test_record_id_matches_showback_deterministic_id(self):
        for r in self.collect():
            self.assertEqual(
                r["record_id"],
                showback_deterministic_id(r["org"], r["tenant"], r["service"],
                                          r["resource_id"], r["metric"],
                                          WINDOW_START_RFC3339),
                f"record_id diverges from showback deterministicID for {r['metric']}",
            )

    def test_keystone_tags_split_into_key_value_pairs(self):
        rows = self.collect()
        tags_a = next(r for r in rows if r["tenant"] == "tenant-a")["tags"]
        self.assertEqual(tags_a, {"env": "prod",          # key:value split
                                  "cost-center": "cc-42",
                                  "gpu": ""})             # bare-tag fallback
        tags_b = next(r for r in rows if r["tenant"] == "tenant-b")["tags"]
        self.assertEqual(tags_b, {})

    def test_declared_metrics_and_org_level_capacity(self):
        rows = self.collect()
        per_tenant = {m for r in rows if r["tenant"] == "tenant-a"
                      for m in [r["metric"]]}
        self.assertEqual(per_tenant, {"instances.count", "vcpu.used",
                                      "ram.used", "storage.used",
                                      "floating_ips.count"})
        capacity = {r["metric"]: r for r in rows if r["tenant"] == ""}
        self.assertEqual(set(capacity), {"vcpu.capacity", "ram.capacity",
                                         "storage.capacity"})
        self.assertEqual(capacity["storage.capacity"]["quantity"], 750.0)
        self.assertEqual(capacity["vcpu.capacity"]["resource_id"], "hypervisors")

    def test_reruns_in_same_window_are_idempotent(self):
        first = sorted(r["record_id"] for r in self.collect())
        second = sorted(r["record_id"] for r in self.collect())
        self.assertEqual(first, second)
        self.assertEqual(len(first), len(set(first)),
                         "record_id collision inside a single run")


class TestHealthConformance(FrozenClock):
    def collect(self):
        with mock.patch.object(emitter, "request", health_request):
            return emitter.collect_health(AUTH_URL, "tok", CATALOG)

    def test_rows_are_shape_exact_and_enum_bounded(self):
        rows = self.collect()
        self.assertTrue(rows)
        for r in rows:
            self.assertEqual(set(r), HEALTH_COLUMNS, f"column drift in {r}")
            self.assertIn(r["status"], HEALTH_ENUM,
                          f"status outside the contract enum: {r['status']!r}")
            self.assertRegex(r["record_id"], RECORD_ID_RE)
            self.assertRegex(r["checked_at"], DATETIME_RE)
            self.assertEqual(r["tenant"], "")
            json.dumps(r)

    def test_every_mapping_branch_and_worst_wins(self):
        status = {r["component"]: r["status"] for r in self.collect()}
        self.assertEqual(status, {
            "identity": "OK",         # 2xx
            "compute": "Critical",    # 5xx
            "volumev3": "Warning",    # other 4xx
            "network": "Unknown",     # timeout
            "_service": "Critical",   # consolidated: worst component wins
        })

    def test_record_id_is_org_qualified_and_deterministic(self):
        for r in self.collect():
            self.assertEqual(
                r["record_id"],
                showback_deterministic_id(r["org"], "", r["service"],
                                          r["component"],
                                          "2026-01-01T00:02:00Z"),  # 1m-aligned
                f"health record_id not org-qualified for {r['component']}",
            )


if __name__ == "__main__":
    unittest.main()
