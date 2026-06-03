{{/* Returns "true" if a Composition of <kind>/<name> reports Ready=True. */}}
{{- define "osh.ready" -}}
{{- $top := index . 0 -}}{{- $kind := index . 1 -}}{{- $name := index . 2 -}}
{{- $o := lookup "composition.krateo.io/v0-1-0" $kind $top.Release.Namespace $name -}}
{{- $r := "" -}}
{{- if $o -}}{{- range ($o.status.conditions | default list) -}}
{{- if and (eq .type "Ready") (eq (.status | toString) "True") -}}{{- $r = "true" -}}{{- end -}}
{{- end -}}{{- end -}}
{{- $r -}}
{{- end -}}

{{/* Returns "true" if the component's generated CRD exists. */}}
{{- define "osh.crdExists" -}}
{{- $name := index . 0 -}}
{{- if lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" (printf "openstack%ss.composition.krateo.io" $name) -}}true{{- end -}}
{{- end -}}

{{/* "true" if every dependency Composition (by component name) is Ready. */}}
{{- define "osh.depsReady" -}}
{{- $top := index . 0 -}}{{- $deps := index . 1 -}}{{- $comps := index . 2 -}}
{{- $all := "true" -}}
{{- range $d := $deps -}}
  {{- $kind := "" -}}{{- range $c := $comps -}}{{- if eq $c.name $d -}}{{- $kind = $c.kind -}}{{- end -}}{{- end -}}
  {{- if ne (include "osh.ready" (list $top $kind (printf "openstack-%s" $d))) "true" -}}{{- $all = "" -}}{{- end -}}
{{- end -}}
{{- $all -}}
{{- end -}}
