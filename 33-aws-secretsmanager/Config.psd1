@{
    Name           = "aws-secretsmanager"
    Namespace      = "kube-system"
    RancherProject = "Security"

    UserConfig = @{
        # ASCP (AWS Secrets and Configuration Provider) for Secrets Store CSI Driver
        AscpVersion = "1.3.9"
    }
}
