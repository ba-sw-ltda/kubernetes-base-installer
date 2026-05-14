@{
    Name      = "wildcard-cert"
    Namespace = "cert-manager"

    UserConfig = @{
        SecretName  = "wildcard-tls"
        VaultPath   = "infrastructure/wildcard-tls"
    }
}
