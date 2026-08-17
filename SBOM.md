# SBOM / Dependency-Track — Status & Preparation

This document is a **planning/status snapshot**, not an implemented feature.
Nothing described here is wired into any `Install.ps1` yet — it exists so we
have a shared picture of what's deployed, what an SBOM pipeline would need to
cover, and which decisions are still open before writing any code. Same
"speculative design, not yet implemented" role as [CERTIFICATES.md](CERTIFICATES.md)
for MQTT client certs.

Driver: CRA (Cyber Resilience Act) expects manufacturers to maintain and be
able to produce a Software Bill of Materials for products with digital
elements. Not one of the 13 ranked findings in the compliance report — a
parallel, self-initiated piece of work.

Known external fact: a Dependency-Track instance is already running
(location/URL/API key not yet shared — see [Open questions](#5-open-questions)).
Nothing in either repo or in memory currently references it; this would be a
net-new integration.

---

## 1. Scope

- **In scope**: every component in this repo (`Kubernetes.BaseLine`) and in
  the sibling `Kubernetes.Infra` repo (MQTT/Redis — app-specific infra that
  reuses this baseline's building blocks, per `ARCHITECTURE.md`'s "Out of
  scope" section).
- **Out of scope for now**: NAVIOS's own application images (`ordermanager`
  etc.) — same deferral the user already gave for compliance Finding #3
  ("die eigenen Produkte sind noch außen vor"). Can be revisited once cluster
  infrastructure is covered.

---

## 2. Inventory — Helm charts

### `Kubernetes.BaseLine`

| # | Component | Chart | Version | Repository |
|---|---|---|---|---|
| 11 | ingress-nginx | ingress-nginx | 4.15.1 | kubernetes.github.io/ingress-nginx |
| 11 | ingress-traefik | traefik | 39.0.8 | traefik.github.io/charts |
| 12 | metallb | metallb | 0.15.3 | metallb.github.io/metallb |
| 21 | longhorn | longhorn | 1.11.1 | charts.longhorn.io |
| 31 | cert-manager | cert-manager | v1.20.2 | charts.jetstack.io |
| 32 | secrets-csi-driver | secrets-store-csi-driver | 1.4.8 | kubernetes-sigs.github.io/secrets-store-csi-driver/charts |
| 33 | openbao | openbao | 0.27.2 | openbao.github.io/openbao-helm |
| 35 | authelia | authelia | 0.11.6 | charts.authelia.com |
| 41 | config-syncer | reflector | 7.1.288 | emberstack.github.io/helm-charts |
| 51 | rancher | rancher | 2.14.1 | releases.rancher.com/server-charts/stable |
| 61 | prometheus | kube-prometheus-stack | 83.7.0 | prometheus-community.github.io/helm-charts |
| 62 | loki | loki | 6.55.0 | grafana.github.io/helm-charts |
| 63 | promtail | promtail | 6.17.1 | grafana.github.io/helm-charts |
| 64 | tracing-jaeger | jaeger | 4.7.0 | jaegertracing.github.io/helm-charts |
| 64 | tracing-tempo | tempo-distributed | 1.61.3 | grafana.github.io/helm-charts |
| 65 | opentelemetry-collector | opentelemetry-collector | 0.152.0 | open-telemetry.github.io/opentelemetry-helm-charts |
| 66 | grafana | grafana | 10.5.15 | grafana.github.io/helm-charts |
| 91 | argocd | argo-cd | 9.5.4 | argoproj.github.io/argo-helm |
| 92 | minio | minio | 5.4.0 | charts.min.io |
| 93 | velero | velero | 12.1.0 | vmware-tanzu.github.io/helm-charts |

`kube-prometheus-stack`, `loki`, `velero` and similar umbrella charts each pull
in many *sub*-images (node-exporter, kube-state-metrics, alertmanager, csi
sidecars, etc.) that never appear as a version string in this repo's config —
see [§4](#4-declared-vs-actual-running-images) for why that matters.

### `Kubernetes.Infra`

| # | Component | Chart | Version | Repository |
|---|---|---|---|---|
| 10 | mqtt-emqx | emqx | 5.8.9 | repos.emqx.io/charts |
| 20 | redis | redis | 27.0.12 | oci://registry-1.docker.io/bitnamicharts/redis |

---

## 3. Inventory — non-chart / hardcoded images

These don't come from a Helm chart's own image defaults — they're pinned
directly in this repo's `Config.psd1`/`Install.ps1` files and need to be fed
into SBOM generation as plain image references, not chart lookups.

| Image | Where | Note |
|---|---|---|
| `curlimages/curl:8.21.0` | BaseLine `33-openbao/Install.ps1` (unsealer initContainer) | semver-pinned |
| `ghcr.io/bastienwirtz/homer:v24.05.1` | BaseLine `70-portal/Config.psd1` | semver-pinned |
| `alpine/k8s:1.31.4` | BaseLine `70-portal/Config.psd1` (sidecar) **and** Infra `21-redis-insight/Config.psd1` (sidecar) | **duplicate** — same image, two components |
| `minio/mc:latest` | BaseLine `92-minio/Install.ps1` | transient one-shot bucket-setup pod, not a running workload — floating tag acceptable here but flag if policy says otherwise |
| `velero/velero-plugin-for-aws:v1.13.1` | BaseLine `93-velero/Config.psd1` | semver-pinned |
| `bitnami/redis` pinned by digest `sha256:533fba5a...` | Infra `20-redis/Install.ps1` | chart's own `image.tag=latest` is broken (Bitnami no longer ships semver tags), digest-pinned per Finding #6 |
| `docker.io/library/busybox:1.36` | Infra `20-redis/Install.ps1` | |
| `busybox:1.36` | Infra `11-mqtt-explorer/Install.ps1` | **duplicate** of the line above, different repo-prefix string (`docker.io/library/` vs bare) — same image, should normalize to one reference before dedup-counting in DT |
| `ghcr.io/thomasnordquist/mqtt-explorer` @ `latest@sha256:319acc69...` | Infra `11-mqtt-explorer/Config.psd1` | digest-pinned per Finding #6, no upstream semver tags exist |
| `redis/redisinsight:2.70.1` | Infra `21-redis-insight/Config.psd1` | semver-pinned |

---

## 4. Special cases (don't fit the standard chart+version model)

- **`33-aws-secretsmanager` (BaseLine)** — installs the ASCP provider by
  applying an **unpinned upstream manifest** directly off `main`:
  `https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml`.
  There is no version string to record — whatever image tag is in `main` at
  install time is what runs. SBOM generation for this one needs a live image
  lookup (`kubectl get pods` after install), not a static Config.psd1 read.
  This is itself a compliance-relevant gap (floating `main`, same shape as the
  already-fixed Finding #6 `:latest` tags) worth a note even outside the SBOM
  effort.
- **`10-mqtt-mosquitto` (Infra)** — not a public chart at all. Custom-built
  image from `10-mqtt-mosquitto/image/Dockerfile` (`FROM eclipse-mosquitto:2`,
  + redis-cli/curl/bash/coreutils), deployed via the local
  `_charts/mosquitto-ha` chart. SBOM for this one must be generated **after
  the image is built**, from the built image itself — a chart/Config.psd1
  read won't reveal what's actually inside it (base image + added packages).

---

## 5. Declared vs. actual running images

Everything in §2/§3 is what this repo's config *declares*. It is not what's
*actually running* — Helm charts like `kube-prometheus-stack` or `loki`
deploy many sub-component images this repo never names directly, and those
sub-images have their own CVEs. For a compliance-grade SBOM (not just a
convenience inventory of what we hand-pin), the generation step should
enumerate the **live cluster's actual image set**:

```powershell
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | Sort-Object -Unique
```

...and generate one SBOM per unique image reference, rather than one per
Helm chart. This also naturally resolves the digest for anything only pinned
by a floating tag today, and catches the two special cases in §4 without
extra logic.

---

## 6. Proposed approach (not yet decided/implemented)

- **Generation tool**: [Syft](https://github.com/anchore/syft) — can scan an
  image reference directly (`syft <image> -o cyclonedx-json`) without a full
  registry pull-and-unpack step of our own, supports OCI, and outputs
  CycloneDX, which Dependency-Track ingests natively. Alternative considered:
  Trivy (combines SBOM + vuln scan) — redundant here since DT does its own
  vuln analysis (NVD/OSS Index/OSV) once a BOM is uploaded, so Syft's
  narrower single-purpose scan is the better fit.
- **Format**: CycloneDX JSON.
- **Ingestion**: Dependency-Track's `POST /api/v1/bom` (multipart or inline
  base64 BOM), header `X-Api-Key: <token>`, with `autoCreate=true` so
  first-time components self-register as DT projects.
- **Project mapping in DT**: one DT project per component (matching this
  repo's own component naming — e.g. `openbao`, `kube-prometheus-stack`,
  `mosquitto-ha`), `projectVersion` = chart version (or image tag/digest for
  the non-chart cases in §3/§4). Mirrors how compliance findings are already
  tracked per-component rather than per-cluster — better traceability than
  one giant aggregate BOM.
- **Automation shape**: a standalone script, run periodically or on demand —
  **not** wired into every `Install.ps1`. Reasoning: SBOM generation needs
  Syft + a DT API key available, which most component installs have no other
  reason to depend on, and it's a cluster-wide concern (live image inventory)
  rather than a per-component one. Same "kept separate, not baked into the
  numbered baseline" precedent as MQTT (`mqtt_separate_install` memory) —
  candidate shape: a root-level `Generate-Sbom.ps1` (or `96-sbom-scan` if it
  needs to run in-cluster as a CronJob rather than from an admin's machine).
- **Credential storage for the DT API key**: if/when this gets built, follow
  the existing least-privilege Vault pattern
  ([[feedback_vault_least_privilege]]) rather than a plaintext config value —
  needs its own scoped read-only path, not shared with anything else.

---

## 7. Open questions

Answers needed before any of §6 gets implemented:

1. Dependency-Track URL and API key — where does it run, is it reachable
   from inside the cluster (for a CronJob) or only from an admin workstation
   (script run manually / from CI)?
2. Should this become a permanent baseline component (`Config.psd1` +
   `Prompt.ps1` + `Install.ps1`, per [[feedback_config_install_prompt_pattern]])
   or stay a separate, non-baseline script like MQTT?
3. Declared-config inventory (fast, §2/§3) vs. live-cluster inventory
   (complete, §5) — or both, with live as the source of truth and
   declared-config as a manual cross-check?
4. Is `Kubernetes.Infra` in scope now, or deferred like NAVIOS's own product
   (Finding #3)? Current draft in §1 assumes in-scope, since it's platform
   infra rather than the product itself — confirm.
5. Project-naming convention in DT — per-component (recommended above) or
   per-cluster aggregate?
6. Should the `33-aws-secretsmanager` unpinned-`main` manifest and the
   `minio/mc:latest` transient image be flagged/fixed as their own
   compliance items (same shape as the already-fixed Finding #6), separately
   from the SBOM effort?
