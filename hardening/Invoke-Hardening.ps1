[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'hardening-config.json'),
    [switch]$InstallScheduledTask,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-ConfigPath {
    param(
        [Parameter(Mandatory)]
        [string]$BaseDirectory,
        [Parameter(Mandatory)]
        [string]$PathValue
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $PathValue))
}

function New-HardeningDirectories {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    foreach ($path in @($Config.Paths.InstallRoot, $Config.Paths.LogRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Initialize-Logger {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $script:LogFile = Join-Path $Config.Paths.LogRoot 'hardening.log'
    $script:EventSource = "$($Config.CompanyName)Hardening"

    if (-not [System.Diagnostics.EventLog]::SourceExists($script:EventSource)) {
        New-EventLog -LogName Application -Source $script:EventSource
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} [{1}] {2}' -f $timestamp, $Level, $Message
    Add-Content -Path $script:LogFile -Value $line

    $entryType = switch ($Level) {
        'INFO' { 'Information' }
        'WARN' { 'Warning' }
        'ERROR' { 'Error' }
    }

    Write-EventLog -LogName Application -Source $script:EventSource -EntryType $entryType -EventId 1000 -Message $Message
    Write-Host $line
}

function Get-Configuration {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $baseDirectory = Split-Path -Path $Path -Parent

    $json.AppLocker.PolicyPath = Resolve-ConfigPath -BaseDirectory $baseDirectory -PathValue $json.AppLocker.PolicyPath
    $json.AppLocker.AllowListPath = Resolve-ConfigPath -BaseDirectory $baseDirectory -PathValue $json.AppLocker.AllowListPath

    return $json
}

function Test-DomainJoined {
    return (Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain
}

function Set-RegistryDwordValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($current -ne $Value) {
        New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
        Write-Log "Registry updated: $Path\\$Name = $Value"
    }
}

function Ensure-ServiceState {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$StartupType,
        [switch]$MustRun
    )

    $service = Get-Service -Name $Name -ErrorAction Stop

    if ($service.StartType -ne $StartupType) {
        Set-Service -Name $Name -StartupType $StartupType
        Write-Log "Service startup type updated: $Name -> $StartupType"
    }

    if ($MustRun -and $service.Status -ne 'Running') {
        Start-Service -Name $Name
        Write-Log "Service started: $Name"
    }
}

function Ensure-StandardUserHardening {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $security = $Config.Security

    if ($security.DisableUsbStorage) {
        Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name 'Start' -Value 4
    }

    if ($security.DisableAutoRun) {
        Set-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'NoDriveTypeAutoRun' -Value 255
        Set-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'NoAutorun' -Value 1
    }
}

function Ensure-FirewallAndDefender {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if ($Config.Security.RequireFirewallEnabled) {
        foreach ($profile in @('Domain', 'Private', 'Public')) {
            Set-NetFirewallProfile -Profile $profile -Enabled True
        }
        Write-Log 'Firewall profiles enabled'
    }

    if ($Config.Security.RequireDefenderRealtimeMonitoring -and (Get-Command -Name Set-MpPreference -ErrorAction SilentlyContinue)) {
        Set-MpPreference -DisableRealtimeMonitoring $false
        Write-Log 'Defender real-time monitoring enabled'
    }
}

function Ensure-TimeService {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [bool]$DomainJoined
    )

    Ensure-ServiceState -Name 'W32Time' -StartupType 'Automatic' -MustRun

    if ($DomainJoined -and $Config.MachineRole -eq 'ADManaged') {
        & w32tm /config /syncfromflags:DOMHIER /update | Out-Null
        Write-Log 'Windows Time configured for domain hierarchy'
    }
    else {
        & w32tm /config /manualpeerlist:$Config.TimeService.StandaloneNtpServer /syncfromflags:manual /reliable:no /update | Out-Null
        Write-Log "Windows Time configured for manual NTP peers: $($Config.TimeService.StandaloneNtpServer)"
    }

    if ($Config.TimeService.ResyncOnApply) {
        & w32tm /resync /force | Out-Null
        Write-Log 'Windows Time resync requested'
    }
}

function Set-AppLockerCollectionMode {
    param(
        [Parameter(Mandatory)]
        [xml]$XmlDocument,
        [Parameter(Mandatory)]
        [string]$Mode
    )

    foreach ($collection in $XmlDocument.AppLockerPolicy.RuleCollection) {
        $collection.EnforcementMode = $Mode
    }
}

function Add-AppLockerPathRules {
    param(
        [Parameter(Mandatory)]
        [xml]$XmlDocument,
        [Parameter(Mandatory)]
        [hashtable[]]$Rules
    )

    $exeCollection = @($XmlDocument.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Exe' })[0]
    foreach ($rule in $Rules) {
        $id = [guid]::NewGuid().Guid
        $node = $XmlDocument.CreateElement('FilePathRule')
        $null = $node.SetAttribute('Id', $id)
        $null = $node.SetAttribute('Name', $rule.Name)
        $null = $node.SetAttribute('Description', 'Generated from apps-allowlist.json')
        $null = $node.SetAttribute('UserOrGroupSid', 'S-1-1-0')
        $null = $node.SetAttribute('Action', 'Allow')

        $conditions = $XmlDocument.CreateElement('Conditions')
        $condition = $XmlDocument.CreateElement('FilePathCondition')
        $null = $condition.SetAttribute('Path', $rule.Path)
        $conditions.AppendChild($condition) | Out-Null
        $node.AppendChild($conditions) | Out-Null
        $exeCollection.AppendChild($node) | Out-Null
    }
}

function Add-AppLockerPublisherRules {
    param(
        [Parameter(Mandatory)]
        [xml]$XmlDocument,
        [Parameter(Mandatory)]
        [hashtable[]]$Rules
    )

    $exeCollection = @($XmlDocument.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Exe' })[0]
    foreach ($rule in $Rules) {
        $id = [guid]::NewGuid().Guid
        $node = $XmlDocument.CreateElement('FilePublisherRule')
        $null = $node.SetAttribute('Id', $id)
        $null = $node.SetAttribute('Name', $rule.Name)
        $null = $node.SetAttribute('Description', 'Generated from apps-allowlist.json')
        $null = $node.SetAttribute('UserOrGroupSid', 'S-1-1-0')
        $null = $node.SetAttribute('Action', 'Allow')

        $conditions = $XmlDocument.CreateElement('Conditions')
        $condition = $XmlDocument.CreateElement('FilePublisherCondition')
        $null = $condition.SetAttribute('PublisherName', $rule.PublisherName)
        $null = $condition.SetAttribute('ProductName', $rule.ProductName)
        $null = $condition.SetAttribute('BinaryName', $rule.BinaryName)
        $conditions.AppendChild($condition) | Out-Null
        $node.AppendChild($conditions) | Out-Null
        $exeCollection.AppendChild($node) | Out-Null
    }
}

function Add-ManagedAllowRules {
    param(
        [Parameter(Mandatory)]
        [xml]$XmlDocument,
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if ($Config.BrowserExecutable) {
        Add-AppLockerPathRules -XmlDocument $XmlDocument -Rules @(@{
            Name = 'Configured Browser'
            Path = $Config.BrowserExecutable
        })
    }
}

function Add-AppLockerHashRules {
    param(
        [Parameter(Mandatory)]
        [xml]$XmlDocument,
        [Parameter(Mandatory)]
        [hashtable[]]$Rules
    )

    if ($Rules.Count -eq 0) {
        return
    }

    $exeCollection = @($XmlDocument.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Exe' })[0]
    foreach ($rule in $Rules) {
        $id = [guid]::NewGuid().Guid
        $node = $XmlDocument.CreateElement('FileHashRule')
        $null = $node.SetAttribute('Id', $id)
        $null = $node.SetAttribute('Name', $rule.Name)
        $null = $node.SetAttribute('Description', 'Generated from apps-allowlist.json')
        $null = $node.SetAttribute('UserOrGroupSid', 'S-1-1-0')
        $null = $node.SetAttribute('Action', 'Allow')

        $conditions = $XmlDocument.CreateElement('Conditions')
        $condition = $XmlDocument.CreateElement('FileHashCondition')
        $null = $condition.SetAttribute('Type', 'SHA256')
        $null = $condition.SetAttribute('Data', $rule.Sha256)
        $null = $condition.SetAttribute('SourceFileName', $rule.SourceFileName)
        $null = $condition.SetAttribute('SourceFileLength', [string]$rule.SourceFileLength)
        $conditions.AppendChild($condition) | Out-Null
        $node.AppendChild($conditions) | Out-Null
        $exeCollection.AppendChild($node) | Out-Null
    }
}

function Add-AppLockerDenyPathRule {
    param(
        [Parameter(Mandatory)]
        [xml]$XmlDocument,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $exeCollection = @($XmlDocument.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Exe' })[0]
    $node = $XmlDocument.CreateElement('FilePathRule')
    $null = $node.SetAttribute('Id', [guid]::NewGuid().Guid)
    $null = $node.SetAttribute('Name', $Name)
    $null = $node.SetAttribute('Description', 'Generated deny rule for standard users')
    $null = $node.SetAttribute('UserOrGroupSid', 'S-1-5-32-545')
    $null = $node.SetAttribute('Action', 'Deny')

    $conditions = $XmlDocument.CreateElement('Conditions')
    $condition = $XmlDocument.CreateElement('FilePathCondition')
    $null = $condition.SetAttribute('Path', $Path)
    $conditions.AppendChild($condition) | Out-Null
    $node.AppendChild($conditions) | Out-Null
    $exeCollection.AppendChild($node) | Out-Null
}

function Add-ManagedDenyRules {
    param(
        [Parameter(Mandatory)]
        [xml]$XmlDocument,
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $denyRules = [System.Collections.Generic.List[hashtable]]::new()

    if ($Config.Security.DisableCommandPrompt) {
        $denyRules.Add(@{ Name = 'Deny cmd.exe for standard users'; Path = '%WINDIR%\System32\cmd.exe' })
    }

    if ($Config.Security.DisablePowerShellForStandardUsers) {
        $denyRules.Add(@{ Name = 'Deny powershell.exe for standard users'; Path = '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe' })
        $denyRules.Add(@{ Name = 'Deny powershell_ise.exe for standard users'; Path = '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell_ise.exe' })
        $denyRules.Add(@{ Name = 'Deny pwsh.exe for standard users'; Path = '%PROGRAMFILES%\PowerShell\*\pwsh.exe' })
    }

    if ($Config.Security.DisableRegistryTools) {
        $denyRules.Add(@{ Name = 'Deny regedit.exe for standard users'; Path = '%WINDIR%\regedit.exe' })
    }

    if ($Config.Security.DisableTaskManager) {
        $denyRules.Add(@{ Name = 'Deny taskmgr.exe for standard users'; Path = '%WINDIR%\System32\taskmgr.exe' })
    }

    if ($Config.Security.DisableMmcForStandardUsers) {
        $denyRules.Add(@{ Name = 'Deny mmc.exe for standard users'; Path = '%WINDIR%\System32\mmc.exe' })
    }

    $denyRules.Add(@{ Name = 'Deny executables from Downloads'; Path = '%OSDRIVE%\Users\*\Downloads\*' })
    $denyRules.Add(@{ Name = 'Deny executables from Temp'; Path = '%OSDRIVE%\Users\*\AppData\Local\Temp\*' })

    foreach ($denyRule in $denyRules) {
        Add-AppLockerDenyPathRule -XmlDocument $XmlDocument -Name $denyRule.Name -Path $denyRule.Path
    }
}

function New-AppLockerPolicyFile {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if (-not (Test-Path -LiteralPath $Config.AppLocker.PolicyPath)) {
        throw "AppLocker base policy not found: $($Config.AppLocker.PolicyPath)"
    }

    if (-not (Test-Path -LiteralPath $Config.AppLocker.AllowListPath)) {
        throw "AppLocker allow list not found: $($Config.AppLocker.AllowListPath)"
    }

    [xml]$xmlDocument = Get-Content -LiteralPath $Config.AppLocker.PolicyPath -Raw
    $allowList = Get-Content -LiteralPath $Config.AppLocker.AllowListPath -Raw | ConvertFrom-Json -AsHashtable

    Set-AppLockerCollectionMode -XmlDocument $xmlDocument -Mode $Config.AppLocker.EnforcementMode
    Add-AppLockerPathRules -XmlDocument $xmlDocument -Rules $allowList.PathRules
    Add-AppLockerPublisherRules -XmlDocument $xmlDocument -Rules $allowList.PublisherRules
    Add-AppLockerHashRules -XmlDocument $xmlDocument -Rules $allowList.HashRules
    Add-ManagedAllowRules -XmlDocument $xmlDocument -Config $Config
    Add-ManagedDenyRules -XmlDocument $xmlDocument -Config $Config

    $generatedPath = Join-Path $Config.Paths.InstallRoot 'generated-applocker-policy.xml'
    $xmlDocument.Save($generatedPath)
    Write-Log "Generated AppLocker policy: $generatedPath"
    return $generatedPath
}

function Ensure-AppLocker {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [bool]$DomainJoined,
        [switch]$ValidateOnly
    )

    Ensure-ServiceState -Name 'AppIDSvc' -StartupType 'Automatic' -MustRun
    $policyPath = New-AppLockerPolicyFile -Config $Config

    if ($ValidateOnly) {
        Write-Log 'ValidateOnly set, skipping AppLocker import'
        return
    }

    if ($DomainJoined -and $Config.MachineRole -eq 'ADManaged' -and -not $Config.AppLocker.ApplyPolicyOnADManagedMachines) {
        Write-Log 'Domain-managed machine detected, AppLocker import skipped by configuration'
        return
    }

    Set-AppLockerPolicy -XMLPolicy $policyPath
    Write-Log 'AppLocker policy imported locally'
}

function Ensure-ScheduledTask {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $taskName = $Config.Schedule.TaskName
    $scriptTarget = Join-Path $Config.Paths.InstallRoot 'Invoke-Hardening.ps1'
    $configTarget = Join-Path $Config.Paths.InstallRoot 'hardening-config.json'
    $policyTarget = Join-Path $Config.Paths.InstallRoot 'applocker-policy.xml'
    $allowListTarget = Join-Path $Config.Paths.InstallRoot 'apps-allowlist.json'

    Copy-Item -Path $PSCommandPath -Destination $scriptTarget -Force
    Copy-Item -Path $ConfigPath -Destination $configTarget -Force
    Copy-Item -Path $Config.AppLocker.PolicyPath -Destination $policyTarget -Force
    Copy-Item -Path $Config.AppLocker.AllowListPath -Destination $allowListTarget -Force

    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptTarget`" -ConfigPath `"$configTarget`""
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours $Config.Schedule.RepetitionHours) -RepetitionDuration ([TimeSpan]::MaxValue)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startupTrigger, $repeatTrigger) -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Scheduled task ensured: $taskName"
}

function Ensure-SupportAdminAccount {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $user = Get-LocalUser -Name $Config.SupportAdminAccount -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Log "Support admin account '$($Config.SupportAdminAccount)' not found. Create it separately before production rollout." 'WARN'
    }
}

try {
    if (-not (Test-IsAdministrator)) {
        throw 'This script must be run as Administrator.'
    }

    $config = Get-Configuration -Path $ConfigPath
    New-HardeningDirectories -Config $config
    Initialize-Logger -Config $config

    Write-Log "Starting hardening run for role $($config.MachineRole)"
    $domainJoined = Test-DomainJoined
    Write-Log "Domain joined: $domainJoined"

    Ensure-SupportAdminAccount -Config $config
    Ensure-StandardUserHardening -Config $config
    Ensure-FirewallAndDefender -Config $config
    Ensure-TimeService -Config $config -DomainJoined:$domainJoined
    Ensure-AppLocker -Config $config -DomainJoined:$domainJoined -ValidateOnly:$ValidateOnly

    if ($InstallScheduledTask) {
        Ensure-ScheduledTask -Config $config -ConfigPath $ConfigPath
    }

    Write-Log 'Hardening run completed successfully'
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($script:LogFile) {
        Write-Log $message 'ERROR'
    }
    else {
        Write-Error $message
    }
    exit 1
}
