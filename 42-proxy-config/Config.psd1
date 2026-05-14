@{
    # Component metadata (NOT configurable by end user)
    Name            = "proxy-config"
    Namespace       = "proxy-config"
    CreateNamespace = $true

    # User-configurable settings
    UserConfig = @{
        SecretName   = "proxy-config"

        # Default NO_PROXY entries — user additions are appended in Prompt.ps1
        NoProxyBase  = "localhost,127.0.0.1,::1,.cluster.local,.svc,kubernetes.default.svc,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    }
}
