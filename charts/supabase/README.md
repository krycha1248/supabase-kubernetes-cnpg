# Supabase for Kubernetes with Helm (CNPG variant)

This directory contains the configurations and scripts required to run Supabase inside a Kubernetes cluster.

This is an **opinionated fork** of [supabase-community/supabase-kubernetes](https://github.com/supabase-community/supabase-kubernetes): the single-pod Postgres StatefulSet from the upstream chart is replaced with a [CloudNativePG](https://cloudnative-pg.io/) (CNPG) `Cluster`. The StatefulSet path, the external-DB init Job, and the community `db.*` values are not supported and have been removed from this chart. If you need one of those, use the upstream chart.

## Prerequisites

- A Kubernetes cluster with the **CloudNativePG operator pre-installed**, **version ≥ 1.28.2** — earlier versions are missing CRD fields the chart relies on. This chart only ships the `Cluster` and `Database` CRs, not the operator.
- The `supabase/postgres` image matching `Chart.yaml` `appVersion` (currently `17.6.1.108`). The CNPG cluster pulls it automatically; override via `cnpg.image.tag` if needed.

For production: run more than one CNPG instance (`cnpg.instances: 3`) and wire up a backup `ObjectStore` (Barman-cloud plugin).

## Usage example

> For this section we're using Minikube and Docker to create a Kubernetes cluster


1. Create a cluster with Minikube:

    ```bash
    minikube start --driver=docker
    minikube addons enable ingress
    echo "$(minikube ip)     supabase.local" | sudo tee -a /etc/hosts > /dev/null
    ```

2. Install the CloudNativePG operator (one-time, cluster-wide; version **≥ 1.28.2**):

    ```bash
    kubectl apply --server-side -f \
      https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.28.2.yaml
    ```

3. Install Supabase from this chart:

    ```bash
    helm install demo ./charts/supabase
    ```

4. The first deployment takes a few minutes (CNPG bootstrap, jwt-generator Job, service pulls). You can view the status of the pods using:

    ```bash
    kubectl get pod -l app.kubernetes.io/instance=demo

    NAME                                      READY   STATUS    RESTARTS      AGE
    demo-supabase-analytics-xxxxxxxxxx-xxxxx  1/1     Running   0             47s
    demo-supabase-auth-xxxxxxxxxx-xxxxx       1/1     Running   0             47s
    demo-supabase-functions-xxxxxxxxxx-xxxxx  1/1     Running   0             47s
    demo-supabase-imgproxy-xxxxxxxxxx-xxxxx   1/1     Running   0             47s
    demo-supabase-kong-xxxxxxxxxx-xxxxx       1/1     Running   0             47s
    demo-supabase-meta-xxxxxxxxxx-xxxxx       1/1     Running   0             47s
    demo-supabase-realtime-xxxxxxxxxx-xxxxx   1/1     Running   0             47s
    demo-supabase-rest-xxxxxxxxxx-xxxxx       1/1     Running   0             47s
    demo-supabase-storage-xxxxxxxxxx-xxxxx    1/1     Running   0             47s
    demo-supabase-studio-xxxxxxxxxx-xxxxx     1/1     Running   0             47s
    demo-supabase-vector-xxxxxxxxxx-xxxxx     1/1     Running   0             47s
    ```

   The Postgres pods are managed by CNPG and carry `cnpg.io/cluster=<cnpg.clusterName>` labels instead:

    ```bash
    kubectl get pod -l cnpg.io/cluster=supabase-db

    NAME            READY   STATUS    RESTARTS   AGE
    supabase-db-1   1/1     Running   0          47s
    ```

5. Open Supabase Studio in your browser: http://supabase.local

   Use the **default credentials** below (for local development only):
   - **Username:** `supabase`
   - **Password:** `this_password_is_insecure_and_should_be_updated`

6. Uninstall Supabase example:

    ```bash
    helm uninstall demo
    minikube delete
    sudo sed -i '/[[:space:]]supabase\.local$/d' /etc/hosts
    ```

## Customize

You should consider to adjust the following values in `values.yaml`:

- `RELEASE_NAME`: Name used for helm release
- `STUDIO.EXAMPLE.COM` URL to Studio

If you want to use mail, consider to adjust the following values in `values.yaml`:

- `SMTP_ADMIN_MAIL`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_SENDER_NAME`

### JWT Secret

A **pre-install Job** (`jwt-generator`) mints the full set of JWT material on first install and writes it to a single Secret `<release>-supabase-jwt`:

- HS256 legacy — `secret`, `anonKey`, `serviceKey`
- ES256 asymmetric — `anonKeyAsymmetric`, `serviceKeyAsymmetric`, `jwtKeys`, `jwtJwks`
- Opaque sb_* keys — `publishableKey`, `secretKey`

This mirrors upstream Supabase's [`generate-keys.sh`](https://supabase.com/docs/guides/self-hosting/docker#generate-and-configure-api-keys) + [`add-new-auth-keys.sh`](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys) in one step. The Job is idempotent — the Secret is populated only on the first install; subsequent upgrades reuse the existing values so keys never rotate implicitly.

To bring your own pre-populated Secret (recommended for production, e.g. from an external secret manager):

```yaml
secret:
  jwt:
    existingSecret: my-supabase-jwt
    # Optional: map to actual key names inside the referenced Secret
    # existingSecretKey:
    #   anonKey: anonKey
    #   serviceKey: serviceKey
    #   secret: secret
```

When `existingSecret` is set, the generator Job is skipped entirely. The referenced Secret must contain all nine keys above. See the [self-hosted auth keys docs](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys) for how to produce them.

### SMTP Secret

Connection credentials for the SMTP mail server will also be provided via Kubernetes secret referenced in `values.yaml`:

```yaml
secret:
  smtp:
    username: <your-smtp-username>
    password: <your-smtp-password>
```

### DB Secrets (per-role)

Unlike the upstream chart, this fork does **not** use a single `postgres` password. A pre-install Job (`db-generator`) mints one random password per Postgres role and stores each one in its own `kubernetes.io/basic-auth` Secret named `<release>-db-<role-with-dashes>`. CNPG consumes those directly (`superuserSecret` + `managed.roles[*].passwordSecret`) and the Supabase services each read the password of the role they authenticate as.

Roles provisioned:

```
postgres
supabase_admin
authenticator
pgbouncer
supabase_auth_admin
supabase_storage_admin
supabase_functions_admin
```

To bring your own credentials for any role, pre-create a basic-auth Secret with keys `username` (= role name) and `password`, then reference it:

```yaml
secret:
  db:
    database: postgres
    existingSecrets:
      postgres: my-postgres-secret
      authenticator: my-authenticator-secret
      # Unlisted roles are still generated by the Job.
```

Passwords never rotate once generated — missing Secrets are filled in on the next upgrade, existing ones are left untouched.

### Dashboard secret

By default, a username and password is required to access the Supabase Studio dashboard. Simply change them at:

```yaml
secret:
  dashboard:
    username: supabase
    password: this_password_is_insecure_and_should_be_updated
```

### Analytics secret

A new logflare secret API key is required for securing communication between all of the Supabase services. To set the secret, generate a new 32 characters long secret similar to the step [above](#jwt-secret).

```yaml
secret:
  analytics:
    publicAccessToken: "your-super-secret-and-long-logflare-key-public"
    privateAccessToken: "your-super-secret-and-long-logflare-key-private"
```

### BigQuery secret

When using BigQuery as the Logflare analytics backend, provide a GCP service account JSON key via secret values:

```yaml
bigQuery:
  enabled: true
  projectId: my-gcp-project
  projectNumber: "123456789"

secret:
  bigquery:
    gcloudJson: '{"type":"service_account", ...}'
```

You can also reference an existing Kubernetes Secret:

```yaml
secret:
  bigquery:
    existingSecret: my-bigquery-secret
    existingSecretKey:
      gcloudJson: gcloud.json
```

### S3 secret

Supabase storage supports the use of S3 object-storage. To enable S3 for Supabase storage:

1. Set S3 key ID and access key:
  ```yaml
   secret:
    s3:
      keyId: your-s3-key-id
      accessKey: your-s3-access-key
  ```
2. Set storage S3 environment variables:
  ```yaml
  storage:
    environment:
      # Set S3 endpoint if using external object-storage
      # GLOBAL_S3_ENDPOINT: http://minio:9000
      STORAGE_BACKEND: s3
      GLOBAL_S3_PROTOCOL: http
      GLOBAL_S3_FORCE_PATH_STYLE: true
      AWS_DEFAULT_REGION: stub
  ```
3. (Optional) Enable internal minio deployment
  ```yaml
  minio:
    enabled: true
  ```

### Extra env (secret references, OAuth providers, …)

Every service exposes `deployment.<svc>.extraEnv`, a raw list of Kubernetes container env entries appended to the pod's `env:`. Use it when you need `valueFrom` — secret/configmap keys, field refs, resource refs — so sensitive values never appear in `values.yaml`. Plain literal values still go in `environment.<svc>` (rendered as `value:`).

Example — configure a Google OAuth provider for GoTrue. Public settings are literals, credentials reference a Secret you create out-of-band (e.g. via `kubectl create secret`, External Secrets, Sealed Secrets):

```yaml
environment:
  auth:
    GOTRUE_EXTERNAL_GOOGLE_ENABLED: "true"
    GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI: "https://supabase.local/auth/v1/callback"

deployment:
  auth:
    extraEnv:
      - name: GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID
        valueFrom:
          secretKeyRef:
            name: my-oauth
            key: google-client-id
      - name: GOTRUE_EXTERNAL_GOOGLE_SECRET
        valueFrom:
          secretKeyRef:
            name: my-oauth
            key: google-secret
```

Full list of provider env vars (Apple, Azure, GitHub, GitLab, Keycloak, Slack, etc.): [GoTrue config reference](https://github.com/supabase/auth/blob/master/example.env). The same pattern works for any variable on any service — not just auth providers.

Entries are appended verbatim; avoid re-declaring env names already set by the chart (DB_HOST, JWT secrets, etc.).

### Edge Functions runtime tuning

`files/functions/index.ts` (the user-worker bootstrap shipped as a ConfigMap)
reads its three perf knobs from env vars instead of hardcoded constants. The
defaults live under `environment.functions` so they can be overridden without
editing the script:

```yaml
environment:
  functions:
    USER_WORKER_MEMORY_LIMIT_MB: "256"     # passed to EdgeRuntime.userWorkers.create
    USER_WORKER_TIMEOUT_MS: "400000"        # per-request worker timeout
    USER_WORKER_NO_MODULE_CACHE: "false"    # set "true" to disable Deno's module cache
```

Override per environment with `--set environment.functions.USER_WORKER_MEMORY_LIMIT_MB=512`
or via your `values.yaml`. The script crashes the worker if any of these is
missing — keep all three defined.

#### Custom edge functions

User functions are delivered via ConfigMaps the user creates out-of-band
(kustomize, GitOps, separate chart, or `kubectl create configmap`). Each
entry in `deployment.functions.extraConfigMaps` declares a ConfigMap and
the files inside it; the chart mounts each declared file as a subPath
under `/home/deno/functions/<mountPath>/<file>`. Studio dispatches the
same list (read-only) so the dashboard can list deployed functions.

```yaml
deployment:
  functions:
    extraConfigMaps:
      # Single-file function (default — files: [index.ts])
      - name: edge-fn-orders
        mountPath: orders             # → /home/deno/functions/orders/index.ts

      # Multi-file function — list every ConfigMap key you want mounted
      - name: edge-fn-billing
        mountPath: billing            # → /home/deno/functions/billing/{index,helpers,deps}.ts
        files:
          - index.ts
          - helpers.ts
          - deps.ts

      # Shared helpers — directory layout matches the official Supabase CLI
      - name: edge-fn-shared
        mountPath: _shared            # imported from a function as ../_shared/<file>.ts
        files:
          - cors.ts
          - auth.ts
```

Author functions with the same layout `supabase functions deploy` produces:
`<func>/index.ts` plus optional sibling files (`helpers.ts`, `deps.ts`).
Shared helpers live in their own ConfigMap mounted as `_shared` and are
imported as `../_shared/<file>.ts`.

Provision a function ConfigMap from a directory of files:

```bash
kubectl -n supabase create configmap edge-fn-orders \
  --from-file=path/to/orders/
```

Constraints:

- ConfigMap data keys are flat — Kubernetes does not allow `/` in keys, so
  no nested directories inside a single ConfigMap. Use multiple ConfigMaps
  to model a tree.
- ConfigMap size limit is 1 MiB (etcd). Sufficient for a typical function
  with helpers; heavier payloads should `deno vendor` and ship a custom
  edge-runtime image.
- ConfigMap name must be ≤ 60 chars: the chart prefixes the volume name
  with `fn-` (avoids collisions with the built-in `functions-main` and
  `deno-cache` volumes), and Kubernetes caps volume names at 63 chars.
- `files:` must list every key you want exposed to the runtime. Default is
  `[index.ts]`. Keys present in the ConfigMap but absent from `files:` are
  not mounted. Files listed in `files:` but missing from the ConfigMap
  fail the pod with a `MountVolume.SetUp failed` error — fix by adding
  the key to the ConfigMap or removing it from `files:`.

Why subPath mounts: edge-runtime bundles each function into
`/var/tmp/sb-compile-edge-runtime/<name>/` at boot and copies the source
files there without resolving symlinks. A directory-style ConfigMap mount
exposes files as symlinks (`index.ts → ..data/index.ts`), so the bundler
ends up with broken references. Per-file subPath mounts deliver the
ConfigMap content as plain files instead.

Restart semantics: changing the `extraConfigMaps` list rolls the Functions
and Studio Deployments automatically (Pod spec changes). Editing a
referenced ConfigMap **in place** does *not* propagate, because subPath
mounts are not hot-synced by kubelet. Run
`kubectl rollout restart deploy/<release>-supabase-functions` (and Studio,
if affected) to pick up in-place ConfigMap edits.

#### `hello` test fixture

`scripts/helm-deploy.sh` provisions a small `hello` function ad-hoc as part
of every local test deploy. It creates a ConfigMap named
`<release>-test-hello` from `scripts/fixtures/hello.ts` and references it
via `deployment.functions.extraConfigMaps[].mountPath: hello`, exercising
the same delivery path real users follow. The function echoes
`{"message":"Hello <name>!"}` for `POST /functions/v1/hello`:

```bash
curl -sS -X POST http://supabase.supabase.local/functions/v1/hello \
  -H 'Content-Type: application/json' \
  -d '{"name":"world"}'
```

## Horizontal Pod Autoscaling

Ten stateless services ship a `HorizontalPodAutoscaler` (autoscaling/v2):
`analytics`, `auth`, `functions`, `imgproxy`, `kong`, `meta`, `realtime`,
`rest`, `storage`, `vector`. Each is toggled independently:

```yaml
autoscaling:
  auth:
    enabled: true
    minReplicas: 1
    maxReplicas: 100
    targetCPUUtilizationPercentage: 80
    # targetMemoryUtilizationPercentage: 80   # optional, second metric
```

When `autoscaling.<svc>.enabled: true`, the corresponding Deployment omits
its `replicas` field so it does not fight the HPA. Disable autoscaling and
the Deployment falls back to `deployment.<svc>.replicaCount`.

`minio` and `studio` ship with `autoscaling.<svc>.enabled: false` by
default — MinIO is stateful (RWO PVC) and Studio is a low-traffic admin UI.
Flip them to `true` only if your workload actually warrants it.

## How to use in Production

Important points to consider:

- Run `cnpg.instances: 3` (primary + 2 standbys) for HA.
- Configure a backup `ObjectStore` (barman-cloud plugin) — this chart does not ship one.
- Add SSL to the Postgres cluster via CNPG's [TLS configuration](https://cloudnative-pg.io/documentation/current/certificates/).
- Add SSL to the Ingress endpoint via `cert-manager` or a LoadBalancer provider.
- Change the domain in `host:` to your real one.
- JWT material is generated automatically on first install; for production prefer to bring your own via `secret.jwt.existingSecret` from an external secret manager.
- Override `secret.*` with `existingSecret` for every block containing credentials — do not leave the inline defaults in production.

## Database bootstrap

CNPG runs `initdb` itself, so the `supabase/postgres` image's `docker-entrypoint-initdb.d/` scripts never execute — the baseline schemas, roles, and dbmate migrations that the image would normally apply are missing. The chart replays them via CNPG `bootstrap.initdb.postInitSQLRefs`.

The SQL is vendored under `files/db/`:

| File | Source | Loaded as |
|------|--------|-----------|
| `init.sql` | `supabase/postgres/migrations/db/init-scripts/*.sql` | ConfigMap key `00-init.sql` |
| `migrations.sql` | `supabase/postgres/migrations/db/migrations/*.sql` | ConfigMap key `01-migrations.sql` |

Both files are regenerated by `scripts/fetch-db-init.sh` (repo root, not inside the chart):

```bash
# Fetch for the current Chart.yaml appVersion
./scripts/fetch-db-init.sh

# Or pin a specific supabase/postgres release tag
./scripts/fetch-db-init.sh 17.6.1.108
```

**Rerun after every `Chart.yaml` `appVersion` bump** and commit the regenerated files.

### Skipped migrations

Some upstream migrations assume state the chart does not ship and are skipped (see `SKIP_MIGRATIONS` in `fetch-db-init.sh`):

- `10000000000000_demote-postgres` — strips SUPERUSER/BYPASSRLS from the `postgres` role; CNPG uses that role as the app superuser and can no longer reconcile `managed.roles` after it runs.
- `*_pgbouncer*` (three files) — reference a `pgbouncer` schema the base image pre-creates out-of-band. We do not ship that setup.

## Database Restore

The chart can restore a CNPG cluster from a barman-cloud backup stored in S3 (or any
other ObjectStore-compatible backend). When `cnpg.restore.enabled` is `true` the cluster
bootstraps via `bootstrap.recovery` instead of `bootstrap.initdb`, pointing CNPG at the
named `ObjectStore` CR through the `barman-cloud.cloudnative-pg.io` plugin.

> **Warning:** After the restore completes successfully, set `cnpg.restore.enabled` back
> to `false` and run `helm upgrade`. CNPG requires the `bootstrap.recovery` block to be
> removed from the `Cluster` CR before it will start new replicas or allow a primary
> promotion. Leaving it set to `true` prevents normal cluster operation.

### Simplest restore (latest backup)

Restore from the most recent backup in an existing `ObjectStore` named `supabase-db-backup`:

```yaml
cnpg:
  restore:
    enabled: true
    objectStoreName: "supabase-db-backup"
```

After `helm upgrade` with these values, CNPG will bootstrap the cluster from the latest
available backup. Once the cluster reaches `Ready`, set `enabled: false` and upgrade again.

### Point-in-Time Recovery (PITR)

Restore to a specific point in time:

```yaml
cnpg:
  restore:
    enabled: true
    objectStoreName: "supabase-db-backup"
    targetTime: "2024-01-15T10:30:00Z"
```

Other optional recovery targets:

| Field | Description |
|-------|-------------|
| `targetTime` | ISO 8601 timestamp — restore to this point in time |
| `targetLSN` | WAL Log Sequence Number — restore up to (and including) this LSN |
| `targetXID` | Transaction ID — restore up to (and including) this transaction |
| `backupName` | Name of a specific `Backup` CR to use as the base backup |

### ObjectStore name resolution

`cnpg.restore.objectStoreName` is resolved in priority order:

1. `cnpg.restore.objectStoreName` — explicit override (recommended)
2. `cnpg.backup.objectStore.existingName` — shared ObjectStore already used for backups
3. `<cnpg.clusterName>-backup` — the name the chart generates when `cnpg.backup.enabled=true`

If none of the three can be determined (all empty and `cnpg.backup.enabled=false`), the
chart fails with a clear error during `helm template` / `helm upgrade`.

### Restoring from a differently-named cluster

By default the chart uses `cnpg.clusterName` as the barman `serverName` — the name under
which barman stored the backup files in S3 (e.g. `s3://bucket/<serverName>/`). This is
correct when the source and destination clusters share the same name.

If the backup was created by a cluster with a **different** name, set `cnpg.restore.serverName`
explicitly:

```yaml
cnpg:
  clusterName: supabase-db        # new (destination) cluster name
  restore:
    enabled: true
    objectStoreName: "supabase-db-backup"
    serverName: "old-cluster-name"  # name of the cluster that created the backup
```

When `cnpg.restore.serverName` is left empty (the default), it falls back to `cnpg.clusterName`.

## Gateway API (alpha)

As an alternative to the Ingress resource, the chart can emit a Gateway API `HTTPRoute` pointing at Kong. This is **alpha** — CRDs must be pre-installed and a `Gateway` must exist in the cluster:

```yaml
ingress:
  enabled: false
gateway:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
      sectionName: https
```

`host:` at the top level is used for both the Ingress rule and the HTTPRoute `hostnames`.

## Troubleshooting

### Ingress Controller and Ingress Class

The default `ingress.className: ""` delegates to the cluster's default IngressClass. Set `className` explicitly for nginx / AGIC / Traefik, and add any controller-specific annotations:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
```

Kong's `/auth/v1/*` endpoints return 401 on unauthenticated health probes. For AGIC, this must be allow-listed so the backend is marked healthy:

```yaml
ingress:
  className: azure-application-gateway
  annotations:
    appgw.ingress.kubernetes.io/health-probe-status-codes: "200-499"
```

### Testing suite

Before creating a merge request, you can test the charts locally by using [helm/chart-testing](https://github.com/helm/chart-testing). If you have Docker and a Kubernetes environment to test with, simply run:

```shell
# Run chart-testing (lint)
docker run -it \
  --workdir=/data \
  --volume $(pwd)/charts/supabase:/data \
  quay.io/helmpack/chart-testing:v3.7.1 \
  ct lint --validate-maintainers=false --chart-dirs . --charts .
# Run chart-testing (install)
docker run -it \
  --network host \
  --workdir=/data \
  --volume ~/.kube/config:/root/.kube/config:ro \
  --volume $(pwd)/charts/supabase:/data \
  quay.io/helmpack/chart-testing:v3.7.1 \
  ct install --chart-dirs . --charts .
```

### CNPG cluster not bootstrapping

If the `supabase-db-1` pod stays in `Pending` or the CNPG `Cluster` CR never becomes `Ready`, check:

- The CNPG operator is installed and healthy (`kubectl get pods -n cnpg-system`).
- `files/db/init.sql` and `files/db/migrations.sql` exist and match `Chart.yaml` `appVersion`. Rerun `./scripts/fetch-db-init.sh` if needed.
- The pre-install `db-generator` Job has completed (`kubectl get jobs -l app.kubernetes.io/component=db-generator`). Without it, `managed.roles[*].passwordSecret` references point to missing Secrets.
