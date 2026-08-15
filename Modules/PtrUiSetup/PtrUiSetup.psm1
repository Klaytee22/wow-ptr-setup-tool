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

foreach ($part in @('Detect.ps1', 'ConfigWtf.ps1', 'FileOps.ps1', 'SavedVariables.ps1', 'AddOnPatch.ps1', 'MacroNames.ps1', 'Steps.ps1', 'Session.ps1', 'Settings.ps1')) {
    . (Join-Path $PSScriptRoot $part)
}

Export-ModuleMember -Function @(
    # Detect
    'Get-WowFlavor'
    'Get-WowClientFlavor'
    'Get-WowFlavorInfo'
    'Get-WowProductLine'
    'Get-WowInstall'
    'Get-WowRootCandidate'
    'Find-WowFolder'
    'Get-WowDefaultRoot'
    'Get-FixedDriveRoot'
    'Get-WowRegistryPath'
    'Test-WindowsHost'
    'Test-MacHost'
    'Select-WowInstallPair'
    'Get-WowAccount'
    'Get-RunningWowProcess'
    'Get-WowFolderFingerprint'
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
    'Test-FileUnchanged'
    'Format-ByteSize'
    # SavedVariables profile keys
    'ConvertFrom-LuaString'
    'ConvertTo-LuaString'
    'Read-TextFileUtf8'
    'Find-LuaTable'
    'Get-LuaBlockEnd'
    'Get-LuaProfileKey'
    'Set-LuaProfileKey'
    'Update-LuaProfileKey'
    'Test-LuaProfileFile'
    'Clear-LuaProbeCache'
    'Get-PtrSetupProfileMapping'
    'Get-LuaProfileKeyForCharacter'
    'Resolve-ProfileKeyMapping'
    'New-ProfileKeyPlan'
    'Merge-FileActionPlan'
    # Ace3 region workaround
    'Test-AceDbRegionBug'
    'Update-AceDbRegionKey'
    'New-AceDbPatchPlan'
    # Macro names
    'Get-InvisibleMacroSuffix'
    'Get-MacroCacheEntry'
    'Get-MacroNameConflict'
    'Resolve-MacroNameConflict'
    'New-MacroNamePlan'
    'New-MacroNameFixPlan'
    # Steps
    'New-PtrSetupContext'
    'Test-ContextReady'
    'Get-ContextOption'
    'Get-ContextAccountPath'
    'Get-ContextCharacter'
    'Get-PtrSetupStep'
    'Get-PtrSetupStepStatus'
    'Get-PtrSetupStepBlocker'
    'New-PtrSetupStepPlan'
    'Invoke-PtrSetupStep'
    'Invoke-PtrSetup'
    # Settings
    'Get-PtrSetupSettingPath'
    'Get-PtrSetupSetting'
    'Save-PtrSetupSetting'
    # Session
    'Initialize-PtrSetupContext'
    'Set-PtrSetupInstall'
    'Set-PtrSetupAccount'
    'Set-PtrSetupAccountGuess'
    'Set-PtrSetupCharacterGuess'
    'ConvertTo-PtrSetupSnapshot'
    'ConvertFrom-PtrSetupSnapshot'
)
