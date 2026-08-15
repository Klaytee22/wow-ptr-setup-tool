<#
.SYNOPSIS
    Make macro names unique without changing what any of them look like.

.DESCRIPTION
    macros-cache.txt holds one record per macro:

        VER 3 0100000001000002 " " "134400"
        #showtooltip taunt
        /cast taunt
        END

    The quoted field after the id is the name, and anything that identifies a
    macro by name needs those to be distinct. ActionBarSaver says so outright:
    it "will not work properly if you have multiple macros with the same name",
    and an action bar restore then fails with a page of "unable to restore item
    to slot".

    The problem is duplication, not blankness. Classic prints a macro's name on
    its action button, so wanting clean bars leads to naming every macro the
    same single space — that is the common case, and it is thirty conflicts
    rather than a special kind of name. Two macros both called "weps" break the
    same thing just as thoroughly.

    So: group by name, leave the first of each group exactly as it is, and give
    the rest a suffix built from characters that draw as nothing —

        space           U+0020
        no-break space  U+00A0

    counted in binary. "weps" stays "weps" on the bar and becomes unique to
    anything reading it; a macro whose name is already its own is never touched
    at all.

    Two things make this safe to rely on. The single space these macros already
    carry proves the client keeps a whitespace name across a logout rather than
    trimming it away, so this is a short step from something known to work. And
    the two scopes take different suffix characters, because account-wide and
    character-specific macros are one namespace to anything reading them in
    game.

    What it does not do is reconcile the two files against each other: a macro
    named "weps" in each, unique within its own file, stays that way. Fixing
    that would mean holding both files at once, and within-file duplication is
    the case that actually happens.
#>

# Both render as blank. NBSP is in effectively every font WoW ships, which the
# more exotic Unicode spaces are not — a name that came out as a tofu box would
# be worse than the problem.
$script:MacroNameDigits = @([char]0x20, [char]0xA0)

# Account-wide and character-specific macros are one namespace to anything
# reading them in game, so a suffix generated for one file can never equal one
# generated for the other.
$script:MacroNamePrefix = @{ Account = [char]0x20; Character = [char]0xA0 }

# VER <version> <id> "<name>" "<icon>"
$script:MacroHeaderPattern = '^(?<lead>VER\s+\d+\s+\S+\s+")(?<name>(?:[^"\\]|\\.)*)(?<tail>"\s+"(?:[^"\\]|\\.)*"\s*)$'

function Get-InvisibleMacroSuffix {
    <#
    .SYNOPSIS
        The Index'th suffix in a sequence of unique, invisible strings.

    .DESCRIPTION
        Bijective base two over the two blank characters, after the scope's own
        character, so the length grows only as far as it has to: a hundred
        conflicts need eight characters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Index,
        [ValidateSet('Account', 'Character')] [string] $Scope = 'Account'
    )

    $digits = ''
    $remaining = $Index
    while ($remaining -gt 0) {
        $remaining--
        $digits = [string]$script:MacroNameDigits[$remaining % 2] + $digits
        $remaining = [Math]::Floor($remaining / 2)
    }
    return ([string]$script:MacroNamePrefix[$Scope] + $digits)
}

function Get-MacroCacheEntry {
    <#
    .SYNOPSIS
        The macro records in a cache, with the line each header sits on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $entries = [System.Collections.Generic.List[psobject]]::new()
    $pattern = [regex] $script:MacroHeaderPattern

    # No max-substrings argument: PowerShell's -split keeps trailing empty
    # entries on its own, and passing -1 does not mean "unlimited" — it comes
    # back with the whole string in a single element.
    $lines = $Text -split "`r?`n"
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = $pattern.Match($lines[$index])
        if (-not $match.Success) { continue }
        $entries.Add([pscustomobject]@{
                Line = $index
                Name = $match.Groups['name'].Value
            })
    }
    return @($entries)
}

function Get-MacroNameConflict {
    <#
    .SYNOPSIS
        The names that more than one macro in a cache is using.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $seen = @{}
    foreach ($entry in (Get-MacroCacheEntry -Text $Text)) {
        if ($seen.ContainsKey($entry.Name)) { $seen[$entry.Name]++ } else { $seen[$entry.Name] = 1 }
    }

    $conflicts = [System.Collections.Generic.List[psobject]]::new()
    foreach ($name in $seen.Keys) {
        if ($seen[$name] -lt 2) { continue }
        $conflicts.Add([pscustomobject]@{ Name = $name; Count = $seen[$name] })
    }
    return @($conflicts | Sort-Object Count -Descending)
}

function Resolve-MacroNameConflict {
    <#
    .SYNOPSIS
        The same cache with every duplicated name made unique, or $null when
        none were.

    .DESCRIPTION
        The first macro of each duplicated name keeps it, so the smallest
        possible number of names change and one of every group still reads
        exactly as the user wrote it. Only the name field of a header line is
        touched: bodies, icons, ids, ordering and line endings are left as they
        were, because this file is read by the game and nothing in it is ours to
        tidy up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [ValidateSet('Account', 'Character')] [string] $Scope = 'Account'
    )

    $entries = @(Get-MacroCacheEntry -Text $Text)
    if ($entries.Count -eq 0) { return $null }

    # Every name in the file is out of bounds for a generated one, so a suffix
    # can never land on a name some other macro is already using.
    $taken = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $entries) { $null = $taken.Add($entry.Name) }

    $lines = $Text -split "`r?`n"
    $newline = if ($Text.IndexOf("`r`n", [System.StringComparison]::Ordinal) -ge 0) { "`r`n" } else { "`n" }
    $pattern = [regex] $script:MacroHeaderPattern

    $used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $next = 0
    $changed = $false

    foreach ($entry in $entries) {
        # The first macro to claim a name keeps it. Everything after it is a
        # conflict and gets a suffix.
        if ($used.Add($entry.Name)) { continue }

        do {
            $candidate = $entry.Name + (Get-InvisibleMacroSuffix -Index $next -Scope $Scope)
            $next++
        } while ($taken.Contains($candidate))

        $null = $taken.Add($candidate)
        $null = $used.Add($candidate)

        $match = $pattern.Match($lines[$entry.Line])
        $lines[$entry.Line] = $match.Groups['lead'].Value + $candidate + $match.Groups['tail'].Value
        $changed = $true
    }

    if (-not $changed) { return $null }
    return ($lines -join $newline)
}

function New-MacroNameFixPlan {
    <#
    .SYNOPSIS
        Plan a macro cache being made unique where it already sits.

    .DESCRIPTION
        In place, not copied: this is for the live client, where the file is
        already the one the game reads. Source is left empty and the whole
        rewritten text goes in Content, so Invoke-FileActionPlan backs the
        original up and writes the new one exactly as it does for Config.wtf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('Account', 'Character')] [string] $Scope = 'Account'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    $text = Read-TextFileUtf8 -Path $Path
    $conflicts = @(Get-MacroNameConflict -Text $text)
    if ($conflicts.Count -eq 0) { return @() }

    $updated = Resolve-MacroNameConflict -Text $text -Scope $Scope
    if ($null -eq $updated) { return @() }

    $affected = (@($conflicts | ForEach-Object { $_.Count - 1 }) | Measure-Object -Sum).Sum
    return @(New-FileAction -Kind 'overwrite' -Destination $Path `
            -Size ([System.Text.Encoding]::UTF8.GetByteCount($updated)) `
            -Note "$affected macro(s) renamed, $($conflicts.Count) name(s) were shared" -Content $updated)
}

function Get-LiveMacroCachePath {
    <#
    .SYNOPSIS
        The macro caches on the live client that this context covers.

    .DESCRIPTION
        The account-level one, and one per mapped character. Only files that
        exist come back, so a caller can walk the result without checking.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [psobject] $Context)

    $paths = [System.Collections.Generic.List[string]]::new()
    $accountDir = Get-ContextAccountPath -Context $Context -Side 'Source'
    if ($accountDir) {
        $account = Join-Path $accountDir 'macros-cache.txt'
        if (Test-Path -LiteralPath $account -PathType Leaf) { $paths.Add($account) }
    }
    foreach ($pair in (Get-ContextCharacter -Context $Context)) {
        if (-not $pair.Source) { continue }
        $character = Join-Path (Get-WowCharacterPath -Install $Context.Source -Character $pair.Source) 'macros-cache.txt'
        if (Test-Path -LiteralPath $character -PathType Leaf) { $paths.Add($character) }
    }
    return @($paths)
}

function Get-ActionBarAddOn {
    <#
    .SYNOPSIS
        Action bar saver addons installed in a client, by folder name.

    .DESCRIPTION
        Only used to tell the user whether they still have to go and install
        one. Matched loosely on purpose: there are several of these, new ones
        appear, and naming the one that is there is useful while saying nothing
        about an unusual one is harmless.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [psobject] $Install)

    if (-not (Test-Path -LiteralPath $Install.AddOns -PathType Container)) { return @() }
    $found = Get-ChildItem -LiteralPath $Install.AddOns -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'actionbar.*(saver|profile)|^abs' }
    return @($found | ForEach-Object { $_.Name } | Sort-Object)
}
