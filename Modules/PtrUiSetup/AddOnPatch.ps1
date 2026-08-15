<#
.SYNOPSIS
    Fix, on the way over, the library bug that stops Ace3 addons loading on a PTR.

.DESCRIPTION
    AceDB-3.0 builds its scope keys when an addon initialises, and one of them
    comes out of a five-entry table:

        local regionTable = { "US", "KR", "EU", "TW", "CN" }
        local regionKey = regionTable[GetCurrentRegion()]
        local factionrealmregionKey = factionrealmKey .. " - " .. regionKey

    A PTR realm reports a region id that is not in that table, so regionKey is
    nil and the concatenation on the next line throws. OnInitialize dies with it,
    the addon never registers its slash commands, and it looks for all the world
    as though it was never copied. It works on live and fails on the PTR, every
    time, on the same code.

    The blast radius is not one addon. Ace3 libraries are shared through LibStub
    and the highest version present wins, so a single addon carrying a stale copy
    takes down every Ace3 addon on the PTR at once.

    So this gives the lookup a fallback. Three things keep it honest:

    - It only ever writes to the PTR. The live copy is read and left alone, which
      is the invariant the whole tool rests on.
    - It only touches files named AceDB-3.0.lua, and only the one assignment.
    - A file that already has a fallback is left alone, so a current Ace3 and a
      hand-patched copy both pass through untouched.

    It is a workaround for a bug fixed upstream. Updating the addon is the better
    answer and the warning says so.
#>

$script:AceDbFileName = 'AceDB-3.0.lua'

# Any region the fallback names is fine. The value only namespaces
# factionrealmregion-scoped data, which nothing reads on a PTR anyway — what
# matters is that it is a string rather than nil.
$script:AceDbFallbackRegion = 'US'

# The assignment, in the forms Ace3 has shipped it in: a local taking a region
# table indexed by GetCurrentRegion(). The lookahead is what makes running this
# twice a no-op, and what leaves a current Ace3 alone — anything that already
# has an "or" after the bracket is already guarded.
$script:AceDbRegionPattern =
'(?<assign>(?<indent>[ \t]*)local[ \t]+(?<name>\w*[Rr]egion\w*)[ \t]*=[ \t]*(?<table>\w+)[ \t]*\[[ \t]*GetCurrentRegion\(\)[ \t]*\])(?![ \t]*or\b)'

function Test-AceDbRegionBug {
    <#
    .SYNOPSIS
        True when this AceDB source would fail on a PTR realm.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    return ([regex]::IsMatch($Text, $script:AceDbRegionPattern))
}

function Update-AceDbRegionKey {
    <#
    .SYNOPSIS
        The same source with the region lookup given a fallback, or $null when
        there was nothing to change.

    .DESCRIPTION
        A splice of one expression, not a rewrite of the file: everything else —
        line endings, comments, the library's own version number — is left byte
        for byte as it was, because this is somebody else's code and the less of
        it that moves the better.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    if (-not (Test-AceDbRegionBug -Text $Text)) { return $null }

    $replacement = '${assign} or "' + $script:AceDbFallbackRegion + '"'
    $updated = [regex]::Replace($Text, $script:AceDbRegionPattern, $replacement)
    if ([string]::Equals($updated, $Text, [System.StringComparison]::Ordinal)) { return $null }
    return $updated
}

function New-AceDbPatchPlan {
    <#
    .SYNOPSIS
        Patched versions of the AceDB copies an addon plan is about to make.

    .DESCRIPTION
        Driven from the copy plan rather than from a second walk of the tree, so
        the destinations are exactly the ones the copy would have written and the
        expensive part — enumerating a real AddOns folder — happens once.

        Actions come back for every AceDB the plan touches, including ones
        already correct on the PTR, because the caller swaps these in for the
        plain copies of the same files. Leave one out and the plain copy puts the
        unpatched file back on the next Apply, undoing this every time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [psobject[]] $Action,
        [bool] $Overwrite = $true
    )

    $patched = [System.Collections.Generic.List[psobject]]::new()
    foreach ($item in @($Action)) {
        if (-not $item -or -not $item.Source) { continue }
        if ([System.IO.Path]::GetFileName($item.Destination) -ne $script:AceDbFileName) { continue }

        $exists = Test-Path -LiteralPath $item.Destination -PathType Leaf
        if ($exists -and -not $Overwrite) { continue }

        $updated = Update-AceDbRegionKey -Text (Read-TextFileUtf8 -Path $item.Source)
        if ($null -eq $updated) { continue }

        $size = [System.Text.Encoding]::UTF8.GetByteCount($updated)
        $note = 'region fallback for PTR realms'

        if ($exists) {
            $existing = Get-Item -LiteralPath $item.Destination
            if ($existing.Length -eq $size -and
                [string]::Equals((Read-TextFileUtf8 -Path $item.Destination), $updated, [System.StringComparison]::Ordinal)) {
                $patched.Add((New-FileAction -Kind 'skip' -Destination $item.Destination -Size $size -Note 'already patched'))
                continue
            }
            $patched.Add((New-FileAction -Kind 'overwrite' -Destination $item.Destination -Size $size -Note $note -Content $updated))
            continue
        }

        $patched.Add((New-FileAction -Kind 'create' -Destination $item.Destination -Size $size -Note $note -Content $updated))
    }

    return @($patched)
}
