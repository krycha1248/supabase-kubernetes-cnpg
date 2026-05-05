{{/*
Expand the name of the JWT secret.
*/}}
{{- define "supabase.secret.jwt" -}}
{{- printf "%s-jwt" (include "supabase.fullname" .) }}
{{- end -}}

{{/*
Expand the name of the publishable-key Secret. Split out so foundry (or any
operator) can pre-seed the publishable key before chart install — it is the
build-time VITE_SUPABASE_PUBLISHABLE_KEY value and must exist before the app
image is built.
*/}}
{{- define "supabase.secret.publishableKey" -}}
{{- $cfg := default (dict) .Values.secret.publishableKey -}}
{{- if $cfg.existingSecret -}}
{{- $cfg.existingSecret -}}
{{- else -}}
{{- printf "%s-publishable-key" (include "supabase.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Expand the name of the SMTP secret.
*/}}
{{- define "supabase.secret.smtp" -}}
{{- printf "%s-smtp" (include "supabase.fullname" .) }}
{{- end -}}

{{/*
Expand the name of the dashboard secret.
*/}}
{{- define "supabase.secret.dashboard" -}}
{{- printf "%s-dashboard" (include "supabase.fullname" .) }}
{{- end -}}

{{/*
Return the Secret name that holds credentials for the given Postgres role.
Honors .Values.secret.db.existingSecrets.<role>; falls back to
"<fullname>-db-<role-with-dashes>", which is what the db-generator Job creates.
Usage: {{ include "supabase.secret.dbRole" (dict "root" $ "role" "authenticator") }}
*/}}
{{- define "supabase.secret.dbRole" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $existing := get (default (dict) $root.Values.secret.db.existingSecrets) $role -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-db-%s" (include "supabase.fullname" $root) ($role | replace "_" "-") -}}
{{- end -}}
{{- end -}}

{{/*
List of Postgres roles the chart provisions. Order matters only for stable
rendering of the generator Job; the roles themselves are independent.
*/}}
{{- define "supabase.db.roles" -}}
postgres supabase_admin authenticator pgbouncer supabase_auth_admin supabase_storage_admin supabase_functions_admin
{{- end -}}

{{/*
Expand the name of the analytics secret.
*/}}
{{- define "supabase.secret.analytics" -}}
{{- printf "%s-analytics" (include "supabase.fullname" .) }}
{{- end -}}

{{/*
Expand the name of the meta secret.
*/}}
{{- define "supabase.secret.meta" -}}
{{- printf "%s-meta" (include "supabase.fullname" .) }}
{{- end -}}


{{/*
Expand the name of the realtime secret.
*/}}
{{- define "supabase.secret.realtime" -}}
{{- printf "%s-realtime" (include "supabase.fullname" .) }}
{{- end -}}

{{/*
Expand the name of the s3 secret.
*/}}
{{- define "supabase.secret.s3" -}}
{{- printf "%s-s3" (include "supabase.fullname" .) }}
{{- end -}}

{{/*
Expand the name of the minio secret.
*/}}
{{- define "supabase.secret.minio" -}}
{{- printf "%s-minio" (include "supabase.fullname" .) }}
{{- end -}}

{{/*
Expand the name of the bigquery secret.
*/}}
{{- define "supabase.secret.bigquery" -}}
{{- printf "%s-bigquery" (include "supabase.fullname" .) }}
{{- end -}}

{{/*
ServiceAccount name used by the pre-install/pre-upgrade generator Jobs.
Honors .Values.secret.generator.serviceAccount.name; falls back to
"<fullname>-generator" rendered by templates/secrets/generator-rbac.yaml.
*/}}
{{- define "supabase.generator.serviceAccountName" -}}
{{- $cfg := default (dict) (default (dict) .Values.secret.generator).serviceAccount -}}
{{- if $cfg.name -}}
{{- $cfg.name -}}
{{- else -}}
{{- printf "%s-generator" (include "supabase.fullname" .) -}}
{{- end -}}
{{- end -}}
