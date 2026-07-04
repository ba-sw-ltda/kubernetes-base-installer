@{
    Name            = "grafana"
    Version         = "10.5.15"
    Repository      = "https://grafana.github.io/helm-charts"
    ChartName       = "grafana"
    Namespace       = "grafana"
    RancherProject  = "Observability"
    CreateNamespace = $false

    PortalTitle     = "Grafana"
    PortalSubtitle  = "Dashboards & Alerts"
    PortalIcon      = "logo.svg"

    UserConfig = @{
        AdminUser     = "admin"

        Resources = @{
            Limits   = @{ Cpu = "500m"; Memory = "512Mi" }
            Requests = @{ Cpu = "100m"; Memory = "128Mi" }
        }

        # Datasource endpoints (cluster-internal)
        Datasources = @{
            PrometheusUrl = "http://prometheus.prometheus:9090"
            LokiUrl       = "http://loki.loki:3100"
            TempoUrl      = "http://tempo-query-frontend.tempo:3200"
            JaegerUrl     = "http://jaeger-query.jaeger:16686"
        }
    }
}
