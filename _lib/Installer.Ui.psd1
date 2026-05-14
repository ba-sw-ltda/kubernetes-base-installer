@{
  # Script module file associated with this manifest.
  RootModule = 'Installer.Ui.psm1'

  # Version number of this module.
  ModuleVersion = '1.0.0'

  # Supported PSEditions (optional; comment out if you run into issues with Windows PowerShell 5.1)
  CompatiblePSEditions = @('Desktop','Core')

  # ID used to uniquely identify this module
  GUID = '8b5e6f2e-6f6d-4d79-9d9f-2a6c8d88d3b5'

  # Author of this module
  Author = 'BA Software LTDA'

  # Company or vendor of this module
  CompanyName = 'BA Software LTDA'

  # Copyright statement for this module
  Copyright = '(c) 2026 BA Software LTDA — MIT License'

  # Description of the functionality provided by this module
  Description = 'Shared console UI helpers for interactive installers (section headers, vertical/horizontal selects, yes/no, secure password prompts, identity/db settings helpers).'

  # Minimum version of the Windows PowerShell engine required by this module
  PowerShellVersion = '5.1'

  # Modules that must be imported into the global environment prior to importing this module
  RequiredModules = @()

  # Functions to export from this module
  FunctionsToExport = @(
    'Test-CommandExists'
    'ToSafeName'
    'Write-Context'
    'Write-Section'
    'Read-SelectIndex'
    'Read-SelectValue'
    'Read-YesNo'
    'Read-MultiSelectValues'
    'Read-ComponentSelectionScreen'
    'Read-Plain'
    'Read-SecretPlain'
    'Read-SecretPlainConfirm'
    'Read-InstallIdentity'
    'Read-DbSettings'
    'ConvertTo-UiOptions'
  )

  # Cmdlets to export from this module
  CmdletsToExport = @()

  # Variables to export from this module
  VariablesToExport = @()

  # Aliases to export from this module
  AliasesToExport = @()

  # Private data to pass to the module specified in RootModule/ModuleToProcess.
  PrivateData = @{
    PSData = @{
      Tags = @('installer','ui','console','wizard','helm','kubernetes')
      LicenseUri = ''
      ProjectUri = ''
      ReleaseNotes = 'Initial shared UI library manifest.'
    }
  }
}