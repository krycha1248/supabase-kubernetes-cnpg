{{/*
Expand the name of the chart.
*/}}
{{- define "supabase.s3.name" -}}
{{- default (print .Chart.Name "-s3") .Values.deployment.s3.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "supabase.s3.fullname" -}}
{{- if .Values.deployment.s3.fullnameOverride }}
{{- .Values.deployment.s3.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default (print .Chart.Name "-s3") .Values.deployment.s3.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "supabase.s3.selectorLabels" -}}
app.kubernetes.io/name: {{ include "supabase.s3.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "supabase.s3.serviceAccountName" -}}
{{- if .Values.serviceAccount.s3.create -}}
{{- default (include "supabase.s3.fullname" .) .Values.serviceAccount.s3.name -}}
{{- else if .Values.serviceAccount.s3.name -}}
{{- .Values.serviceAccount.s3.name -}}
{{- else -}}
{{- include "supabase.serviceAccountName" . -}}
{{- end -}}
{{- end -}}
