@{
    # Component metadata (NOT configurable by end user)
    Name = "argocd"
    Version = "9.5.4"
    Repository = "https://argoproj.github.io/argo-helm"
    ChartName = "argo-cd"
    Namespace = "argocd"
    RancherProject = "Utilities"
    CreateNamespace = $true
    
    # User-configurable settings
    UserConfig = @{
        # Service type for ArgoCD server: LoadBalancer, NodePort, or ClusterIP
        ServerServiceType = "ClusterIP"
        ServerInsecure    = $true
        
        # Resource limits and requests
        Resources = @{
            Limits = @{
                Cpu = "1000m"
                Memory = "1Gi"
            }
            Requests = @{
                Cpu = "250m"
                Memory = "256Mi"
            }
        }
        
        # Enable or disable specific components
        EnableGrafana = $false
        EnablePrometheus = $false
        
        # Repository server settings
        RepoServer = @{
            ReplicaCount = 1
        }
        
        # Application controller settings
        Controller = @{
            ParallelismLimit = 10
        }
    }
}