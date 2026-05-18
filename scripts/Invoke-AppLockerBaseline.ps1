[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('ValidateConfig', 'GeneratePolicy', 'ApplyAudit', 'ApplyEnforce', 'ExportEffectivePolicy')]
    [string]$Mode,

    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\config\applocker.config.json'),

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SupportedRuleCollections = @('Exe', 'Msi', 'Script', 'Appx')
$StandardUserSid = 'S-1-1-0'

function Get-DefaultOutputPath {
    param(
        [Parameter(Mandatory)]
        [string]$RequestedMode
    )

    $fileName = switch ($RequestedMode) {
        'ApplyAudit' { 'applocker-audit.xml' }
        'ApplyEnforce' { 'applocker-enforce.xml' }
        'ExportEffectivePolicy' { 'applocker-effective.xml' }
        default { 'applocker-policy.xml' }
    }

    return (Join-Path -Path $PSScriptRoot -ChildPath "..\out\$fileName")
}

function Ensure-ParentDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -Path $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

function Load-Config {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Konfigurationsdatei nicht gefunden: $Path"
    }

    $jsonContent = Get-Content -Path $Path -Raw
    $convertFromJsonCommand = Get-Command -Name ConvertFrom-Json

    if ($convertFromJsonCommand.Parameters.ContainsKey('Depth')) {
        return ($jsonContent | ConvertFrom-Json -Depth 10)
    }

    return ($jsonContent | ConvertFrom-Json)
}

function Validate-ConfigObject {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not $Config.allowedPaths -or $Config.allowedPaths.Count -eq 0) {
        $errors.Add('allowedPaths muss mindestens einen Eintrag enthalten.')
    }

    foreach ($pathEntry in @($Config.allowedPaths)) {
        if (-not $pathEntry.path) {
            $errors.Add('Jeder Eintrag in allowedPaths braucht das Feld path.')
        }
        foreach ($collection in @($pathEntry.collections)) {
            if ($collection -and $collection -notin $SupportedRuleCollections) {
                $errors.Add("allowedPaths enthaelt eine ungueltige Collection: $collection")
            }
        }
    }

    foreach ($fileEntry in @($Config.allowedFiles)) {
        if (-not $fileEntry.path) {
            $errors.Add('Jeder Eintrag in allowedFiles braucht das Feld path.')
        }
        foreach ($collection in @($fileEntry.collections)) {
            if ($collection -and $collection -notin $SupportedRuleCollections) {
                $errors.Add("allowedFiles enthaelt eine ungueltige Collection: $collection")
            }
        }
    }

    foreach ($publisherEntry in @($Config.allowedPublishers)) {
        if (-not $publisherEntry.publisherName) {
            $errors.Add('Jeder Eintrag in allowedPublishers braucht publisherName.')
        }
        foreach ($collection in @($publisherEntry.collections)) {
            if ($collection -and $collection -notin $SupportedRuleCollections) {
                $errors.Add("allowedPublishers enthaelt eine ungueltige Collection: $collection")
            }
        }
    }

    if ($null -eq $Config.modeDefaults -or [string]::IsNullOrWhiteSpace($Config.modeDefaults.defaultMode)) {
        $errors.Add('modeDefaults.defaultMode fehlt.')
    }
    elseif ($Config.modeDefaults.defaultMode -notin @('AuditOnly', 'Enabled')) {
        $errors.Add("modeDefaults.defaultMode muss 'AuditOnly' oder 'Enabled' sein.")
    }

    if ($Config.PSObject.Properties.Name -contains 'targetGroup') {
        $warnings.Add('targetGroup wird nicht mehr verwendet. Die Regeln gelten fuer alle Benutzer, Administratoren erhalten eine separate uneingeschraenkte Freigabe.')
    }

    if ($Config.PSObject.Properties.Name -contains 'blockedPaths' -and @($Config.blockedPaths).Count -gt 0) {
        $warnings.Add('blockedPaths wird im Modus "alle Benutzer ausser Admins" nicht mehr ausgewertet. Die Sperrwirkung entsteht ueber die Allowlist.')
    }

    [pscustomobject]@{
        IsValid  = ($errors.Count -eq 0)
        Errors   = $errors
        Warnings = $warnings
    }
}

function New-PolicyDocument {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AuditOnly', 'Enabled')]
        [string]$EnforcementMode
    )

    $document = New-Object System.Xml.XmlDocument
    $declaration = $document.CreateXmlDeclaration('1.0', 'utf-8', $null)
    [void]$document.AppendChild($declaration)
    $root = $document.CreateElement('AppLockerPolicy')
    [void]$root.SetAttribute('Version', '1')
    [void]$document.AppendChild($root)

    foreach ($type in $SupportedRuleCollections) {
        $collection = $document.CreateElement('RuleCollection')
        [void]$collection.SetAttribute('Type', $type)
        [void]$collection.SetAttribute('EnforcementMode', $EnforcementMode)
        [void]$root.AppendChild($collection)
    }

    return $document
}

function Get-RuleCollectionNode {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [ValidateSet('Exe', 'Msi', 'Script', 'Appx')]
        [string]$CollectionType
    )

    return $Document.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq $CollectionType } | Select-Object -First 1
}

function Add-PathRule {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [string]$CollectionType,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [string]$UserOrGroupSid,

        [Parameter(Mandatory)]
        [ValidateSet('Allow', 'Deny')]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $collection = Get-RuleCollectionNode -Document $Document -CollectionType $CollectionType
    $rule = $Document.CreateElement('FilePathRule')
    [void]$rule.SetAttribute('Id', ([guid]::NewGuid().Guid))
    [void]$rule.SetAttribute('Name', $Name)
    [void]$rule.SetAttribute('Description', $Description)
    [void]$rule.SetAttribute('UserOrGroupSid', $UserOrGroupSid)
    [void]$rule.SetAttribute('Action', $Action)

    $conditions = $Document.CreateElement('Conditions')
    $condition = $Document.CreateElement('FilePathCondition')
    [void]$condition.SetAttribute('Path', $Path)
    [void]$conditions.AppendChild($condition)
    [void]$rule.AppendChild($conditions)
    [void]$collection.AppendChild($rule)
}

function Add-PublisherRule {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [ValidateSet('Exe', 'Msi', 'Script', 'Appx')]
        [string]$CollectionType,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [string]$UserOrGroupSid,

        [Parameter(Mandatory)]
        [ValidateSet('Allow', 'Deny')]
        [string]$Action,

        [Parameter(Mandatory)]
        [pscustomobject]$Publisher
    )

    $collection = Get-RuleCollectionNode -Document $Document -CollectionType $CollectionType
    $rule = $Document.CreateElement('FilePublisherRule')
    [void]$rule.SetAttribute('Id', ([guid]::NewGuid().Guid))
    [void]$rule.SetAttribute('Name', $Name)
    [void]$rule.SetAttribute('Description', $Description)
    [void]$rule.SetAttribute('UserOrGroupSid', $UserOrGroupSid)
    [void]$rule.SetAttribute('Action', $Action)

    $conditions = $Document.CreateElement('Conditions')
    $condition = $Document.CreateElement('FilePublisherCondition')
    [void]$condition.SetAttribute('PublisherName', $Publisher.publisherName)
    [void]$condition.SetAttribute('ProductName', $(if ($Publisher.productName) { $Publisher.productName } else { '*' }))
    [void]$condition.SetAttribute('BinaryName', $(if ($Publisher.binaryName) { $Publisher.binaryName } else { '*' }))

    $range = $Document.CreateElement('BinaryVersionRange')
    [void]$range.SetAttribute('LowSection', $(if ($Publisher.lowVersion) { $Publisher.lowVersion } else { '*' }))
    [void]$range.SetAttribute('HighSection', $(if ($Publisher.highVersion) { $Publisher.highVersion } else { '*' }))
    [void]$condition.AppendChild($range)
    [void]$conditions.AppendChild($condition)
    [void]$rule.AppendChild($conditions)
    [void]$collection.AppendChild($rule)
}

function Add-AdminSupportRules {
    param(
        [Parameter(Mandatory)]
        [xml]$Document
    )

    foreach ($collectionType in $SupportedRuleCollections) {
        Add-PathRule -Document $Document `
            -CollectionType $collectionType `
            -Name "Administrators $collectionType unrestricted" `
            -Description 'Ermoeglicht Wartung durch lokale Administratoren.' `
            -UserOrGroupSid 'S-1-5-32-544' `
            -Action 'Allow' `
            -Path '*'
    }
}

function Add-AllowRulesFromConfig {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    foreach ($pathEntry in @($Config.allowedPaths)) {
        $collections = if ($pathEntry.collections) { @($pathEntry.collections) } else { @('Exe', 'Msi', 'Script') }
        foreach ($collectionType in $collections) {
            Add-PathRule -Document $Document `
                -CollectionType $collectionType `
                -Name $(if ($pathEntry.name) { $pathEntry.name } else { "Allow $($pathEntry.path)" }) `
                -Description $(if ($pathEntry.description) { $pathEntry.description } else { 'Aus Konfiguration freigegebener Pfad.' }) `
                -UserOrGroupSid $StandardUserSid `
                -Action 'Allow' `
                -Path $pathEntry.path
        }
    }

    foreach ($fileEntry in @($Config.allowedFiles)) {
        $collections = if ($fileEntry.collections) { @($fileEntry.collections) } else { @('Exe', 'Msi', 'Script') }
        foreach ($collectionType in $collections) {
            Add-PathRule -Document $Document `
                -CollectionType $collectionType `
                -Name $(if ($fileEntry.name) { $fileEntry.name } else { "Allow $($fileEntry.path)" }) `
                -Description $(if ($fileEntry.description) { $fileEntry.description } else { 'Einzeln freigegebene Datei.' }) `
                -UserOrGroupSid $StandardUserSid `
                -Action 'Allow' `
                -Path $fileEntry.path
        }
    }

    foreach ($publisherEntry in @($Config.allowedPublishers)) {
        $collections = if ($publisherEntry.collections) { @($publisherEntry.collections) } else { @('Exe', 'Msi', 'Script', 'Appx') }
        foreach ($collectionType in $collections) {
            Add-PublisherRule -Document $Document `
                -CollectionType $collectionType `
                -Name $(if ($publisherEntry.name) { $publisherEntry.name } else { "Allow publisher $($publisherEntry.publisherName)" }) `
                -Description $(if ($publisherEntry.description) { $publisherEntry.description } else { 'Aus Konfiguration freigegebener Publisher.' }) `
                -UserOrGroupSid $StandardUserSid `
                -Action 'Allow' `
                -Publisher $publisherEntry
        }
    }
}

function New-AppLockerPolicyXml {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,

        [Parameter(Mandatory)]
        [ValidateSet('AuditOnly', 'Enabled')]
        [string]$EnforcementMode
    )

    $document = New-PolicyDocument -EnforcementMode $EnforcementMode
    Add-AdminSupportRules -Document $document
    Add-AllowRulesFromConfig -Document $document -Config $Config
    return $document
}

function Save-XmlDocument {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Ensure-ParentDirectory -Path $Path

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $Document.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
}

function Get-EnforcementMode {
    param(
        [Parameter(Mandatory)]
        [string]$RequestedMode,

        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    switch ($RequestedMode) {
        'ApplyAudit' { return 'AuditOnly' }
        'ApplyEnforce' { return 'Enabled' }
        default {
            if ($Config.modeDefaults.defaultMode -eq 'Enabled') {
                return 'Enabled'
            }
            return 'AuditOnly'
        }
    }
}

function Show-AppLockerAuditHints {
    Write-Host ''
    Write-Host 'Relevante Eventlogs fuer die Auswertung:' -ForegroundColor Cyan
    Write-Host '  EXE/DLL: Microsoft-Windows-AppLocker/EXE and DLL'
    Write-Host '  MSI/Skripte: Microsoft-Windows-AppLocker/MSI and Script'
    Write-Host '  Packaged Apps: Microsoft-Windows-AppLocker/Packaged app-Execution'
    Write-Host ''
    Write-Host 'Beispiel fuer die letzten Audit-Ereignisse:' -ForegroundColor Cyan
    Write-Host "  Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 20 | Format-Table TimeCreated, Id, Message -AutoSize"
}

function Export-EffectivePolicy {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Ensure-ParentDirectory -Path $Path
    $effectivePolicyXml = Get-AppLockerPolicy -Effective -Xml
    Set-Content -Path $Path -Value $effectivePolicyXml -Encoding utf8
    Write-Host "Effektive AppLocker-Policy exportiert nach: $Path" -ForegroundColor Green
}

function Apply-PolicyFile {
    param(
        [Parameter(Mandatory)]
        [string]$PolicyPath
    )

    $policyXml = Get-Content -Path $PolicyPath -Raw
    $service = Get-Service -Name 'AppIDSvc' -ErrorAction Stop
    if ($service.StartType -ne 'Automatic') {
        Set-Service -Name 'AppIDSvc' -StartupType Automatic
    }
    if ($service.Status -ne 'Running') {
        Start-Service -Name 'AppIDSvc'
    }

    Set-AppLockerPolicy -XmlPolicy $policyXml
    Write-Host "AppLocker-Policy angewendet: $PolicyPath" -ForegroundColor Green
}

if (-not $Mode) {
    $configPreview = Load-Config -Path $ConfigPath
    $Mode = switch ($configPreview.modeDefaults.defaultMode) {
        'Enabled' { 'ApplyEnforce' }
        default { 'ApplyAudit' }
    }
}

$resolvedOutputPath = if ($OutputPath) { $OutputPath } else { Get-DefaultOutputPath -RequestedMode $Mode }
$config = Load-Config -Path $ConfigPath
$validation = Validate-ConfigObject -Config $config

foreach ($warning in $validation.Warnings) {
    Write-Warning $warning
}

if (-not $validation.IsValid) {
    foreach ($errorMessage in $validation.Errors) {
        Write-Error $errorMessage
    }
    throw 'Die Konfigurationsdatei ist ungueltig.'
}

switch ($Mode) {
    'ValidateConfig' {
        Write-Host "Konfiguration gueltig. Regeln gelten fuer alle Benutzerkonten; Administratoren erhalten zusaetzlich Vollzugriff." -ForegroundColor Green
        Write-Host "Default-Modus: $($config.modeDefaults.defaultMode)"
        Write-Host "Erlaubte Pfade: $(@($config.allowedPaths).Count)"
        Write-Host "Erlaubte Dateien: $(@($config.allowedFiles).Count)"
        Write-Host "Erlaubte Publisher: $(@($config.allowedPublishers).Count)"
        return
    }
    'ExportEffectivePolicy' {
        Export-EffectivePolicy -Path $resolvedOutputPath
        return
    }
    default {
        $enforcementMode = Get-EnforcementMode -RequestedMode $Mode -Config $config
        $policyDocument = New-AppLockerPolicyXml -Config $config -EnforcementMode $enforcementMode
        Save-XmlDocument -Document $policyDocument -Path $resolvedOutputPath
        Write-Host "Policy-Datei erzeugt: $resolvedOutputPath" -ForegroundColor Green

        if ($Mode -eq 'GeneratePolicy') {
            return
        }

        Apply-PolicyFile -PolicyPath $resolvedOutputPath
        if ($Mode -eq 'ApplyAudit') {
            Show-AppLockerAuditHints
        }
    }
}
