<#
    The settings file exists so the folder is picked once, not every launch.
    It is also the one thing in the tool that is allowed to fail quietly: a
    machine where it cannot be written still has to copy addons.
#>

function Use-TestSettings {
    <#
        Point the settings functions at this test's own scratch folder, so the
        suite never reads or writes the developer's real settings.
    #>
    param([string] $Name = 'settings.json')

    $env:PTRSETUP_SETTINGS = Join-Path $script:TestDrive $Name
    return $env:PTRSETUP_SETTINGS
}

Describe 'Settings' {

    It 'reports nothing saved on a machine that has never run it' {
        $null = Use-TestSettings
        try {
            Assert-Equal $null (Get-PtrSetupSetting).WowFolder
        }
        finally { $env:PTRSETUP_SETTINGS = $null }
    }

    It 'remembers the folder across a restart' {
        $null = Use-TestSettings
        try {
            Assert-True (Save-PtrSetupSetting -WowFolder 'D:\Games\World of Warcraft')
            Assert-Equal 'D:\Games\World of Warcraft' (Get-PtrSetupSetting).WowFolder
        }
        finally { $env:PTRSETUP_SETTINGS = $null }
    }

    It 'creates the folder it saves into' {
        $env:PTRSETUP_SETTINGS = Join-Path $script:TestDrive 'nested/deeper/settings.json'
        try {
            Assert-True (Save-PtrSetupSetting -WowFolder 'C:\WoW')
            Assert-True (Test-Path -LiteralPath $env:PTRSETUP_SETTINGS -PathType Leaf)
        }
        finally { $env:PTRSETUP_SETTINGS = $null }
    }

    It 'shrugs off a corrupt settings file instead of failing the launch' {
        $path = Use-TestSettings
        try {
            Set-Content -LiteralPath $path -Value 'this is not json {{{'
            # No throw, and no remembered folder — the tool falls back to detection.
            Assert-Equal $null (Get-PtrSetupSetting).WowFolder
            # ...and the next save repairs it.
            Assert-True (Save-PtrSetupSetting -WowFolder 'C:\WoW')
            Assert-Equal 'C:\WoW' (Get-PtrSetupSetting).WowFolder
        }
        finally { $env:PTRSETUP_SETTINGS = $null }
    }

    It 'writes without a byte-order mark, like every other file here' {
        $path = Use-TestSettings
        try {
            $null = Save-PtrSetupSetting -WowFolder 'C:\WoW'
            $bytes = [System.IO.File]::ReadAllBytes($path)
            Assert-True ($bytes[0] -ne 0xEF) 'Settings file should not start with a UTF-8 BOM.'
        }
        finally { $env:PTRSETUP_SETTINGS = $null }
    }
}
