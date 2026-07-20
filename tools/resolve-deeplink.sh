#!/usr/bin/env bash
# Resolve a serviceContract SSO deep-link template against a context, and
# optionally probe the resolved URL. This is the same substitution a portal
# performs when rendering the "open in native console" link from the service
# descriptor: placeholders {org} {tenant} {namespace} {project} are replaced
# with the caller's context; anything left unresolved is an error.
#
# Usage:
#   tools/resolve-deeplink.sh [--from-chart | <urlTemplate>]
#     [--org v] [--tenant v] [--namespace v] [--project v] [--check]
#
#   --from-chart  read serviceContract.sso.deepLink.urlTemplate from the
#                 umbrella chart values (requires python3 + pyyaml)
#   --check       HTTP-probe the resolved URL (HEAD, 5s timeout)
set -euo pipefail

TEMPLATE=""
ORG="" TENANT="" NAMESPACE="" PROJECT="" CHECK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from-chart)
      TEMPLATE="$(python3 -c '
import yaml
v = yaml.safe_load(open("blueprints/openstack/chart/values.yaml"))
print(v["serviceContract"]["sso"]["deepLink"]["urlTemplate"])
')" ;;
    --org)       ORG="$2"; shift ;;
    --tenant)    TENANT="$2"; shift ;;
    --namespace) NAMESPACE="$2"; shift ;;
    --project)   PROJECT="$2"; shift ;;
    --check)     CHECK=1 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           TEMPLATE="$1" ;;
  esac
  shift
done

[ -n "$TEMPLATE" ] || { echo "error: no template (pass one or --from-chart)" >&2; exit 2; }

url="$TEMPLATE"
url="${url//\{org\}/$ORG}"
url="${url//\{tenant\}/$TENANT}"
url="${url//\{namespace\}/$NAMESPACE}"
url="${url//\{project\}/$PROJECT}"

case "$url" in
  *\{*|*\}*)
    echo "error: unresolved placeholders remain: $url" >&2
    exit 1 ;;
esac

echo "$url"

if [ "$CHECK" = 1 ]; then
  code="$(curl -ksIL -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
  case "$code" in
    2*|3*|401|403) echo "reachable (http $code)" ;;
    *)             echo "unreachable (http ${code:-timeout})" >&2; exit 1 ;;
  esac
fi
