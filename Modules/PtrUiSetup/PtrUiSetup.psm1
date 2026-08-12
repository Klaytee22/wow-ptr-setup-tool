<#
.SYNOPSIS
    PtrUiSetup — copy a live World of Warcraft UI onto the PTR client.

.DESCRIPTION
    All the logic lives here, with no dependency on the window: detection, the
    plan/apply/backup machinery, the Config.wtf merge, and the step list. The
    GUI in PtrUiSetup.ps1 is one consumer of it; the functions are equally
    usable from a plain console.

        Import-Module ./Modules/PtrUiSetup
        $context = Initialize-PtrSetupContext
        Invoke-PtrSetup -Context $context -StepId copy_addons -PreviewOnly
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($part in @('Detect.ps1', 'ConfigWtf.ps1', 'FileOps.ps1', 'Steps.ps1', 'Session.ps1')) {
    . (Join-Path $PSScriptRoot $part)
}

Export-ModuleMember -Function @(
    # Detect
    'Get-WowFlavor'
    'Get-WowInstall'
    'Get-WowRootCandidate'
    'Test-WindowsHost'
    'Test-MacHost'
    'Select-WowInstallPair'
    'Get-WowAccount'
    'Get-RunningWowProcess'
    'Get-WowRealm'
    'Get-WowCharacter'
    'Get-WowCharacterPath'
    'New-WowInstall'
    # Config.wtf
    'ConvertFrom-ConfigWtf'
    'ConvertTo-ConfigWtf'
    'Read-ConfigWtf'
    'Merge-ConfigWtf'
    'Compare-ConfigWtf'
    'Get-ProtectedConfigKey'
    # File operations
    'New-FileAction'
    'New-TreeCopyPlan'
    'New-SingleFileCopyPlan'
    'Invoke-FileActionPlan'
    'Get-PtrSetupBackup'
    'Restore-PtrSetupBackup'
    'Remove-EmptyFolder'
    'Test-PathWithin'
    'Get-PathRelative'
    'Write-TextFileNoBom'
    'Get-RelativeFile'
    'Format-ByteSize'
    # Steps
    'New-PtrSetupContext'
    'Test-ContextReady'
    'Get-ContextOption'
    'Get-ContextAccountPath'
    'Get-PtrSetupStep'
    'Get-PtrSetupStepStatus'
    'Get-PtrSetupStepBlocker'
    'New-PtrSetupStepPlan'
    'Invoke-PtrSetupStep'
    'Invoke-PtrSetup'
    # Session
    'Initialize-PtrSetupContext'
    'Set-PtrSetupInstall'
    'Set-PtrSetupAccount'
    'Set-PtrSetupAccountGuess'
    'Set-PtrSetupCharacterGuess'
)
