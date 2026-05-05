{{/*
Expand the name of the chart.
*/}}
{{- define "supabase.rustfs.name" -}}
{{- default (print .Chart.Name "-rustfs") .Values.deployment.rustfs.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "supabase.rustfs.fullname" -}}
{{- if .Values.deployment.rustfs.fullnameOverride }}
{{- .Values.deployment.rustfs.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default (print .Chart.Name "-rustfs") .Values.deployment.rustfs.nameOverride }}
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
{{- define "supabase.rustfs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "supabase.rustfs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "supabase.rustfs.serviceAccountName" -}}
{{- if .Values.serviceAccount.rustfs.create -}}
{{- default (include "supabase.rustfs.fullname" .) .Values.serviceAccount.rustfs.name -}}
{{- else if .Values.serviceAccount.rustfs.name -}}
{{- .Values.serviceAccount.rustfs.name -}}
{{- else -}}
{{- include "supabase.serviceAccountName" . -}}
{{- end -}}
{{- end -}}
