<#
.SYNOPSIS
    Build a fake "World of Warcraft" folder to test the tool against.

.DESCRIPTION
    Creates a live client and a PTR client with the same shape a real install
    has, filled with recognisable content so you can see what moved and what
    did not:

        World of Warcraft/
          _classic_/          the live client — 5 addons, 3 characters, full settings
          _classic_ptr_/      the PTR client  — launched once, one copied character,
                              one stale addon, and PTR-specific realm settings

    Nothing here touches a real game folder. Point the window at the result and
    apply away; delete the folder when you are done.

.PARAMETER Path
    Where to build it. Defaults to a "PtrUiSetup-Mock" folder on your desktop
    (or the temp folder if there is no desktop).

.PARAMETER Force
    Delete and rebuild if the folder already exists.

.PARAMETER Launch
    Open the window pointed at the mock folder once it is built.

.PARAMETER Quiet
    Return the path and print nothing. Used by the integration tests.

.EXAMPLE
    .\tools\New-MockWowFolder.ps1 -Launch

.EXAMPLE
    .\tools\New-MockWowFolder.ps1 -Path C:\temp\mock -Force
#>

[CmdletBinding()]
param(
    [string] $Path,
    [switch] $Force,
    [switch] $Launch,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $Path) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = [System.IO.Path]::GetTempPath() }
    $Path = Join-Path $desktop 'PtrUiSetup-Mock'
}

if (Test-Path -LiteralPath $Path) {
    if (-not $Force) { throw "$Path already exists. Pass -Force to rebuild it, or -Path to build somewhere else." }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

# --------------------------------------------------------------------------
# Content. Every file says where it came from, so after a copy you can open
# anything on the PTR side and see whether it is live content or PTR content.
# --------------------------------------------------------------------------

$account = '112233445#1'
$liveRealm = 'Whitemane'
$ptrRealm = 'Classic PTR Realm 1'
$characters = @('Sunderfury', 'Mendicant', 'Bankalt')
$addons = @('WeakAuras', 'Details', 'Plater', 'Bartender4', 'Questie')

$liveConfig = @'
SET gxWindow "1"
SET gxMaximize "1"
SET gxResolution "2560x1440"
SET realmList "us.logon.worldofwarcraft.com"
SET portal "us"
SET Sound_MasterVolume "0.35"
SET weatherDensity "3"
SET graphicsQuality "7"
SET nameplateShowEnemies "1"
'@

$ptrConfig = @'
SET gxWindow "0"
SET gxResolution "1920x1080"
SET realmList "us.logon-ptr.worldofwarcraft.com"
SET portal "us-ptr"
SET Sound_MasterVolume "1.0"
'@

function Write-MockFile {
    param([string] $FilePath, [string] $Content)

    $parent = Split-Path -Path $FilePath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [System.IO.File]::WriteAllText($FilePath, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function New-MockCharacter {
    param([string] $Root, [string] $Name, [string] $Origin)

    Write-MockFile (Join-Path $Root 'SavedVariables/WeakAuras.lua') "-- $Origin WeakAuras profile for $Name`nWeakAurasSaved = { displays = { } }`n"
    Write-MockFile (Join-Path $Root 'SavedVariables/Details.lua') "-- $Origin Details profile for $Name`n"
    Write-MockFile (Join-Path $Root 'AddOns.txt') "WeakAuras: enabled`nDetails: enabled`nPlater: enabled`n# $Origin`n"
    Write-MockFile (Join-Path $Root 'layout-local.txt') "-- $Origin frame layout for $Name`n"
    Write-MockFile (Join-Path $Root 'config-cache.wtf') "SET cameraDistanceMaxZoomFactor `"$(if ($Origin -eq 'LIVE') { '2.6' } else { '1.0' })`"`nSET floatingCombatTextCombatDamage `"$(if ($Origin -eq 'LIVE') { '1' } else { '0' })`"`n# $Origin`n"
    Write-MockFile (Join-Path $Root 'bindings-cache.wtf') "bind V TARGETNEARESTENEMY`n# $Origin character keybinds for $Name`n"
    Write-MockFile (Join-Path $Root 'macros-cache.txt') "MACRO Pull $Origin`n/say Pulling!`n"
}

function New-MockBartender {
    <#
        An AceDB-shaped saved variable — the layout Bartender4, ElvUI and most
        others use. profileKeys maps "Name - Realm" onto a profile name, which is
        the table the tool adds the PTR character to so the bars come up right.
    #>
    param([string] $Realm, [string[]] $CharacterName, [string] $Origin)

    $profileFor = @{ }
    $keys = ''
    $index = 0
    foreach ($name in $CharacterName) {
        # One character on its own named profile, one sharing a shared profile,
        # one on the default — the three cases the rewrite has to carry across.
        $profile = @("$name - $Realm", 'Healer', 'Default')[$index % 3]
        $profileFor[$name] = $profile
        $keys += "`t`t[`"$name - $Realm`"] = `"$profile`",`n"
        $index++
    }

    $bodies = ''
    foreach ($profile in @($profileFor.Values | Select-Object -Unique | Sort-Object)) {
        $bodies += "`t`t[`"$profile`"] = {`n`t`t`t[`"bar1`"] = {`n`t`t`t`t[`"position`"] = `"$Origin-$profile`",`n`t`t`t},`n`t`t},`n"
    }

    return "-- $Origin account-wide Bartender4 profiles`nBartender4DB = {`n`t[`"profileKeys`"] = {`n$keys`t},`n`t[`"profiles`"] = {`n$bodies`t},`n}`n"
}

function New-MockAccount {
    param([string] $InstallRoot, [string] $Realm, [string[]] $CharacterName, [string] $Origin)

    $accountRoot = Join-Path (Join-Path $InstallRoot 'WTF/Account') $account
    Write-MockFile (Join-Path $accountRoot 'SavedVariables/Bartender4.lua') (New-MockBartender -Realm $Realm -CharacterName $CharacterName -Origin $Origin)
    Write-MockFile (Join-Path $accountRoot 'SavedVariables/WeakAuras.lua') "-- $Origin account-wide WeakAuras profiles`n"
    Write-MockFile (Join-Path $accountRoot 'SavedVariables/Plater.lua') "-- $Origin account-wide Plater profiles`n"
    Write-MockFile (Join-Path $accountRoot 'bindings-cache.wtf') "bind SHIFT-1 MULTIACTIONBAR1BUTTON1`n# $Origin account-wide keybinds`n"
    Write-MockFile (Join-Path $accountRoot 'macros-cache.txt') "MACRO AccountWide $Origin`n/wave`n"
    Write-MockFile (Join-Path $accountRoot 'config-cache.wtf') "SET showTutorials `"0`"`n# $Origin account cache`n"

    foreach ($name in $CharacterName) {
        New-MockCharacter -Root (Join-Path (Join-Path $accountRoot $Realm) $name) -Name $name -Origin $Origin
    }
}

# --- The live client -------------------------------------------------------

$live = Join-Path $Path 'World of Warcraft/_classic_'
foreach ($addon in $addons) {
    Write-MockFile (Join-Path $live "Interface/AddOns/$addon/$addon.toc") "## Interface: 20504`n## Title: $addon`n## Notes: LIVE copy`n$addon.lua`n"
    Write-MockFile (Join-Path $live "Interface/AddOns/$addon/$addon.lua") "-- LIVE $addon`nlocal _ = 'installed on the live client'`n"
}
# One addon carries an old Ace3, the way a real install nearly always does. Its
# region lookup has no fallback, so on a PTR realm AceDB throws while the addon
# is initialising and every Ace3 addon goes down with it — see the AceDB section
# of the README. The PTR's copy gets the one-line fix; this one never changes.
$staleAceDb = @'
local regionTable = { "US", "KR", "EU", "TW", "CN" }
local charKey = UnitName("player") .. " - " .. GetRealmName()
local regionKey = regionTable[GetCurrentRegion()]
local factionrealmregionKey = factionrealmKey .. " - " .. regionKey
-- LIVE copy of AceDB-3.0
'@
Write-MockFile (Join-Path $live 'Interface/AddOns/Bartender4/Libs/AceDB-3.0/AceDB-3.0.lua') $staleAceDb

Write-MockFile (Join-Path $live 'WTF/Config.wtf') $liveConfig
New-MockAccount -InstallRoot $live -Realm $liveRealm -CharacterName $characters -Origin 'LIVE'

# --- The PTR client --------------------------------------------------------
# Launched once (so WTF exists) with one character copied across, plus a stale
# addon so the "replace the PTR addon folder" option has something to remove.

$ptr = Join-Path $Path 'World of Warcraft/_classic_ptr_'
Write-MockFile (Join-Path $ptr 'Interface/AddOns/OldPtrAddon/OldPtrAddon.toc') "## Title: OldPtrAddon`n## Notes: only on the PTR — pruning should remove this`n"
Write-MockFile (Join-Path $ptr 'Interface/AddOns/OldPtrAddon/OldPtrAddon.lua') "-- PTR-only leftover`n"
Write-MockFile (Join-Path $ptr 'WTF/Config.wtf') $ptrConfig
New-MockAccount -InstallRoot $ptr -Realm $ptrRealm -CharacterName @('Sunderfury') -Origin 'PTR'

if ($Quiet) { return $Path }

$wowFolder = Join-Path $Path 'World of Warcraft'
Write-Host ''
Write-Host 'Mock World of Warcraft folder built.' -ForegroundColor Green
Write-Host "  $wowFolder"
Write-Host ''
Write-Host 'What is in it:' -ForegroundColor Cyan
Write-Host "  _classic_      $($addons.Count) addons · account $account · realm '$liveRealm' · $($characters.Count) characters"
Write-Host "  _classic_ptr_  1 stale addon (OldPtrAddon) · realm '$ptrRealm' · 1 copied character (Sunderfury)"
Write-Host ''
Write-Host 'Every file is stamped LIVE or PTR, so after applying you can open any' -ForegroundColor Cyan
Write-Host 'file on the PTR side and see whether it really came across.'
Write-Host ''
Write-Host 'Things worth trying:' -ForegroundColor Cyan
Write-Host '  · Preview changes  — nothing should be written'
Write-Host "  · Apply            — $($addons.Count) addons copied, OldPtrAddon removed, Sunderfury settings copied"
Write-Host "  · Check WTF\Config.wtf on the PTR side — realmList must still say logon-ptr"
Write-Host '  · Restore a backup — that step goes back. An Apply leaves one backup'
Write-Host '                       per step, so undoing the lot means restoring each'
Write-Host '  · Apply again      — steps should report "already up to date"'
Write-Host ''
Write-Host 'Point the tool at it:' -ForegroundColor Yellow
Write-Host "  .\PtrUiSetup.ps1 -Path '$wowFolder'"
Write-Host '  (or press Browse in the window and pick that folder)'
Write-Host ''
Write-Host 'Delete the whole folder when you are done — nothing else is touched.'
Write-Host ''

if ($Launch) {
    & (Join-Path $repoRoot 'PtrUiSetup.ps1') -Path $wowFolder
}

return $Path
