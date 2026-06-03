{{/* The composition.krateo.io apiVersion served by the component CRDs, derived
     from chartVersion (crdgen maps version 0.1.1 -> apiVersion v0-1-1). Keeping
     this in one place means a version bump never strands a hardcoded v0-1-0. */}}
{{- define "osh.apiVersion" -}}
{{- $top := index . 0 -}}
{{- printf "composition.krateo.io/v%s" ($top.Values.chartVersion | toString | replace "." "-") -}}
{{- end -}}

{{/* Returns "true" if a Composition of <kind>/<name> reports Ready=True. */}}
{{- define "osh.ready" -}}
{{- $top := index . 0 -}}{{- $kind := index . 1 -}}{{- $name := index . 2 -}}
{{- $o := lookup (include "osh.apiVersion" (list $top)) $kind $top.Release.Namespace $name -}}
{{- $r := "" -}}
{{- if $o -}}{{- range ($o.status.conditions | default list) -}}
{{- if and (eq .type "Ready") (eq (.status | toString) "True") -}}{{- $r = "true" -}}{{- end -}}
{{- end -}}{{- end -}}
{{- $r -}}
{{- end -}}

{{/* Returns "true" if a generated CRD for <kind> in composition.krateo.io exists.
     Matched by Kind (not a guessed plural), so pluralization can never bite. */}}
{{- define "osh.crdExists" -}}
{{- $kind := index . 0 -}}
{{- $found := "" -}}
{{- range (lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" "").items -}}
{{- if and (eq .spec.group "composition.krateo.io") (eq .spec.names.kind $kind) -}}{{- $found = "true" -}}{{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/* "true" if every dependency Composition (by component name) is Ready. */}}
{{- define "osh.depsReady" -}}
{{- $top := index . 0 -}}{{- $deps := index . 1 -}}{{- $comps := index . 2 -}}
{{- $all := "true" -}}
{{- range $d := $deps -}}
  {{- $kind := "" -}}{{- range $c := $comps -}}{{- if eq $c.name $d -}}{{- $kind = $c.kind -}}{{- end -}}{{- end -}}
  {{- if ne (include "osh.ready" (list $top $kind $d)) "true" -}}{{- $all = "" -}}{{- end -}}
{{- end -}}
{{- $all -}}
{{- end -}}
