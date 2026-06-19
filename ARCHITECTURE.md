# Architektur — Komponenten & Kommunikation

Dieses Dokument zeigt die von `Install-Base.ps1` installierten Komponenten, wie sie
untereinander kommunizieren, wie ein eingehender Aufruf durch den Cluster läuft —
und wie sich **MQTT** als zusätzliche Komponente einfügen würde (sowohl intern als
auch von außerhalb des Clusters erreichbar).

> Die Diagramme sind als [Mermaid](https://mermaid.js.org/) eingebettet. In VS Code
> (Markdown-Preview), GitHub und den meisten Markdown-Renderern werden sie direkt als
> Grafik dargestellt.

---

## 1. Gesamtübersicht — Komponenten & Kommunikationswege

```mermaid
flowchart TB
    Internet["🌐 Internet / externer Client"]
    DNS["DNS (*.kubernetes.local)"]

    Internet --> DNS

    subgraph LB["Externe Erreichbarkeit (MetalLB-Pools / Cloud-LB)"]
        IngressLB["LoadBalancer :80 / :443\n(Pool: ingress-pool)"]
        MqttLB["LoadBalancer :1883 / :8883\n(Pool: default-pool)"]
    end

    DNS --> IngressLB

    subgraph NS_ING["ns: ingress-nginx / traefik"]
        Ingress["Ingress Controller\n(NGINX oder Traefik)"]
    end

    subgraph NS_CERT["ns: cert-manager"]
        CertMgr["cert-manager"]
    end

    subgraph NS_VAULT["ns: openbao"]
        Vault["OpenBao :8200\n(Secrets / Wildcard-Cert)"]
    end

    subgraph NS_ESO["ns: external-secrets / kube-system"]
        ESO["External Secrets Operator"]
        CSI["Secrets Store CSI Driver"]
        Reflector["Reflector (Config-Syncer)"]
    end

    subgraph NS_MON["ns: monitoring"]
        Prom["Prometheus :9090"]
        Loki["Loki :3100"]
        Promtail["Promtail (DaemonSet)"]
        Otel["OTel Collector :4317/:4318"]
        Tempo["Tempo :4317 / :3200"]
        Jaeger["Jaeger :4317 / :16686"]
        Grafana["Grafana :3000"]
    end

    subgraph NS_MGMT["ns: cattle-system / argocd"]
        Rancher["Rancher"]
        ArgoCD["ArgoCD Server :8080"]
    end

    subgraph NS_STORE["ns: longhorn-system"]
        Longhorn["Longhorn"]
    end

    subgraph NS_MQTT["ns: mqtt (NEU)"]
        MqttBroker["MQTT-Broker\n(z. B. EMQX / Mosquitto)\n:1883 plain · :8883 TLS"]
    end

    IngressLB --> Ingress
    Ingress -- "TLS-Terminierung,\nHost-Routing" --> Grafana
    Ingress --> Rancher
    Ingress --> ArgoCD
    Ingress --> Longhorn
    Ingress --> Vault

    CertMgr -- "Zertifikate ausstellen" --> Ingress
    Vault -- "Wildcard-Cert" --> ESO
    ESO -- "sync → K8s Secret" --> Ingress
    ESO -- "sync → K8s Secret" --> MqttBroker
    CSI -- "mount Secret" --> Grafana
    Reflector -- "ConfigMap/Secret-Spiegelung" --> NS_MON
    Reflector -- "ConfigMap/Secret-Spiegelung" --> NS_MQTT

    Promtail --> Loki
    Otel -- "remote_write" --> Prom
    Otel -- "OTLP logs" --> Loki
    Otel -- "OTLP traces" --> Tempo
    Otel -- "OTLP traces" --> Jaeger
    Grafana -- "Query" --> Prom
    Grafana -- "Query" --> Loki
    Grafana -- "Query" --> Tempo
    Grafana -- "Query" --> Jaeger

    ArgoCD -- "Deploy/Reconcile" --> NS_MQTT
    ArgoCD -- "Deploy/Reconcile" --> NS_MON

    MqttLB -- "extern: Geräte/IoT/Clients" --> MqttBroker
    MqttBroker -- "ClusterIP intern:\nmqtt-broker.mqtt:1883" --> NS_MON
    MqttBroker -. "Metriken (optional)" .-> Otel

    Internet -. "MQTT-Client (TCP)" .-> MqttLB
```

**Lesehinweise**

- Alle **HTTP/HTTPS-UIs** (Grafana, Rancher, ArgoCD, Longhorn, OpenBao) laufen über
  denselben Ingress-Controller → eine LoadBalancer-IP, Host-basiertes Routing,
  TLS von `cert-manager`.
- **MQTT ist kein HTTP-Protokoll** und kann daher nicht über den HTTP-Ingress laufen.
  Es bekommt einen **eigenen LoadBalancer-Service** (eigene externe IP, Pool
  `default-pool`) — analog zum bisherigen Muster, bei dem MetalLB schon zwei Pools
  vorsieht (`ingress-pool` für HTTP, `default-pool` für alles andere).
- Intern ist der Broker ganz normal per ClusterIP/DNS erreichbar
  (`mqtt-broker.mqtt.svc.cluster.local:1883`), genau wie Prometheus oder Loki.

---

## 2. Aufruf-Beispiel 1 — Browser ruft Grafana auf (HTTPS via Ingress)

```mermaid
sequenceDiagram
    participant U as Browser (extern)
    participant D as DNS
    participant LB as LoadBalancer :443
    participant ING as Ingress Controller
    participant CM as cert-manager
    participant SVC as Service grafana.monitoring:3000
    participant POD as Grafana Pod

    U->>D: grafana.kubernetes.local ?
    D-->>U: externe IP des Ingress-LB
    U->>LB: HTTPS GET (Host: grafana.kubernetes.local)
    LB->>ING: TCP :443 weiterleiten
    Note over ING,CM: TLS-Zertifikat von cert-manager\n(Wildcard, via Vault + ESO synchronisiert)
    ING->>ING: TLS terminieren, Host-Header prüfen
    ING->>SVC: HTTP weiterleiten (ClusterIP)
    SVC->>POD: an Grafana-Pod weiterleiten
    POD-->>SVC: Response
    SVC-->>ING: Response
    ING-->>U: HTTPS Response
```

---

## 3. Aufruf-Beispiel 2 — MQTT-Client (intern *und* extern)

```mermaid
sequenceDiagram
    participant EXT as Externes Gerät (z. B. IoT-Sensor)
    participant LB as LoadBalancer :8883 (default-pool)
    participant BRK as MQTT-Broker Pod (mqtt ns)
    participant POD as interner Subscriber (z. B. App-Pod)

    EXT->>LB: MQTT CONNECT (TLS, Port 8883)
    LB->>BRK: TCP weiterleiten (kein HTTP-Ingress nötig)
    BRK-->>EXT: CONNACK
    EXT->>BRK: PUBLISH sensors/temp 21.5
    BRK->>POD: PUBLISH (Subscriber via ClusterIP\nmqtt-broker.mqtt.svc.cluster.local:1883)
    POD-->>BRK: SUBACK / weitere Verarbeitung
```

**Zwei Zugriffspfade auf denselben Broker:**

| Aufrufer | Adresse | Port | Weg |
|---|---|---|---|
| Pod **innerhalb** des Clusters | `mqtt-broker.mqtt.svc.cluster.local` | `1883` (plain) | ClusterIP, kein Sprung über LB |
| Client **außerhalb** des Clusters | öffentliche/MetalLB-IP des `mqtt`-LoadBalancer-Service | `8883` (TLS) | LoadBalancer-Service direkt auf den Broker, **ohne** HTTP-Ingress |

TLS für `8883` nutzt dasselbe Wildcard-Zertifikat wie die übrigen Komponenten
(Vault → External Secrets Operator → K8s-Secret im `mqtt`-Namespace).

---

## 4. Namespace- und Port-Übersicht (inkl. MQTT)

| Namespace | Komponente | Port(s) | Extern erreichbar? |
|---|---|---|---|
| `ingress-nginx` / `traefik` | Ingress Controller | 80, 443 | ✅ LoadBalancer (`ingress-pool`) |
| `cert-manager` | cert-manager | – | ❌ intern |
| `openbao` | OpenBao (Vault) | 8200 | optional über Ingress |
| `external-secrets` / `kube-system` | ESO, CSI-Driver, Reflector | – | ❌ intern |
| `longhorn-system` | Longhorn | 80 (UI) | optional über Ingress |
| `cattle-system` | Rancher | 80/443 | ✅ über Ingress |
| `monitoring` | Prometheus, Loki, Tempo/Jaeger, OTel, Grafana | 9090, 3100, 4317/4318, 3200/16686, 3000 | Grafana/Prometheus/Jaeger optional über Ingress, Rest intern |
| `argocd` | ArgoCD | 8080 | ✅ über Ingress (optional) |
| **`mqtt` (neu)** | **MQTT-Broker** | **1883 (plain, intern), 8883 (TLS, intern+extern)** | **✅ eigener LoadBalancer (`default-pool`), zusätzlich ClusterIP intern** |

---

## 5. Wie würde MQTT als Komponente eingebaut werden?

**Entscheidung:** MQTT wird **nicht** Teil dieser Baseline (kein `72-mqtt` in diesem
Repo). Diese Baseline deckt nur clusterweite Infrastruktur ab (Ingress, Secrets,
Storage, Observability, GitOps) — MQTT ist anwendungsspezifisch und gehört in ein
**separates Install-Skript/Repo**, das auf einem bereits per Baseline aufgesetzten
Cluster aufbaut.

Das separate Skript würde dieselben Bausteine wiederverwenden, die die Baseline
bereitstellt, statt sie zu duplizieren:

- **Namespace**: eigener (z. B. `mqtt`), nicht Teil der Baseline-Namespaces
- **Helm-Chart**: z. B. `emqx/emqx` oder `bitnami/mosquitto`
- **Service 1 (intern)**: `ClusterIP`, Port `1883` — für Pods im Cluster
- **Service 2 (extern)**: `LoadBalancer`, Port `8883` (TLS), Annotation
  `metallb.universe.tf/address-pool: default-pool` — nutzt den von der Baseline
  bereits angelegten MetalLB-Pool, statt den HTTP-Ingress zu missbrauchen
- **TLS**: Wildcard-Zertifikat, das bereits über Vault + External-Secrets-Operator
  (Baseline-Komponenten) verteilt wird — nur zusätzlich in den `mqtt`-Namespace
  synchronisiert

Das Diagramm oben zeigt den Zielzustand konzeptionell. Die tatsächliche Umsetzung
(eigenes Skript/Repo) folgt später.
