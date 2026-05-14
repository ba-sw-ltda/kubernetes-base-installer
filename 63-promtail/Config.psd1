@{
    Name            = "promtail"
    Version         = "6.17.1"
    Repository      = "https://grafana.github.io/helm-charts"
    ChartName       = "promtail"
    Namespace       = "monitoring"
    CreateNamespace = $false

    UserConfig = @{
        LokiUrl = "http://loki.monitoring:3100/loki/api/v1/push"

        Resources = @{
            Limits   = @{ Cpu = "200m"; Memory = "256Mi" }
            Requests = @{ Cpu = "50m";  Memory = "64Mi" }
        }
    }
}
