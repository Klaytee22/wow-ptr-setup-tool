<#
.SYNOPSIS
    Give blank-named macros a unique name, without putting text on the bars.

.DESCRIPTION
    macros-cache.txt holds one record per macro:

        VER 3 0100000001000002 " " "134400"
        #showtooltip taunt
        /cast taunt
        END

    The quoted field after the id is the name. Classic prints that name on the
    action button, so anyone who wants clean bars ends up naming every macro the
    same single space — and then everything that identifies a macro by name has
    nothing to work with. ActionBarSaver says so outright: it "will not work
    properly if you have multiple macros with the same name", which is why an
    action bar restore fails with a page of "unable to restore item to slot".

    So the blank ones are given names that are unique but still render as
    nothing. Two characters that both draw as blank space act as binary digits:

        space           U+0020
        no-break space  U+00A0

    Counting in those gives 30 macros names of at most five characters, well
    inside any name length limit, and every one of them invisible on a bar.

    Two things make this safe to rely on. The single space already in the file
    proves the client keeps a whitespace name across a logout rather than
    trimming it away, so this is a small step from something known to work. And
    the two scopes get different leading characters, because account-wide and
    character-specific macros share one namespace in game: numbering each file
    from zero without that would hand the same name to one of each.

    Only blank names are touched. A macro the user has actually named is left
    exactly as it is, including duplicates of each other — renaming something
    somebody chose is not this tool's business.
#>

# Both render as blank. NBSP is in effectively every font WoW ships, which the
# more exotic Unicode spaces are not — a name that renders as a tofu box would
# be worse than the problem.
$script:MacroNameDigits = @([char]0x20, [char]0xA0)

# Account-wide and character-specific macros are one namespace to anything
# reading them in game, so the two files start from different characters and
# cannot collide however they are numbered.
$script:MacroNamePrefix = @{ Account = [char]0x20; Character = [char]0xA0 }

# VER <version> <id> "<name>" "<icon>"
$script:MacroHeaderPattern = '^(?<lead>VER\s+\d+\s+\S+\s+")(?<name>(?:[^"\\]|\\.)*)(?<tail>"\s+"(?:[^"\\]|\\.)*"\s*)$'

function Get-BlankMacroName {
    <#
    .SYNOPSIS
        The Index'th name in a sequence of unique, invisible macro names.

    .DESCRIPTION
        Bijective base two over the two blank characters, so index 0 is the
        prefix on its own and the length grows only as far as it has to. The
        first name is a single space, which is what these macros are already
        called — one fewer thing changing.
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
    # back with the whole string in one element.
    $lines = $Text -split "`r?`n"
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = $pattern.Match($lines[$index])
        if (-not $match.Success) { continue }
        $name = $match.Groups['name'].Value
        $entries.Add([pscustomobject]@{
                Line    = $index
                Name    = $name
                IsBlank = [string]::IsNullOrWhiteSpace($name)
            })
    }
    return @($entries)
}

function Set-BlankMacroName {
    <#
    .SYNOPSIS
        The same cache with every blank-named macro uniquely named, or $null
        when there were none.

    .DESCRIPTION
        Only the name field of the header line changes. Bodies, icons, ids,
        ordering and line endings are left exactly as they were — this file is
        read by the game and nothing in it is ours to tidy up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [ValidateSet('Account', 'Character')] [string] $Scope = 'Account'
    )

    $entries = @(Get-MacroCacheEntry -Text $Text)
    $blank = @($entries | Where-Object { $_.IsBlank })
    if ($blank.Count -eq 0) { return $null }

    # Names already in the file are out of bounds, so a generated one can never
    # land on a macro the user named themselves.
    $taken = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        if (-not $entry.IsBlank) { $null = $taken.Add($entry.Name) }
    }

    $newline = if ($Text.IndexOf("`r`n", [System.StringComparison]::Ordinal) -ge 0) { "`r`n" } else { "`n" }
    $lines = $Text -split "`r?`n"
    $pattern = [regex] $script:MacroHeaderPattern

    $next = 0
    $changed = $false
    foreach ($entry in $blank) {
        do {
            $name = Get-BlankMacroName -Index $next -Scope $Scope
            $next++
        } while ($taken.Contains($name))
        $null = $taken.Add($name)

        if ([string]::Equals($entry.Name, $name, [System.StringComparison]::Ordinal)) { continue }
        $match = $pattern.Match($lines[$entry.Line])
        $lines[$entry.Line] = $match.Groups['lead'].Value + $name + $match.Groups['tail'].Value
        $changed = $true
    }

    if (-not $changed) { return $null }
    return ($lines -join $newline)
}

function New-MacroNamePlan {
    <#
    .SYNOPSIS
        Named-up copies of the macro caches a plan is about to write.

    .DESCRIPTION
        Driven from the copy plan, and standing in for the plain copies of the
        same files, exactly as the AceDB patch and the profile keys do. A file
        already named up comes back as a skip rather than as nothing, so the
        plain copy does not put the blank-named original back on the next Apply.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [psobject[]] $Action,
        [ValidateSet('Account', 'Character')] [string] $Scope = 'Account',
        [bool] $Overwrite = $true
    )

    $named = [System.Collections.Generic.List[psobject]]::new()
    foreach ($item in @($Action)) {
        if (-not $item -or -not $item.Source) { continue }
        $leaf = [System.IO.Path]::GetFileName($item.Destination)
        if ($leaf -ne 'macros-cache.txt' -and $leaf -ne 'macros-cache.wtf') { continue }

        $exists = Test-Path -LiteralPath $item.Destination -PathType Leaf
        if ($exists -and -not $Overwrite) { continue }

        $updated = Set-BlankMacroName -Text (Read-TextFileUtf8 -Path $item.Source) -Scope $Scope
        if ($null -eq $updated) { continue }

        $size = [System.Text.Encoding]::UTF8.GetByteCount($updated)
        $note = 'blank macro names made unique'

        if ($exists) {
            $existing = Get-Item -LiteralPath $item.Destination
            if ($existing.Length -eq $size -and
                [string]::Equals((Read-TextFileUtf8 -Path $item.Destination), $updated, [System.StringComparison]::Ordinal)) {
                $named.Add((New-FileAction -Kind 'skip' -Destination $item.Destination -Size $size -Note 'macro names already unique'))
                continue
            }
            $named.Add((New-FileAction -Kind 'overwrite' -Destination $item.Destination -Size $size -Note $note -Content $updated))
            continue
        }

        $named.Add((New-FileAction -Kind 'create' -Destination $item.Destination -Size $size -Note $note -Content $updated))
    }

    return @($named)
}
