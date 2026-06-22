# Changelog

All notable changes to this chart are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this chart adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Database restore via barman-cloud.** New `cnpg.restore` block in `values.yaml`
  enables bootstrapping the CNPG Cluster in `bootstrap.recovery` mode instead of
  `bootstrap.initdb`. When `cnpg.restore.enabled: true` the chart renders a
  `bootstrap.recovery` section pointing at the named ObjectStore and adds the
  corresponding `externalClusters` entry required by the barman-cloud plugin.
  Optional fields `targetTime`, `targetLSN`, `targetXID`, and `backupName` support
  Point-in-Time Recovery and selecting a specific backup. After a successful restore,
  set `cnpg.restore.enabled` back to `false` and run `helm upgrade` so CNPG returns
  to normal operation.

### Breaking

- **Bundled object storage replaced: MinIO → SeaweedFS.** The in-cluster S3
  backend now ships SeaweedFS 4.23 in single-node `weed mini` mode (one
  process — master, volume server, filer, S3 gateway). MinIO was dropped
  because the Community Edition was archived in February 2026 and is no
  longer maintained. Every `minio.*` values key is renamed to
  `s3.*` (`deployment.s3`, `image.s3`, `service.s3`, `persistence.s3`,
  `serviceAccount.s3`, `environment.s3`); the dedicated bundled-backend
  Secret is removed and consolidated into the existing `secret.s3` (fields
  `keyId` / `accessKey`, used both as Storage API S3 protocol creds and to
  authenticate against the bundled backend). The createbucket Job is gone
  — `weed mini` precreates buckets via the `S3_BUCKET` env (comma-separated
  list). Service port is now `8333` (was `9000`). Single-node only; for HA,
  leave `deployment.s3.enabled=false` and point
  `environment.storage.GLOBAL_S3_ENDPOINT` + `secret.s3.existingSecret` at
  an externally managed S3 cluster (e.g. SeaweedFS operator).
- **Public URL is no longer per-service.** `environment.auth.API_EXTERNAL_URL`,
  `environment.auth.GOTRUE_SITE_URL`, and `environment.studio.SUPABASE_PUBLIC_URL`
  are removed from `values.yaml`. All four public URLs (those three plus
  `STORAGE_PUBLIC_URL`) are now rendered from a single source via the
  `supabase.publicUrl` helper, which derives `http://`/`https://` from
  `tls.enabled` and the hostname from `host`. Set `publicUrl: <full-url>`
  to override (e.g. when API and frontend live on different hostnames).
- **Edge Functions delivery is now ConfigMap-only.** The
  `persistence.functions` PVC (RWO, 1 Gi, enabled by default) was a no-op —
  nothing in the chart wrote to it, and its RWO lock silently blocked the
  HPA from scaling Functions past one replica. The block is removed
  entirely. Users with `existingClaim` overrides must migrate their
  functions into ConfigMaps; see README "Custom edge functions".
- **Deno module cache is now `emptyDir`.** `persistence.deno` PVC removed.
  The cache lives for the pod lifetime and does not survive restarts;
  cold starts re-fetch modules. Acceptable for typical workloads. Heavy
  import graphs should `deno vendor`.
- **`deployment.functions.testFunction.enabled` removed.** The hello
  fixture is now provisioned automatically by the chart as a helm-test
  artefact (see *Added* below) and gated by `tests.functions.enabled`
  (default `false`). Set it to `true` to surface the fixture ConfigMap,
  the `/hello` mount in the Functions Deployment, and the helm-test Job.
- **Studio's edge-function browser now reads `deployment.functions.extraConfigMaps`.**
  Previously gated by `persistence.functions.enabled`, it now mounts each
  declared file from `extraConfigMaps` read-only into the Studio pod.
  `EDGE_FUNCTIONS_MANAGEMENT_FOLDER` is set unconditionally on Studio so
  recent versions don't crash on the assertion at startup.

### Added

- `deployment.functions.extraConfigMaps` — list of out-of-band ConfigMaps
  surfaced as plain files under `/home/deno/functions/<mountPath>/`.
  Schema: `{name: <configmap-name>, mountPath: <relative-dir>, files:
  [<key>, ...]}`. `files` defaults to `[index.ts]`; multi-file functions
  must list every key explicitly. Each declared file is mounted via
  `subPath` so edge-runtime sees real files instead of the symlinks a
  directory-style ConfigMap mount would expose (the bundler in
  `/var/tmp/sb-compile-edge-runtime/` cannot follow them). Volume name
  is `fn-<configmap-name>` (≤ 60 chars to stay under Kubernetes' 63-char
  volume name cap). Studio dispatches the same list (`readOnly: true`)
  so the dashboard can list deployed functions.
- `tests.functions.enabled` — top-level toggle for the chart-managed
  hello fixture: gates the fixture ConfigMap, the `/hello` mount in the
  Functions Deployment, and the `helm test` Job in one place. Default
  `false`.
- `templates/test/functions-fixture.configmap.yaml` — chart-managed
  fixture ConfigMap (`{{ .Chart.Name }}-test-hello`) sourced from
  `files/test/hello.ts`. Gated by `tests.functions.enabled`.
- `templates/test/functions.yaml` — `helm test` hook that POSTs to
  `/functions/v1/hello` and asserts the response body. Same gating;
  runs automatically on `helm test` (and through `ct install`) whenever
  `tests.functions.enabled` is on.
- `templates/s3/test.yaml` — `helm test` hook that probes the bundled
  SeaweedFS S3 endpoint. Gated by `deployment.s3.enabled`.
- `charts/supabase/ci/with-extra-functions.yaml` — second CI values file
  that activates the fixture so chart-testing exercises the
  `extraConfigMaps` flow end-to-end (the existing `ci/example.yaml`
  continues to cover the no-extras path).

### Changed

- `helm-deploy.sh` enables the chart-managed hello fixture by setting
  `tests.functions.enabled=true` in its defaults block. The fixture
  source of truth is `charts/supabase/files/test/hello.ts`. The script
  also pre-creates the Storage bucket (and, with `--backup`, the backup
  bucket) by feeding `environment.s3.S3_BUCKET` to `weed mini` —
  replacing the previous explicit createbucket Job.
- All `templates/test/*.yaml` jobs migrated from the third-party
  `kdevup/curljq` image to the official `curlimages/curl:8.20.0`
  (pinned). Shell switched from `/bin/bash` to `/bin/sh` (POSIX,
  available in the alpine-based curl image). No `jq` dependency — the
  one new test (`functions.yaml`) asserts the response body with `grep`.

### Removed

- `templates/functions/test-function.configmap.yaml` (replaced by
  `templates/test/functions-fixture.configmap.yaml`).
- PVC entries for `functions` and `deno` in `templates/persistence.yaml`
  and the corresponding `persistence.functions` / `persistence.deno`
  blocks in `values.yaml`.

## [0.7.0]

### Breaking

- **Rename `secret.<component>.secretRef` → `secret.<component>.existingSecret`**
  across `secret.jwt`, `secret.analytics`, `secret.bigquery`, `secret.smtp`,
  `secret.dashboard`, `secret.s3`, `secret.realtime`, `secret.meta`,
  `secret.minio`. Default changed from `""` to `null`.
- **Rename `secret.<component>.secretRefKey` → `secret.<component>.existingSecretKey`.**
  Previously commented-out example map is now a populated default
  (e.g. `{anonKey: anonKey, serviceKey: serviceKey, secret: secret}`), so
  referencing an external Secret with the canonical key names no longer
  requires touching this block.
- **ServiceAccount consolidation.** By default, all Supabase services now
  share a single ServiceAccount named `<fullname>` rendered from the new
  top-level `serviceAccount.{create,name,annotations}`. The 11 per-service
  blocks (`serviceAccount.auth`, `.rest`, `.studio`, `.meta`, `.storage`,
  `.kong`, `.minio`, `.realtime`, `.functions`, `.analytics`, `.imgproxy`)
  now default to `{}` and fall back to the shared SA. Set a service's
  `create: true` (or `name: <existing-sa>`) to opt into a dedicated SA —
  required for IRSA / Azure Workload Identity scenarios where a specific
  service needs its own cloud identity. `serviceAccount.vector` still
  defaults to `create: true` to keep its `pods/log` ClusterRoleBinding from
  leaking to unrelated pods.

### Added

- `cnpg.serviceAccountTemplate.{annotations,labels}` — annotations/labels
  applied to the ServiceAccount CNPG creates for the Postgres pods (IRSA /
  Workload Identity for the barman-cloud plugin).
- `OPENAI_API_KEY` in the Studio Deployment is now declared as
  `secretKeyRef.optional: true`, so bring-your-own `secret.dashboard.existingSecret`
  without an `openAiApiKey` entry no longer blocks Studio startup.
- `deployment.<svc>.extraEnv` on every service (analytics, auth, functions,
  imgproxy, kong, meta, minio, realtime, rest, storage, studio, vector) —
  a raw list of container env entries appended to the pod's `env:`. Intended
  for `valueFrom` injection (secret/configmap keys, field refs) so sensitive
  values stay out of `values.yaml`. Plain literals still belong in
  `environment.<svc>`. Primary use case: wiring GoTrue external OAuth
  providers (`GOTRUE_EXTERNAL_<PROVIDER>_CLIENT_ID` / `_SECRET`) via
  `secretKeyRef` without chart changes.
- `HorizontalPodAutoscaler` resources for the ten stateless services
  (analytics, auth, functions, imgproxy, kong, meta, realtime, rest, storage,
  vector). Toggled per service via `autoscaling.<svc>.enabled` with
  `minReplicas`, `maxReplicas`, `targetCPUUtilizationPercentage`, and an
  optional `targetMemoryUtilizationPercentage`. When HPA is on, the
  Deployment omits `replicas` so it does not fight the autoscaler.
- `USER_WORKER_MEMORY_LIMIT_MB`, `USER_WORKER_TIMEOUT_MS`,
  `USER_WORKER_NO_MODULE_CACHE` defaults under `environment.functions`,
  consumed by `files/functions/index.ts` to tune `EdgeRuntime.userWorkers.create`
  per-deployment without editing the shipped script.
- `deployment.functions.testFunction.enabled` (default `false`) — mounts a
  `hello` fixture function at `/home/deno/functions/hello/index.ts` from
  `files/functions/test/hello.ts` via a ConfigMap subPath. Reachable at
  `POST /functions/v1/hello {"name":"<x>"}`. `scripts/helm-deploy.sh` enables
  it for local test deploys.

### Fixed

- Setting `secret.<component>.existingSecret` no longer fails template
  rendering with `nil pointer evaluating interface {}.<key>`. The previous
  default of a commented-out `secretRefKey` map meant any path that
  dereferenced it (e.g. `.existingSecretKey.anonKey | default "anonKey"`)
  panicked before the `| default` pipe could take effect.
- Studio pg-meta `CRYPTO_KEY` env var: add missing `| default "cryptoKey"`
  in `templates/meta/deployment.yaml` so a custom `existingSecretKey` that
  omits `cryptoKey` falls back to the canonical key name instead of
  rendering an empty `key:`.

### Changed

- `credentials-generator` no longer unconditionally writes an
  `openAiApiKey` entry to the generated dashboard Secret. The key is
  written only when `secret.dashboard.openAiApiKey` is non-empty. Combined
  with `optional: true` on Studio's envFrom, Pods start fine whether or not
  the key exists.
- The three credential-generator Jobs (`jwt-generator`, `db-generator`,
  `credentials-generator`) now share a single pre-install ServiceAccount +
  Role + RoleBinding (`<fullname>-generator`) instead of provisioning one
  set each. Net: 6 fewer RBAC resources per release.
- Kong, Vector and Edge Functions ConfigMap bodies moved out of the
  templates into `files/kong/{kong-entrypoint.sh,temp.yml}`,
  `files/vector/vector.yml` and `files/functions/index.ts`, loaded via
  `tpl (.Files.Get …) .`. Pure refactor — rendered ConfigMap data is
  byte-identical. Pattern mirrors upstream
  [supabase-community/supabase-kubernetes@f331cb4](https://github.com/supabase-community/supabase-kubernetes/commit/f331cb4f2fdab234f966fdc3e882f8565a81ab58).
- `image.functions.tag`: `v1.71.2` → `v1.74.0` (supabase/edge-runtime).
- `image.studio.tag`: `2026.04.08-sha-205cbe7` → `2026.04.27-sha-5f60601`.
- `autoscaling.minio.enabled` and `autoscaling.studio.enabled` now default
  to `false`. MinIO is stateful (RWO PVC); Studio is a low-traffic admin UI.
  Set them back to `true` if your environment justifies it.
- `files/functions/index.ts` no longer hardcodes worker memory/timeout/
  module-cache. The three knobs are read from env vars
  (`USER_WORKER_MEMORY_LIMIT_MB`, `USER_WORKER_TIMEOUT_MS`,
  `USER_WORKER_NO_MODULE_CACHE`) whose defaults live in
  `values.yaml: environment.functions`. Override per environment via
  `--set environment.functions.USER_WORKER_MEMORY_LIMIT_MB=512` etc.

### Migration

If you previously referenced an external Secret via `secretRef`:

```yaml
# before
secret:
  jwt:
    secretRef: my-supabase-jwt
    secretRefKey:
      anonKey: ANON_KEY   # custom mapping

# after
secret:
  jwt:
    existingSecret: my-supabase-jwt
    existingSecretKey:
      anonKey: ANON_KEY
```

If you previously customized a per-service ServiceAccount (annotations
for IRSA / Workload Identity):

```yaml
# before — implicit `create: true`
serviceAccount:
  storage:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123:role/storage

# after — must set `create: true` explicitly
serviceAccount:
  storage:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123:role/storage
```

## [0.6.0]

- Add support for backups via Barman Cloud (CNPG plugin).
- Initial CNPG-native release following the fork from supabase-community.
