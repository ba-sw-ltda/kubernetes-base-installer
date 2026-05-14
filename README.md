# Kubernetes Base Installer

A PowerShell-based, fully automated base stack installer for Kubernetes clusters.  
Supports **AKS · EKS · GKE · RKE2 (On-Premise) · Kind (Local)** from a single codebase.

---

## What it does

`Install-Base.ps1` sets up a production-ready Kubernetes cluster with:

| # | Component | Notes |
|---|---|---|
| 11 | **Ingress** (NGINX or Traefik) | Auto-selects between controllers |
| 12 | **MetalLB** | On-premise / Kind only |
| 21 | **cert-manager** | TLS certificate management |
| 22 | **External Secrets Operator** | Sync secrets from vault to K8s |
| 22 | **Secrets Store CSI Driver** | Mount secrets directly into pods |
| 23 | **Vault** (OpenBao / Azure Key Vault / AWS Secrets Manager / GCP Secret Manager) | Platform-native |
| 24 | **Wildcard TLS Certificate** | PFX import → Vault → ESO → K8s Secret |
| 31 | **Longhorn** | Distributed block storage (on-premise) |
| 41 | **Config Syncer (Reflector)** | Sync ConfigMaps/Secrets across namespaces |
| 43 | **Private Registry** | imagePullSecrets via Reflector |
| 51 | **Rancher** | Cluster management UI |
| 61–66 | **Observability Stack** | Prometheus · Loki · Promtail · Tempo/Jaeger · OTel · Grafana |
| 70 | **ArgoCD** | GitOps |

All inputs are collected **upfront** before any installation starts.  
No prompts mid-install. No manual `kubectl` commands required.

---

## Requirements

- **PowerShell 7+** (pwsh)
- **kubectl** and **helm** (auto-installed if missing)
- Platform CLI for cloud targets: `az` / `aws` + `eksctl` / `gcloud`
- SSH access to RKE2 control-plane node (on-premise)

---

## Quick Start

```powershell
git clone https://github.com/ba-sw-ltda/kubernetes-base-installer
cd kubernetes-base-installer
.\Install-Base.ps1
```

Follow the interactive prompts — group selection, then component selection and configuration per group, then installation.

---

## Other scripts

| Script | Purpose |
|---|---|
| `Reset-RKE2.ps1` | Remove the entire stack from an RKE2 cluster (cluster stays intact) |
| `Reset-AKS.ps1` / `Reset-EKS.ps1` / `Reset-GKE.ps1` | Delete cloud cluster and clean up resources |
| `Verify-RKE2.ps1` | Verify a clean reset — lists any remaining resources |
| `Rotate-Secret.ps1` | Rotate a secret in the vault and restart affected workloads |
| `Rotate-Cert.ps1` | Replace the wildcard TLS certificate (PFX → Vault → auto-sync) |

---

## State files

The scripts write `.json` state files (cluster connection details, tokens) to the project root.  
These are listed in `.gitignore` and **must not be committed**.

---

## License

MIT License — Copyright (c) 2026 BA Software LTDA

Provided **as-is**, without warranty of any kind.  
See [LICENSE](LICENSE) for full terms.

---

> **Distribution:** GitHub only — https://github.com/ba-sw-ltda/kubernetes-base-installer
