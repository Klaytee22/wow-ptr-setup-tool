<#
.SYNOPSIS
    Give blank-named macros unique names that still render as nothing.

.DESCRIPTION
    Separate from the window on purpose. PtrUiSetup.ps1 never writes to your
    live client — that is the rule the whole tool rests on — and this is the one
    job that has to be done there, so it is a thing you run deliberately at a
    prompt rather than something that happens to you.

    Why it has to be the live client: an action bar saver records, for each
    slot, the name of the macro sitting in it. Save a profile on live where
    thirty macros are all called " " and the profile itself is ambiguous —
    every slot says " " and nothing can tell them apart afterwards. Renaming on
    the PTR side cannot repair a profile that was already ambiguous when it was
    written.

    The names are built from spaces and no-break spaces, so they are unique to
    anything reading them and invisible on an action bar. Nothing else in the
    file changes: bodies, icons, ids, ordering and line endings all survive.

    QUIT WORLD OF WARCRAFT FIRST. It rewrites macros-cache.txt when it exits and
    will put the old names straight back.

.PARAMETER Path
    A macros-cache.txt. Both levels have one and both are worth doing:
        <WoW>\_anniversary_\WTF\Account\<ACCOUNT>\macros-cache.txt
        <WoW>\_anniversary_\WTF\Account\<ACCOUNT>\<Realm>\<Character>\macros-cache.txt

.PARAMETER Scope
    Account for the account-level file, Character for a character's own. The two
    sets share one namespace in game, so they are numbered differently to stop a
    macro of each ending up with the same name.

.PARAMETER Apply
    Write the change. Without it this only reports what it would do.

.EXAMPLE
    .\tools\Rename-BlankMacros.ps1 -Path 'C:\...\WTF\Account\12345#1\macros-cache.txt'

.EXAMPLE
    .\tools\Rename-BlankMacros.ps1 -Path '...\Hunnybuns\macros-cache.txt' -Scope Character -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [ValidateSet('Account', 'Character')] [string] $Scope = 'Account',
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PtrUiSetup/PtrUiSetup.psd1') -Force

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "No file at $Path" }

$running = @(Get-RunningWowProcess)
if ($running.Count -gt 0) {
    Write-Host ''
    Write-Host '  World of Warcraft is running.' -ForegroundColor Red
    Write-Host '  It rewrites macros-cache.txt when it exits, which would undo this.' -ForegroundColor Red
    Write-Host '  Quit the game and run this again.' -ForegroundColor Red
    Write-Host ''
    exit 1
}

$text = Read-TextFileUtf8 -Path $Path
$before = @(Get-MacroCacheEntry -Text $text)
$blank = @($before | Where-Object { $_.IsBlank })

Write-Host ''
Write-Host "  $Path" -ForegroundColor Cyan
Write-Host "  $($before.Count) macro(s), $($blank.Count) with a blank name." -ForegroundColor Cyan

if ($blank.Count -eq 0) {
    Write-Host '  Nothing to do — every macro already has a name of its own.' -ForegroundColor Green
    Write-Host ''
    return
}

$updated = Set-BlankMacroName -Text $text -Scope $Scope
if ($null -eq $updated) {
    Write-Host '  Already named — the blanks are the invisible names this writes.' -ForegroundColor Green
    Write-Host ''
    return
}

# Shown as code points, because the whole point is that they look like nothing.
$after = @(Get-MacroCacheEntry -Text $updated)
Write-Host ''
Write-Host '  New names (invisible on a bar; shown here as code points):' -ForegroundColor Cyan
foreach ($entry in ($after | Select-Object -First 5)) {
    $points = (@($entry.Name.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
    Write-Host "    $points"
}
if ($after.Count -gt 5) { Write-Host "    … and $($after.Count - 5) more" }

if (-not $Apply) {
    Write-Host ''
    Write-Host '  Nothing written. Run it again with -Apply to make the change.' -ForegroundColor Yellow
    Write-Host ''
    return
}

$backup = "$Path.before-rename"
Copy-Item -LiteralPath $Path -Destination $backup -Force
Write-TextFileNoBom -Path $Path -Content $updated

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host "  The file as it was is at: $backup" -ForegroundColor Green
Write-Host '  Log in once and check your bars still look right, then re-save your' -ForegroundColor Green
Write-Host '  action bar profile — the old one was written when the names matched.' -ForegroundColor Green
Write-Host ''
