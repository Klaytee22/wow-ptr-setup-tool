<#
.SYNOPSIS
    Remembering the folder the user picked, so they pick it once.

.DESCRIPTION
    Detection is a guess. Once someone has corrected it — because the game is on
    a second drive, or the folder is named something else — asking again on the
    next launch is the tool forgetting something it was told. One small JSON file
    under the user's local app data, holding one setting.

    Nothing here is required: if the file cannot be read or written the tool
    carries on with detection, because a settings file failing is not a reason to
    stop copying addons.
#>

function Get-PtrSetupSettingPath {
    <#
    .SYNOPSIS
        Where the settings file lives on this machine.

    .DESCRIPTION
        PTRSETUP_SETTINGS overrides it, which is how the tests get their own file
        instead of the developer's.
    #>
    [CmdletBinding()]
    param()

    if ($env:PTRSETUP_SETTINGS) { return $env:PTRSETUP_SETTINGS }

    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.config' }
    return (Join-Path (Join-Path $base 'PtrUiSetup') 'settings.json')
}

function Get-PtrSetupSetting {
    <#
    .SYNOPSIS
        The saved settings, or an empty set if there are none.
    #>
    [CmdletBinding()]
    param()

    $empty = [pscustomobject]@{ WowFolder = $null }
    $path = Get-PtrSetupSettingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $empty }

    try {
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        # A corrupt settings file is worth ignoring, not reporting: the tool
        # works without it and will overwrite it on the next save.
        return $empty
    }

    $folder = if ($saved.PSObject.Properties.Name -contains 'WowFolder') { $saved.WowFolder } else { $null }
    return [pscustomobject]@{ WowFolder = $folder }
}

function Save-PtrSetupSetting {
    <#
    .SYNOPSIS
        Remember the folder for next time. Returns whether it stuck.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] [string] $WowFolder)

    $path = Get-PtrSetupSettingPath
    try {
        $parent = Split-Path -Path $path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        Write-TextFileNoBom -Path $path -Content ([pscustomobject]@{ WowFolder = $WowFolder } | ConvertTo-Json)
        return $true
    }
    catch {
        return $false
    }
}
