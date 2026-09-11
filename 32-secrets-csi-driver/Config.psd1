@{
    Name            = "secrets-csi-driver"
    Version         = "1.4.8"
    Repository      = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
    ChartName       = "secrets-store-csi-driver"
    Namespace       = "kube-system"
    CreateNamespace = $false
    RancherProject  = "Security"

    UserConfig = @{
        # Enables the driver's opt-in secretObjects sync (creates/rotates a
        # real K8s Secret alongside the file mount) for any SecretProviderClass
        # that declares a secretObjects block — off by default for everyone
        # else, so this has no effect unless a consumer explicitly opts in via
        # New-CsiSecretMount's -SyncSecretName. Flipped on 2026-09-11: the
        # mosquitto-exporter sidecar (Kubernetes.Infra) has no shell to read a
        # mounted file, so its password must arrive via a real Secret +
        # secretKeyRef. Confirmed live: with this false, the driver still
        # accepts a secretObjects request without error but can never
        # fulfill it — pods sit in CreateContainerConfigError /
        # FailedToCreateSecret / SecretRotationFailed indefinitely.
        SyncSecret = $true
        RotationPollInterval = "2m"
    }
}
