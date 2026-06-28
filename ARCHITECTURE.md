# Architecture — Components & Communication

This document shows the components installed by `Install-Base.ps1`, how they
communicate with each other, and how a few representative calls travel
through the cluster.

> Diagrams are embedded as [Mermaid](https://mermaid.js.org/). VS Code
> (Markdown Preview), GitHub, and most Markdown renderers display them directly
> as graphics.

Application-specific infrastructure that isn't part of this baseline (MQTT,
Redis, ...) is intentionally out of scope here — see the note at the bottom.

---

## 1. Overview — Components & Communication Paths

```mermaid
flowchart TB
    Internet["🌐 Internet / external client"] --> DNS["DNS (*.kubernetes.local)"]
    DNS --> IngressLB["LoadBalancer :80 / :443"]
    IngressLB --> Ingress["Ingress Controller\n(NGINX or Traefik)"]

    CertMgr["cert-manager"]
    Vault["Vault\nOpenBao (RKE2/Kind) or cloud-native KV\nKV-v2 secrets + PKI root CA"]
    Authelia["Authelia\nForward-auth gateway + OIDC Provider"]
    Longhorn["Longhorn\n(Storage)"]

    Ingress -- "TLS, host routing" --> Longhorn
    Ingress -- "forward-auth check" --> Authelia
    Vault -- "PKI: sign per-hostname certs\n(ClusterIssuer: openbao-pki)" --> CertMgr
    CertMgr -- "issue + auto-renew" --> Ingress
    Vault -- "secrets (CSI mount)" --> Authelia
    Authelia -- "forward-auth: allow/deny" --> Longhorn

    subgraph OPT["Optional — selected per install run"]
        direction TB
        ConfigMgmt["Configuration Management\nRegistry credentials + Proxy config"]
        Rancher["Rancher\n(SSO via Authelia OIDC)"]
        Observability["Observability Stack\nPrometheus / Loki / Promtail /\nTracing / OTel / Grafana"]
        Utilities["Utilities\nArgoCD (GitOps) + Velero/MinIO (Backup)"]
    end

    Ingress --> Rancher
    Ingress --> Observability
    Ingress --> Utilities
    Vault -- "secrets" --> ConfigMgmt
    Authelia -- "OIDC" --> Rancher
    Authelia -- "forward-auth" --> Observability
    Utilities -- "backs up" --> Longhorn
```

**How to read this**

- All **HTTP/HTTPS UIs** run behind the same Ingress Controller → one
  LoadBalancer IP, host-based routing, TLS from `cert-manager`.
- **Authelia plays two distinct roles**: it's a **forward-auth gateway** for
  apps with no login of their own (Longhorn, and Prometheus/Jaeger inside the
  Observability Stack), and a full **OIDC Provider** for apps that integrate
  properly (currently Rancher; more clients can register the same way via
  `Register-AutheliaOidcClient`).
- **Ingress, cert-manager, Vault, Authelia, Longhorn are always installed** —
  every other box is a separate, individually-selectable part of the install
  run and may not be present in a given cluster.
- Section 5's table has the per-component detail (ports, namespaces,
  individual optionality) that this overview deliberately leaves out.

---

## 2. Call example 1 — Forward-auth protected app (Longhorn / Prometheus / Jaeger)

```mermaid
sequenceDiagram
    participant U as Browser (external)
    participant ING as Ingress Controller
    participant AUTH as Authelia (forward-auth)
    participant SVC as Protected app (e.g. Longhorn UI)

    U->>ING: HTTPS GET (Host: storage.kubernetes.local)
    ING->>AUTH: subrequest — auth_request /api/verify
    alt no valid session
        AUTH-->>ING: 401
        ING-->>U: redirect to Authelia login
        U->>AUTH: credentials (1FA)
        AUTH-->>U: session cookie, redirect back
        U->>ING: retry original request (with cookie)
        ING->>AUTH: subrequest — auth_request /api/verify
    end
    AUTH-->>ING: 200 (authenticated)
    ING->>SVC: forward HTTP (ClusterIP)
    SVC-->>ING: response
    ING-->>U: HTTPS response
```

The app itself (Longhorn, Prometheus, Jaeger) never sees an unauthenticated
request — nginx's `auth_request` directive blocks it at the Ingress layer
before it ever reaches the backend Service.

---

## 3. Call example 2 — Rancher SSO via Authelia (OIDC)

```mermaid
sequenceDiagram
    participant U as Browser
    participant RAN as Rancher
    participant AUTH as Authelia (OIDC Provider)

    U->>RAN: click "Login with OIDC"
    RAN->>U: redirect to Authelia /api/oidc/authorization
    U->>AUTH: authorization request (scope, client_id=rancher)
    AUTH->>U: login form (if no session) + consent screen
    U->>AUTH: credentials + consent
    AUTH-->>U: redirect to Rancher /verify-auth with code
    U->>RAN: GET /verify-auth?code=...
    RAN->>AUTH: POST /api/oidc/token (server-to-server,\nclient_id + client_secret)
    AUTH-->>RAN: id_token + access_token + refresh_token
    RAN->>AUTH: GET /api/oidc/userinfo
    AUTH-->>RAN: claims incl. groups: [admins]
    Note over RAN: GlobalRoleBinding maps\noidc_group://admins → admin role
    RAN-->>U: logged in, full cluster access
```

Rancher's OIDC client (`client_id=rancher`) is registered against Authelia by
`51-rancher/Install.ps1` via the shared `Register-AutheliaOidcClient` helper
in `_lib/Installer.Ui.psm1` — the same mechanism any future OIDC client
(e.g. Grafana) would reuse. The `groups` claim is what drives Rancher's
authorization: a `GlobalRoleBinding` with `groupPrincipalName:
oidc_group://admins` grants the `admin` role to anyone Authelia reports as a
member of the `admins` group, with no manual per-user grant needed.

---

## 4. Call example 3 — Scheduled backup (Velero)

```mermaid
sequenceDiagram
    participant CRON as Velero Schedule (cron)
    participant VEL as Velero
    participant K8S as Kubernetes API
    participant CSI as Longhorn CSI driver
    participant MIN as MinIO (S3)

    CRON->>VEL: trigger Backup (per schedule.spec.schedule)
    VEL->>K8S: list & export cluster resources (manifests)
    VEL->>CSI: create VolumeSnapshot (per PVC, via VolumeSnapshotClass)
    CSI-->>VEL: VolumeSnapshotContent ready
    VEL->>VEL: node-agent moves snapshot data\n(kopia uploader, snapshotMoveData: true)
    VEL->>MIN: upload backup (resources + volume data) to bucket
    MIN-->>VEL: upload complete
    VEL->>K8S: Backup status = Completed
```

Two things travel into MinIO per backup: the **resource manifests** (every
object in the cluster, the same data `kubectl get -A -o yaml` would show) and
the **volume data** (moved out of Longhorn's snapshot via Velero's built-in
CSI data-movement, not just a metadata-only snapshot reference — so a backup
survives losing the storage cluster itself, not only an accidental `kubectl
delete`).

---

## 5. Namespace & port overview

| Namespace | Component | Port(s) | Externally reachable? |
|---|---|---|---|
| `ingress-nginx` / `traefik` | Ingress Controller | 80, 443 | ✅ LoadBalancer (`ingress-pool`) |
| `cert-manager` | cert-manager | – | ❌ internal |
| `openbao` (RKE2/Kind) or cloud-native KV | Vault (+ PKI root CA on RKE2/Kind) | 8200 | optional via Ingress |
| `authelia` | Authelia (forward-auth + OIDC Provider) | 9091 | ✅ via Ingress |
| `kube-system` | Secrets Store CSI driver, Reflector | – | ❌ internal |
| `registry` / `proxy-config` | Private Registry credentials, Proxy Configuration | – | ❌ internal |
| `longhorn-system` | Longhorn | 80 (UI) | optional via Ingress, forward-auth via Authelia |
| `cattle-system` | Rancher | 80/443 | ✅ via Ingress, SSO via Authelia OIDC |
| `monitoring` | Prometheus, Loki, Promtail, Tempo/Jaeger, OTel, Grafana | 9090, 3100, 4317/4318, 3200/16686, 3000 | Grafana optional via Ingress (own login); Prometheus/Jaeger optional via Ingress (forward-auth); rest internal |
| `argocd` | ArgoCD | 8080 | ✅ via Ingress (optional) |
| `minio` | MinIO (Velero's backup target) | 9000 | ❌ internal only (RKE2/Kind only) |
| `velero` | Velero | – | ❌ internal (operated via `velero` CLI / `kubectl`) |

---

## Out of scope

This baseline only covers cluster-wide infrastructure (ingress, secrets,
storage, observability, GitOps, backup). Application-specific infrastructure
— **MQTT**, **Redis**, or anything else a workload needs — belongs in a
separate install script/repo that builds on a cluster this baseline already
provisioned, reusing its building blocks (Ingress/MetalLB pools, cert-manager,
Vault/OpenBao, Authelia) instead of duplicating them.

A detailed speculative design for one such case (MQTT client mTLS via
OpenBao PKI) exists in [CERTIFICATES.md](CERTIFICATES.md) — it predates this
revision and is **not implemented**, kept only as a reference for whenever
that work actually starts.
