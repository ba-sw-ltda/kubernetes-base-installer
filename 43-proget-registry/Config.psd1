@{
    Name      = "proget-registry"
    Namespace = "registry"

    UserConfig = @{
        RegistryUrl   = ""   # set via Prompt.ps1 — e.g. registry.example.com
        Feed          = ""   # set via Prompt.ps1 — main Docker feed name
        PrototypeFeed = ""   # set via Prompt.ps1 — on-premise prototype feed (optional)
        User          = "api"
    }
}
