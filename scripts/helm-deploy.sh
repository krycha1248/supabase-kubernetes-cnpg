#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHART="supabase"
CHART_PATH="$REPO_ROOT/charts/$CHART"
VALUES_DIR="$REPO_ROOT/values"

usage() {
  cat <<EOF
Usage: $0 --cluster <name> [--backup] [<release-name>]

Required:
  --cluster <name>   kind cluster name (context is kind-<name>)

Optional:
  --backup           Enable the Barman Cloud plugin, point backups at the
                     in-cluster SeaweedFS, pre-create the backup bucket via
                     the bundled S3 backend's S3_BUCKET env, apply a one-shot
                     Backup CR, and wait for it to complete. Used to smoke-test
                     the backup wiring end-to-end on a kind cluster.

Positional:
  <release-name>     Helm release + namespace (default: supabase)

Environment:
  DOMAIN             Default <release-name>.supabase.local
  EDGE               Force "ingress" or "gateway" (overrides auto-detection)
EOF
}

CLUSTER=""
BACKUP=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --backup)  BACKUP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*) echo "Unknown flag: $1" >&2; usage; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [[ -z "$CLUSTER" ]]; then
  usage
  exit 2
fi

RELEASE="${1:-supabase}"

CTX="kind-$CLUSTER"

[[ -f "$CHART_PATH/Chart.yaml" ]] || { echo "ERROR: no Chart.yaml at $CHART_PATH" >&2; exit 2; }

# Cluster reachability -----------------------------------------------------
kubectl --context "$CTX" cluster-info >/dev/null

# Worker count drives the default Functions replica count below. Falls back
# to 1 for single-node (control-plane only) kind clusters created without
# --workers — kind leaves the control-plane untainted, so pods still schedule.
WORKER_NODES=$(kubectl --context "$CTX" get nodes \
  -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l)
(( WORKER_NODES < 1 )) && WORKER_NODES=1

# Domain / EDGE ------------------------------------------------------------
DOMAIN="${DOMAIN:-$RELEASE.supabase.local}"

if [[ -z "${EDGE:-}" ]]; then
  # Detect the mode cluster.sh configured Traefik for. cloud-provider-kind
  # registers a GatewayClass of its own unconditionally, so a generic
  # "any GatewayClass present" check misfires — look specifically for the
  # traefik-named class, matching cluster.sh cmd_validate.
  if kubectl --context "$CTX" get gatewayclass traefik >/dev/null 2>&1; then
    EDGE=gateway
  elif kubectl --context "$CTX" get ingressclass traefik >/dev/null 2>&1; then
    EDGE=ingress
  else
    echo "ERROR: neither GatewayClass nor IngressClass 'traefik' is present. Run cluster.sh create --mode ingress|gateway first, or set EDGE=..." >&2
    exit 3
  fi
fi

case "$EDGE" in
  ingress) INGRESS_ENABLED=true;  GATEWAY_ENABLED=false ;;
  gateway) INGRESS_ENABLED=false; GATEWAY_ENABLED=true  ;;
  *) echo "ERROR: EDGE must be 'ingress' or 'gateway' (got '$EDGE')" >&2; exit 2 ;;
esac

echo "Cluster  : $CLUSTER (context $CTX)"
echo "Release  : $RELEASE"
echo "Chart    : $CHART_PATH"
echo "Host     : $DOMAIN"
echo "Edge     : $EDGE"
echo "Workers  : $WORKER_NODES (used as Functions replicaCount)"
$BACKUP && echo "Backup   : enabled (in-cluster SeaweedFS)"

# Namespace ---------------------------------------------------------------
kubectl --context "$CTX" create namespace "$RELEASE" --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

# Values layering ---------------------------------------------------------
HELM_VALUES_ARGS=()

# Single trap covers all generated values files dropped in /tmp.
TMP_VALUES_FILES=()
cleanup_tmp_values() { [[ ${#TMP_VALUES_FILES[@]} -gt 0 ]] && rm -f "${TMP_VALUES_FILES[@]}"; }
trap cleanup_tmp_values EXIT

CNPG_CLUSTER="supabase-db"
BACKUP_BUCKET="supabase-backup"
STORAGE_BUCKET="stub"

# weed mini precreates buckets listed in S3_BUCKET (comma-separated). Always
# include the Storage API bucket; append the backup bucket only when --backup
# is on, so non-backup runs don't carry it.
S3_BUCKETS="$STORAGE_BUCKET"
$BACKUP && S3_BUCKETS="${S3_BUCKETS},${BACKUP_BUCKET}"

# Test-deploy defaults: pin Functions to one replica per worker node, disable
# HPA so the Deployment is a stable iteration target, and always enable the
# in-cluster SeaweedFS as the Storage API S3 backend (and as the destination
# for the optional --backup smoke test below). Layered first so user values
# files / --backup overrides take precedence.
DEFAULTS_VALUES="/tmp/supabase-deploy-defaults_$$_$RANDOM.yaml"
TMP_VALUES_FILES+=("$DEFAULTS_VALUES")
cat >"$DEFAULTS_VALUES" <<EOF
autoscaling:
  functions:
    enabled: false
deployment:
  functions:
    replicaCount: ${WORKER_NODES}
  s3:
    enabled: true
environment:
  s3:
    S3_BUCKET: "${S3_BUCKETS}"
tests:
  functions:
    enabled: true
EOF
HELM_VALUES_ARGS+=(-f "$DEFAULTS_VALUES")

BASE_VALUES="$VALUES_DIR/$CHART.yaml"
LOCAL_VALUES="$VALUES_DIR/$CHART.local.yaml"
[[ -f "$BASE_VALUES"  ]] && HELM_VALUES_ARGS+=(-f "$BASE_VALUES")
[[ -f "$LOCAL_VALUES" ]] && HELM_VALUES_ARGS+=(-f "$LOCAL_VALUES")

# --- Name helpers (mirror helm's supabase.fullname / supabase.s3.fullname).
# For release names that already contain the chart name, helm collapses the
# fullname to the release name — so for release=supabase the dashboard secret
# is "supabase-dashboard", not "supabase-supabase-dashboard".
case "$RELEASE" in
  *supabase*) FULLNAME="$RELEASE" ;;
  *)          FULLNAME="${RELEASE}-supabase" ;;
esac
case "$RELEASE" in
  *supabase-s3*) S3_SVC="$RELEASE" ;;
  *)             S3_SVC="${RELEASE}-supabase-s3" ;;
esac
S3_SECRET="${FULLNAME}-s3"

if $BACKUP; then
  BACKUP_VALUES="/tmp/supabase-backup-values_$$_$RANDOM.yaml"
  TMP_VALUES_FILES+=("$BACKUP_VALUES")
  cat >"$BACKUP_VALUES" <<EOF
cnpg:
  backup:
    enabled: true
    objectStore:
      configuration:
        destinationPath: s3://${BACKUP_BUCKET}/
        endpointURL: http://${S3_SVC}:8333
        s3Credentials:
          accessKeyId:
            name: ${S3_SECRET}
            key: keyId
          secretAccessKey:
            name: ${S3_SECRET}
            key: accessKey
        wal:
          compression: gzip
        data:
          compression: gzip
    scheduledBackup:
      immediate: true
EOF
  HELM_VALUES_ARGS+=(-f "$BACKUP_VALUES")
fi

# Install -----------------------------------------------------------------
helm --kube-context "$CTX" upgrade --install "$RELEASE" "$CHART_PATH" \
  -n "$RELEASE" \
  "${HELM_VALUES_ARGS[@]}" \
  --set "host=$DOMAIN" \
  --set "ingress.enabled=$INGRESS_ENABLED" \
  --set "gateway.enabled=$GATEWAY_ENABLED" \
  --wait --timeout 10m

# Resolve Traefik LoadBalancer IP (assigned by cloud-provider-kind). Wait up
# to ~2 min because on a fresh cluster CPK can take a moment to reconcile.
lb_ip=""
for _ in $(seq 1 60); do
  lb_ip="$(kubectl --context "$CTX" -n traefik get svc traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$lb_ip" ]] && break
  sleep 2
done

echo
echo "Deployed."
if [[ -n "$lb_ip" ]]; then
  cat <<EOF
Add to /etc/hosts (sudo required) and open http://$DOMAIN:

  $lb_ip  $DOMAIN
EOF
else
  echo "WARNING: could not resolve Traefik LB IP — access via the LB IP printed by 'kubectl -n traefik get svc traefik'." >&2
fi

# Studio dashboard credentials (HTTP Basic Auth through Kong). The generator
# Job runs as a pre-install hook so the Secret is in place once helm upgrade
# returns. If the user supplied their own existingSecret, skip with a note.
dash_ref="$(helm --kube-context "$CTX" get values "$RELEASE" -n "$RELEASE" -a \
  -o json 2>/dev/null | python3 -c \
  'import json,sys;d=json.load(sys.stdin);print(d.get("secret",{}).get("dashboard",{}).get("existingSecret") or "")' 2>/dev/null || true)"
dash_secret="${dash_ref:-${FULLNAME}-dashboard}"
dash_user="$(kubectl --context "$CTX" -n "$RELEASE" get secret "$dash_secret" \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
dash_pass="$(kubectl --context "$CTX" -n "$RELEASE" get secret "$dash_secret" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [[ -n "$dash_user" && -n "$dash_pass" ]]; then
  cat <<EOF

Studio dashboard login (HTTP Basic Auth):
  user: $dash_user
  pass: $dash_pass
EOF
else
  echo
  echo "WARNING: could not read dashboard credentials from Secret '$dash_secret' in namespace '$RELEASE'." >&2
fi

cat <<EOF

Edge Functions test fixture (provisioned via extraConfigMaps[hello]):
  curl -sS -X POST http://$DOMAIN/functions/v1/hello \\
    -H 'Content-Type: application/json' \\
    -d '{"name":"world"}'
EOF

# --- Backup smoke test --------------------------------------------------
# weed mini precreates the backup bucket via S3_BUCKET env (set above when
# --backup is on) — no explicit bucket-init step needed. Trigger an on-demand
# Backup CR and wait for it to complete. The ScheduledBackup in values has
# immediate=true, but its first Backup may race with cluster bring-up — we
# don't rely on it. A single explicit Backup CR gives a deterministic signal.
if $BACKUP; then
  echo
  echo "Backup: triggering smoke Backup CR and waiting for completion..."

  backup_name="${CNPG_CLUSTER}-smoke"
  kubectl --context "$CTX" -n "$RELEASE" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${backup_name}
spec:
  cluster:
    name: ${CNPG_CLUSTER}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

  kubectl --context "$CTX" -n "$RELEASE" wait \
    --for=jsonpath='{.status.phase}'=completed \
    "backup/${backup_name}" --timeout=5m

  echo "Backup: smoke backup ${backup_name} completed."
fi