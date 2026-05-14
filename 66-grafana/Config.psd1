@{
    Name            = "grafana"
    Version         = "10.5.15"
    Repository      = "https://grafana.github.io/helm-charts"
    ChartName       = "grafana"
    Namespace       = "monitoring"
    CreateNamespace = $false

    UserConfig = @{
        AdminUser     = "admin"

        Resources = @{
            Limits   = @{ Cpu = "500m"; Memory = "512Mi" }
            Requests = @{ Cpu = "100m"; Memory = "128Mi" }
        }

        # Datasource endpoints (cluster-internal)
        Datasources = @{
            PrometheusUrl = "http://prometheus.monitoring:9090"
            LokiUrl       = "http://loki.monitoring:3100"
            TempoUrl      = "http://tempo-query-frontend.monitoring:3200"
            JaegerUrl     = "http://jaeger-query.monitoring:16686"
        }
    }
}
