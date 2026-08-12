@{
    RootModule        = 'PtrUiSetup.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'b6f4a1c2-7d3e-4a58-9c21-8f0d5e6a7b31'
    Author            = 'Klaytee22'
    Description       = 'Copies a live World of Warcraft client''s UI, addons and settings onto the PTR client.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-WowFlavor'
        'Get-WowInstall'
        'Get-WowRootCandidate'
        'Test-WindowsHost'
        'Test-MacHost'
        'Select-WowInstallPair'
        'Get-WowAccount'
        'Get-WowRealm'
        'Get-WowCharacter'
        'Get-WowCharacterPath'
        'New-WowInstall'
        'ConvertFrom-ConfigWtf'
        'ConvertTo-ConfigWtf'
        'Read-ConfigWtf'
        'Merge-ConfigWtf'
        'Compare-ConfigWtf'
        'Get-ProtectedConfigKey'
        'New-FileAction'
        'New-TreeCopyPlan'
        'New-SingleFileCopyPlan'
        'Invoke-FileActionPlan'
        'Get-PtrSetupBackup'
        'Restore-PtrSetupBackup'
        'Test-PathWithin'
        'Get-PathRelative'
        'Write-TextFileNoBom'
        'Get-RelativeFile'
        'Format-ByteSize'
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
        'Initialize-PtrSetupContext'
        'Set-PtrSetupInstall'
        'Set-PtrSetupAccount'
        'Set-PtrSetupAccountGuess'
        'Set-PtrSetupCharacterGuess'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('WoW', 'WorldOfWarcraft', 'PTR', 'AddOns', 'UI')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
