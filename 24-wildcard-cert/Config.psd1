@{
    Name           = "wildcard-cert"
    Namespace      = "cert-manager"
    RancherProject = "Security"

    UserConfig = @{
        SecretName  = "wildcard-tls"
        VaultPath   = "infrastructure/wildcard-tls"
    }
}
