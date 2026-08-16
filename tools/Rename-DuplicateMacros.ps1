<#
.SYNOPSIS
    Make duplicated macro names unique without changing how they look.

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

    The first macro of each duplicated name keeps it; the rest get a suffix
    built from spaces and no-break spaces, so they are unique to anything
    reading them and look identical on a bar. A macro whose name is already its
    own is not touched. Nothing else in the file changes: bodies, icons, ids,
    ordering and line endings all survive.

    One file at a time, so the account file and each character's have to be
    reconciled against each other with -Reserve. The window's step does that
    for you; this does not do it by itself.

    QUIT WORLD OF WARCRAFT FIRST. It rewrites macros-cache.txt when it exits and
    will put the old names straight back.

.PARAMETER Path
    A macros-cache.txt. Both levels have one and both are worth doing:
        <WoW>\_anniversary_\WTF\Account\<ACCOUNT>\macros-cache.txt
        <WoW>\_anniversary_\WTF\Account\<ACCOUNT>\<Realm>\<Character>\macros-cache.txt

.PARAMETER Scope
    Account for the account-level file, Character for a character's own. The two
    sets share one namespace in game, so the suffixes are drawn from different
    characters and a generated name in one can never equal one in the other.

.PARAMETER Reserve
    Other macros-cache.txt files whose names are already spoken for. In game
    there is one namespace: a macro called CORE in the account file and another
    in a character's collide exactly as if they were in one file, and fixing
    each file on its own leaves that pair untouched. Do the account file first,
    then pass it here when you do each character.

.PARAMETER Apply
    Write the change. Without it this only reports what it would do.

.EXAMPLE
    .\tools\Rename-DuplicateMacros.ps1 -Path 'C:\...\WTF\Account\12345#1\macros-cache.txt'

.EXAMPLE
    .\tools\Rename-DuplicateMacros.ps1 -Path '...\Hunnybuns\macros-cache.txt' -Scope Character -Apply `
        -Reserve 'C:\...\WTF\Account\12345#1\macros-cache.txt'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [ValidateSet('Account', 'Character')] [string] $Scope = 'Account',
    [string[]] $Reserve,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PtrUiSetup/PtrUiSetup.psd1') -Force

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "No file at $Path" }

$reserved = [System.Collections.Generic.List[string]]::new()
foreach ($other in @($Reserve)) {
    if (-not $other) { continue }
    if (-not (Test-Path -LiteralPath $other -PathType Leaf)) { throw "No file at $other" }
    foreach ($entry in (Get-MacroCacheEntry -Text (Read-TextFileUtf8 -Path $other))) {
        $reserved.Add($entry.Name)
    }
}

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
$conflicts = @(Get-MacroNameConflict -Text $text)

# A name unique in this file but already taken by a reserved one is a conflict
# just the same — that is the whole reason -Reserve exists.
$spokenFor = [System.Collections.Generic.HashSet[string]]::new(
    [string[]] @($reserved), [System.StringComparer]::Ordinal)
$clashes = @($before | Where-Object { $spokenFor.Contains($_.Name) }).Count

Write-Host ''
Write-Host "  $Path" -ForegroundColor Cyan
Write-Host "  $($before.Count) macro(s), $($conflicts.Count) name(s) used more than once." -ForegroundColor Cyan
foreach ($conflict in ($conflicts | Select-Object -First 5)) {
    $shown = if ([string]::IsNullOrWhiteSpace($conflict.Name)) { '(blank)' } else { $conflict.Name }
    Write-Host "    $($conflict.Count) x `"$shown`""
}
if ($clashes) {
    Write-Host "  $clashes also share a name with one of the $(@($Reserve).Count) reserved file(s)." -ForegroundColor Cyan
}

if ($conflicts.Count -eq 0 -and $clashes -eq 0) {
    Write-Host '  Nothing to do — every macro already has a name of its own.' -ForegroundColor Green
    Write-Host ''
    return
}

$updated = Resolve-MacroNameConflict -Text $text -Scope $Scope -Reserved @($reserved)
if ($null -eq $updated) {
    Write-Host '  Already unique — the ties are broken by the invisible suffixes this writes.' -ForegroundColor Green
    Write-Host ''
    return
}

# Counted from what actually changed rather than from the conflict list, so a
# name pulled in by -Reserve is included the same as one duplicated here.
$after = @(Get-MacroCacheEntry -Text $updated)
$affected = 0
for ($index = 0; $index -lt $after.Count; $index++) {
    if ($after[$index].Name -cne $before[$index].Name) { $affected++ }
}

# Shown as code points, because the whole point is that they look like nothing.
Write-Host ''
Write-Host "  $affected macro(s) get a suffix (invisible on a bar; code points shown):" -ForegroundColor Cyan
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
