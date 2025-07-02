{{/*
Expand the name of the chart.
*/}}
{{- define "linkurious-entity-resolution.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "linkurious-entity-resolution.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "linkurious-entity-resolution.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "linkurious-entity-resolution.labels" -}}
helm.sh/chart: {{ include "linkurious-entity-resolution.chart" . }}
{{ include "linkurious-entity-resolution.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "linkurious-entity-resolution.selectorLabels" -}}
app.kubernetes.io/name: {{ include "linkurious-entity-resolution.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "linkurious-entity-resolution.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "linkurious-entity-resolution.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
{{/*
Default external url
*/}}
{{- define "linkurious-entity-resolution.defaultHostUrl" -}}
{{- print   (include "linkurious-entity-resolution.fullname" .) "."  .Release.Namespace "." .Values.hostPostfix  -}}
{{- end }}
