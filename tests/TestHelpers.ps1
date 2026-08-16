<#
.SYNOPSIS
    Builders for fake World of Warcraft install trees.

.DESCRIPTION
    Every test builds a throwaway install under its own temp folder rather than
    touching a real game folder, so the suite runs anywhere — including CI,
    which has never seen WoW.
#>

$script:DefaultFakeConfig = @'
SET gxWindow "1"
SET gxResolution "2560x1440"
SET realmList "us.logon.worldofwarcraft.com"
SET Sound_MasterVolume "0.4"
'@

# Handed out one second at a time by New-TestFile. Backdated a day so nothing
# written by a test is stamped in the future.
$script:LastTestFileStamp = [datetime]::UtcNow.AddDays(-1)

function New-TestFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Content = 'x'
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    Write-TextFileNoBom -Path $Path -Content $Content

    # Every file gets a stamp of its own. `Test-FileUnchanged` reads an equal
    # size and an equal last-write time as "already copied", and Windows'
    # timestamps are coarse enough that two same-size files written back to back
    # can share one — which turned a test meaning "these two differ" into a
    # coin flip that came up heads on most machines and tails on a CI runner.
    # A test that wants two files to compare equal copies one to the other,
    # because that is what preserves a timestamp in the tool itself.
    $script:LastTestFileStamp = $script:LastTestFileStamp.AddSeconds(1)
    [System.IO.File]::SetLastWriteTimeUtc($Path, $script:LastTestFileStamp)
    return $Path
}

function New-FakeInstall {
    <#
    .SYNOPSIS
        Create one client folder, e.g. <Root>\_classic_, populated enough to copy.
    #>
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Flavor,
        [string] $Account = '12345678#1',
        [string] $Realm = 'Whitemane',
        [string[]] $Character = @('Bankalt'),
        [string[]] $AddOn = @('WeakAuras', 'Details'),
        [string] $Config = $script:DefaultFakeConfig,
        [string[]] $AccountSavedVariable = @('WeakAuras.lua')
    )

    $install = Join-Path $Root $Flavor
    $null = New-Item -ItemType Directory -Path $install -Force

    # Loop variables must not share a name with a typed parameter: PowerShell
    # variable names are case-insensitive, so `foreach ($addon in $AddOn)` would
    # assign through the [string[]] constraint and hand back an array.
    foreach ($addonName in $AddOn) {
        $folder = Join-Path (Join-Path $install 'Interface/AddOns') $addonName
        $null = New-TestFile -Path (Join-Path $folder "$addonName.toc") -Content "## Title: $addonName`n"
        $null = New-TestFile -Path (Join-Path $folder "$addonName.lua") -Content "-- code`n"
    }

    if ($Config) {
        $null = New-TestFile -Path (Join-Path $install 'WTF/Config.wtf') -Content $Config
    }

    $accountDir = Join-Path (Join-Path $install 'WTF/Account') $Account
    foreach ($savedVariableName in $AccountSavedVariable) {
        $null = New-TestFile -Path (Join-Path (Join-Path $accountDir 'SavedVariables') $savedVariableName) -Content "-- account profile`n"
    }
    $null = New-TestFile -Path (Join-Path $accountDir 'macros-cache.txt') -Content "macros`n"
    $null = New-TestFile -Path (Join-Path $accountDir 'bindings-cache.wtf') -Content "bindings`n"

    foreach ($characterName in $Character) {
        $characterDir = Join-Path (Join-Path $accountDir $Realm) $characterName
        $null = New-TestFile -Path (Join-Path (Join-Path $characterDir 'SavedVariables') 'WeakAuras.lua') -Content "-- char profile`n"
        $null = New-TestFile -Path (Join-Path $characterDir 'AddOns.txt') -Content "WeakAuras: enabled`n"
        $null = New-TestFile -Path (Join-Path $characterDir 'layout-local.txt') -Content "layout`n"
        $null = New-TestFile -Path (Join-Path $characterDir 'macros-cache.txt') -Content "char macros`n"
        $null = New-TestFile -Path (Join-Path $characterDir 'bindings-cache.wtf') -Content "char bindings`n"
    }

    return $install
}

function New-FakeWowRoot {
    <#
    .SYNOPSIS
        A "World of Warcraft" folder with a populated live client and a bare PTR one.
    #>
    param([Parameter(Mandatory)] [string] $Parent)

    $root = Join-Path $Parent 'World of Warcraft'
    $null = New-FakeInstall -Root $root -Flavor '_classic_'
    $null = New-FakeInstall -Root $root -Flavor '_classic_ptr_' -Realm 'PTR Whitemane' -AddOn @() `
        -Config "SET realmList `"us.logon-ptr.worldofwarcraft.com`"`nSET gxWindow `"0`"`n" `
        -AccountSavedVariable @()
    return $root
}

function New-FakeContext {
    <#
    .SYNOPSIS
        A fully-populated context over a fake root: both clients, matching
        accounts, one character pair.
    #>
    param([Parameter(Mandatory)] [string] $Root)

    $installs = @(Get-WowInstall -Path $Root -SkipDefaultLocations)
    $source = $installs | Where-Object { -not $_.IsPtr } | Select-Object -First 1
    $target = $installs | Where-Object { $_.IsPtr } | Select-Object -First 1
    $account = '12345678#1'

    $pair = [pscustomobject]@{
        Source = (Get-WowCharacter -Install $source -Account $account)[0]
        Target = (Get-WowCharacter -Install $target -Account $account)[0]
    }

    return New-PtrSetupContext -Source $source -Target $target `
        -SourceAccount $account -TargetAccount $account -Character @($pair)
}
