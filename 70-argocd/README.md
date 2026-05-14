# 70 - ArgoCD

## Overview
ArgoCD is a declarative, GitOps continuous delivery tool for Kubernetes. It enables automated deployment of applications following GitOps methodology.

## Components
- argocd-server (API server and UI)
- argocd-repo-server (Git repository access)
- argocd-application-controller (Application management)
- argocd-dex-server (Authentication service)

## Installation
```powershell
.\Install.ps1 -Platform <platform>
```

## Configuration
Default configuration is provided in `Config.psd1`. Override values by passing a custom configuration hashtable.

## Dependencies
- Helm (installed by base installer)
- kubectl (installed by base installer)

## Platform Support
- ✅ Azure AKS
- ✅ AWS EKS
- ✅ Google GKE
- ✅ RKE2 (On-Premise)
- ✅ Kind (Local)

## Integration with Jenkins + ProGet
After installation, configure ArgoCD to work with your ProGet registry:
1. Add your ProGet registry credentials as a secret in the argocd namespace
2. Configure image updater to track your ProGet repository
3. Set up automated synchronization with your Git repositories

## Access
- Initial admin password is displayed after installation
- By default, ArgoCD is exposed as LoadBalancer service
- For local Kind clusters, use port forwarding to access the UI