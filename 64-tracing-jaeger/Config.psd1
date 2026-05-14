@{
    Name            = "jaeger"
    Version         = "4.7.0"
    Repository      = "https://jaegertracing.github.io/helm-charts"
    ChartName       = "jaeger"
    Namespace       = "monitoring"
    CreateNamespace = $false

    UserConfig = @{
        # allInOne: simple single-pod deployment (local/dev)
        # production: separate collector + query + storage
        DeploymentMode = "allInOne"
        StorageType    = "badger"
        StorageSize    = "10Gi"
        Retention      = "168h"
        IngressClass   = "nginx"

        Resources = @{
            Limits   = @{ Cpu = "500m"; Memory = "512Mi" }
            Requests = @{ Cpu = "100m"; Memory = "128Mi" }
        }
    }
}
