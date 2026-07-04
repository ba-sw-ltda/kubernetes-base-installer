@{
    Name            = "tempo"
    Version         = "1.61.3"
    Repository      = "https://grafana.github.io/helm-charts"
    ChartName       = "tempo-distributed"
    Namespace       = "tempo"
    RancherProject  = "Observability"
    CreateNamespace = $false

    UserConfig = @{
        Retention   = "168h"
        StorageSize = "10Gi"

        Resources = @{
            Limits   = @{ Cpu = "500m"; Memory = "512Mi" }
            Requests = @{ Cpu = "100m"; Memory = "128Mi" }
        }
    }
}
