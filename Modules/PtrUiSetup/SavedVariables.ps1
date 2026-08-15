<#
.SYNOPSIS
    Point copied addon profiles at the PTR character instead of the live one.

.DESCRIPTION
    Most addon configuration libraries — AceDB-3.0, which Bartender4, ElvUI,
    Details and a long tail of others sit on — keep a `profileKeys` table in the
    account-level SavedVariables file:

        Bartender4DB = {
            ["profileKeys"] = {
                ["Sunderfury - Whitemane"] = "Sunderfury - Whitemane",
            },
            ["profiles"] = { ... },
        }

    The key is the character's name and realm, and the value names the profile
    that character loads. Copying the file to the PTR brings every profile
    across, but the PTR character's realm is different — "Classic PTR Realm 1"
    rather than "Whitemane" — so there is no matching key, and the addon comes
    up on its default profile with the real one sitting unused in the same file.

    That is the gap the source guide papers over with "Log in and go to each
    addon and copy the profile from your Live Character's profile". Adding one
    key per mapped character closes it: the PTR character loads the same profile
    its live counterpart did, so the bars are where they were on the first login.

    Nothing else in the file is touched. Only files that already hold a key for
    the live character are rewritten at all, and a rewrite that would change
    nothing produces no action, so a second run reports itself done.
#>

# A megabyte at a time. The probe's cost is almost all string allocation, so
# fewer, larger chunks is most of the difference: at 64 KB a 120 MB folder took
# 580ms to scan, at 1 MB it takes a fraction of that.
$script:LuaProbeChunk = 1048576

# What the probe found last time, keyed by path, size and write time, so a plan
# rebuilt because the user changed a dropdown does not re-read the folder. Any
# edit to a file changes the key, so a stale answer cannot be served.
$script:LuaProbeSeen = @{}
$script:LuaProbeLimit = 2048

function Read-TextFileUtf8 {
    <#
    .SYNOPSIS
        Read a file as UTF-8, honouring a byte-order mark if there is one.

    .DESCRIPTION
        Get-Content -Raw decodes with the machine's ANSI code page on Windows
        PowerShell 5.1, which mangles every accented character name in the file.
        SavedVariables are UTF-8, so they are read as UTF-8 on both editions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function ConvertFrom-LuaString {
    <#
    .SYNOPSIS
        The text a Lua string literal stands for, given its contents.

    .DESCRIPTION
        Takes what is between the quotes and resolves the escapes. WoW writes
        every byte outside printable ASCII as a decimal escape, so an accented
        character name arrives as \195\169 rather than as é — the escapes are
        bytes, not characters, and only mean anything once the whole run has
        been decoded as UTF-8. That is why this builds a byte list rather than
        a string.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Literal)

    $bytes = [System.Collections.Generic.List[byte]]::new()
    $plain = [System.Text.StringBuilder]::new()

    # Runs of ordinary characters are encoded together so a surrogate pair — one
    # character written as two chars — is not cut in half.
    $flush = {
        if ($plain.Length -gt 0) {
            foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes($plain.ToString())) { $bytes.Add($byte) }
            $null = $plain.Clear()
        }
    }

    $index = 0
    while ($index -lt $Literal.Length) {
        $char = $Literal[$index]
        if ($char -ne '\') {
            $null = $plain.Append($char)
            $index++
            continue
        }

        & $flush
        $index++
        if ($index -ge $Literal.Length) { break }

        $next = $Literal[$index]
        if ([char]::IsDigit($next)) {
            # Lua reads at most three digits, so \1959 is byte 195 then a "9".
            $digits = ''
            while ($index -lt $Literal.Length -and [char]::IsDigit($Literal[$index]) -and $digits.Length -lt 3) {
                $digits += $Literal[$index]
                $index++
            }
            $bytes.Add([byte]([int]$digits % 256))
            continue
        }

        switch ($next) {
            'n' { $bytes.Add([byte]10) }
            't' { $bytes.Add([byte]9) }
            'r' { $bytes.Add([byte]13) }
            'a' { $bytes.Add([byte]7) }
            'b' { $bytes.Add([byte]8) }
            'f' { $bytes.Add([byte]12) }
            'v' { $bytes.Add([byte]11) }
            default { foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes([string]$next)) { $bytes.Add($byte) } }
        }
        $index++
    }

    & $flush
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function ConvertTo-LuaString {
    <#
    .SYNOPSIS
        The contents of a Lua string literal standing for this text.

    .DESCRIPTION
        Written the way WoW writes it, so a key this tool adds is
        indistinguishable from one the game wrote: decimal escapes for every
        byte outside printable ASCII, always three digits so a following digit
        in the text cannot be swallowed into the escape.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

    $out = [System.Text.StringBuilder]::new()
    foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes($Value)) {
        switch ($byte) {
            92 { $null = $out.Append('\\') }
            34 { $null = $out.Append('\"') }
            10 { $null = $out.Append('\n') }
            13 { $null = $out.Append('\r') }
            9 { $null = $out.Append('\t') }
            default {
                if ($byte -lt 32 -or $byte -gt 126) { $null = $out.Append(('\{0:D3}' -f $byte)) }
                else { $null = $out.Append([char]$byte) }
            }
        }
    }
    return $out.ToString()
}

function Get-LuaBlockEnd {
    <#
    .SYNOPSIS
        Index of the brace closing the one at Open, or -1 if it never closes.

    .DESCRIPTION
        Braces inside string literals do not count, so the scan has to know
        where the strings are. It jumps between interesting characters rather
        than walking every one: a profileKeys table is small, but the file it
        sits in can run to megabytes, and a per-character PowerShell loop over
        that is seconds rather than milliseconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [int] $Open
    )

    $interesting = [char[]] @('{', '}', '"', "'")
    $depth = 0
    $index = $Open

    while ($index -ge 0 -and $index -lt $Text.Length) {
        $char = $Text[$index]
        if ($char -eq '{') {
            $depth++
            $index++
        }
        elseif ($char -eq '}') {
            $depth--
            if ($depth -le 0) { return $index }
            $index++
        }
        else {
            # A quote. Walk to its unescaped partner and carry on from there.
            $stops = [char[]] @('\', $char)
            $index++
            $closed = $false
            while ($index -le $Text.Length) {
                $stop = $Text.IndexOfAny($stops, $index)
                if ($stop -lt 0) { return -1 }
                if ($Text[$stop] -eq '\') {
                    $index = $stop + 2
                    continue
                }
                $index = $stop + 1
                $closed = $true
                break
            }
            if (-not $closed) { return -1 }
        }

        if ($index -ge $Text.Length) { break }
        $index = $Text.IndexOfAny($interesting, $index)
    }

    return -1
}

function Find-LuaTable {
    <#
    .SYNOPSIS
        Where a named table starts and ends, or $null if there is not one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string] $Name,
        [int] $StartIndex = 0
    )

    if ($StartIndex -ge $Text.Length) { return $null }
    $escaped = [regex]::Escape($Name)
    # WoW always writes the bracketed form; the bare one is here because some
    # addons ship a hand-written defaults file in the same folder.
    $pattern = [regex] ('(?:\[\s*"{0}"\s*\]|(?<![\w.]){0})\s*=\s*\{{' -f $escaped)

    $match = $pattern.Match($Text, [Math]::Max(0, $StartIndex))
    if (-not $match.Success) { return $null }

    $open = $match.Index + $match.Length - 1
    $close = Get-LuaBlockEnd -Text $Text -Open $open
    if ($close -lt 0) { return $null }

    return [pscustomobject]@{ Open = $open; Close = $close }
}

function Get-LuaProfileKey {
    <#
    .SYNOPSIS
        The ["key"] = "value" pairs in a profileKeys body, with their offsets.

    .DESCRIPTION
        Offsets come back alongside the values because rewriting is done by
        splicing the original text rather than by re-serialising the table —
        anything this tool does not understand has to survive untouched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Body)

    $pattern = [regex] '\[\s*"((?:\\.|[^"\\])*)"\s*\]\s*=\s*"((?:\\.|[^"\\])*)"'
    $entries = [System.Collections.Generic.List[psobject]]::new()
    foreach ($match in $pattern.Matches($Body)) {
        $entries.Add([pscustomobject]@{
                Key          = ConvertFrom-LuaString -Literal $match.Groups[1].Value
                ValueLiteral = $match.Groups[2].Value
                ValueStart   = $match.Groups[2].Index
                ValueLength  = $match.Groups[2].Length
                Start        = $match.Index
            })
    }
    return @($entries)
}

function Set-LuaProfileKey {
    <#
    .SYNOPSIS
        A profileKeys body with the PTR characters pointed at the live profiles,
        or $null when it already is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Body,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [psobject[]] $Mapping
    )

    $entries = @(Get-LuaProfileKey -Body $Body)
    if ($entries.Count -eq 0) { return $null }

    $byKey = @{}
    foreach ($entry in $entries) { $byKey[$entry.Key] = $entry }

    # Collected first and applied afterwards from the back, so an edit never
    # moves the offsets of one still to come.
    $edits = [System.Collections.Generic.List[psobject]]::new()
    $inserts = [System.Collections.Generic.List[string]]::new()

    foreach ($pair in $Mapping) {
        if (-not $byKey.ContainsKey($pair.From)) { continue }
        $wanted = $byKey[$pair.From].ValueLiteral

        if ($byKey.ContainsKey($pair.To)) {
            $existing = $byKey[$pair.To]
            if ([string]::Equals($existing.ValueLiteral, $wanted, [System.StringComparison]::Ordinal)) { continue }
            $edits.Add([pscustomobject]@{ Start = $existing.ValueStart; Length = $existing.ValueLength; Text = $wanted })
        }
        else {
            $inserts.Add(('["{0}"] = "{1}",' -f (ConvertTo-LuaString -Value $pair.To), $wanted))
        }
    }

    if ($edits.Count -eq 0 -and $inserts.Count -eq 0) { return $null }

    $result = $Body
    foreach ($edit in ($edits | Sort-Object Start -Descending)) {
        $result = $result.Substring(0, $edit.Start) + $edit.Text + $result.Substring($edit.Start + $edit.Length)
    }

    if ($inserts.Count -gt 0) {
        # New keys go in above the first existing one, wearing its indentation.
        # There is always a first one: a key is only added when the live
        # character's key was found in this very table.
        $anchor = @(Get-LuaProfileKey -Body $result)[0]
        $lineStart = $result.LastIndexOf("`n", $anchor.Start) + 1
        $indent = $result.Substring($lineStart, $anchor.Start - $lineStart)
        if ($indent -match '\S') { $indent = '' }
        $newline = if ($result.IndexOf("`r`n", [System.StringComparison]::Ordinal) -ge 0) { "`r`n" } else { "`n" }

        $block = ''
        foreach ($line in $inserts) { $block += $indent + $line + $newline }
        $result = $result.Substring(0, $lineStart) + $block + $result.Substring($lineStart)
    }

    return $result
}

function Update-LuaProfileKey {
    <#
    .SYNOPSIS
        A whole SavedVariables file with its profile keys pointed at the PTR
        characters, or $null when there is nothing to change.

    .DESCRIPTION
        Every profileKeys table in the file is considered, not just the first —
        one file can hold several addons' databases, and AceDB namespaces nest
        their own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [psobject[]] $Mapping
    )

    if (-not $Mapping) { return $null }
    if ($Text.IndexOf('profileKeys', [System.StringComparison]::Ordinal) -lt 0) { return $null }

    $result = $Text
    $changed = $false
    $from = 0

    while ($true) {
        $table = Find-LuaTable -Text $result -Name 'profileKeys' -StartIndex $from
        if (-not $table) { break }

        $body = $result.Substring($table.Open + 1, $table.Close - $table.Open - 1)
        $updated = Set-LuaProfileKey -Body $body -Mapping $Mapping
        if ($null -eq $updated) {
            $from = $table.Close + 1
            continue
        }

        $result = $result.Substring(0, $table.Open + 1) + $updated + $result.Substring($table.Close)
        $changed = $true
        $from = $table.Open + 1 + $updated.Length + 1
    }

    if (-not $changed) { return $null }
    return $result
}

function Test-LuaProfileFile {
    <#
    .SYNOPSIS
        True when a file mentions profileKeys at all.

    .DESCRIPTION
        A cheap gate in front of the expensive part. Plans are rebuilt every
        time the window's selection changes, and a SavedVariables folder holds
        files that run to tens of megabytes; loading each of those into a string
        only to reject it costs both the read and twice its size in memory. This
        reads in chunks and stops at the first hit, keeping a few characters of
        overlap so a match straddling a chunk boundary is still found, and
        remembers the answer against the file's size and write time.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $needle = 'profileKeys'
    $stream = $null
    $memo = $null
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $memo = '{0}|{1}|{2}' -f $item.FullName, $item.Length, $item.LastWriteTimeUtc.Ticks
        if ($script:LuaProbeSeen.ContainsKey($memo)) { return [bool]$script:LuaProbeSeen[$memo] }
        if ($script:LuaProbeSeen.Count -ge $script:LuaProbeLimit) { $script:LuaProbeSeen.Clear() }

        $stream = [System.IO.File]::OpenRead($Path)
        $buffer = [byte[]]::new($script:LuaProbeChunk)
        $carry = ''
        $found = $false
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            # ASCII on purpose: every byte over 127 decodes to a character that
            # cannot appear in the needle, so nothing can match by accident.
            $chunk = $carry + [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
            if ($chunk.IndexOf($needle, [System.StringComparison]::Ordinal) -ge 0) {
                $found = $true
                break
            }
            $keep = [Math]::Min($needle.Length - 1, $chunk.Length)
            $carry = $chunk.Substring($chunk.Length - $keep)
        }

        $script:LuaProbeSeen[$memo] = $found
        return $found
    }
    catch {
        # An unreadable file is one the copy will fail on anyway; saying no here
        # leaves it to the plain copy to report. Not remembered, in case the
        # reason it could not be read was temporary.
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Clear-LuaProbeCache {
    <#
    .SYNOPSIS
        Forget what the probe has seen. For tests; nothing else needs it.
    #>
    [CmdletBinding()]
    param()
    $script:LuaProbeSeen.Clear()
}

function Get-PtrSetupProfileMapping {
    <#
    .SYNOPSIS
        The live-key → PTR-key pairs implied by a context's character mapping.

    .DESCRIPTION
        AceDB keys a character as "Name - Realm", built in game from
        UnitName and GetRealmName. What this has to hand is the folder name WoW
        writes under WTF\Account\<ACCOUNT>\, and the two are usually the same
        string — but only usually, which is not good enough: a key that does not
        match is a key nothing ever reads, and the addon quietly starts on its
        default with the right profile sitting unused beside it.

        So the constructed key is a fallback. ToName is carried alongside it so
        the planner can look for what the game itself wrote in the PTR's own copy
        of the file and prefer that, which needs no assumption at all.

        A pair whose two sides are identical is left out — the key the addon
        looks up is then already there.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [psobject] $Context)

    $mapping = [System.Collections.Generic.List[psobject]]::new()
    foreach ($pair in (Get-ContextCharacter -Context $Context)) {
        if (-not $pair.Source -or -not $pair.Target) { continue }
        $from = '{0} - {1}' -f $pair.Source.Name, $pair.Source.Realm
        $to = '{0} - {1}' -f $pair.Target.Name, $pair.Target.Realm
        if ([string]::Equals($from, $to, [System.StringComparison]::Ordinal)) { continue }
        $mapping.Add([pscustomobject]@{ From = $from; To = $to; ToName = $pair.Target.Name })
    }
    return @($mapping)
}

function Get-LuaProfileKeyForCharacter {
    <#
    .SYNOPSIS
        The keys in a file that the game itself wrote for this character.

    .DESCRIPTION
        AceDB writes profileKeys["Name - Realm"] the first time a character logs
        in, so the PTR's own copy of the file is a statement of fact about how
        that character is keyed on that realm — no guessing at what GetRealmName
        returns, and no assumption that it matches the folder name.

        Everything before the first " - " is the character name. Realm names
        contain spaces and hyphens of their own, so the split has to be on the
        first separator and nowhere else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $Name
    )

    $found = [System.Collections.Generic.List[string]]::new()
    if ($Text.IndexOf('profileKeys', [System.StringComparison]::Ordinal) -lt 0) { return @($found) }

    $prefix = "$Name - "
    $from = 0
    while ($true) {
        $table = Find-LuaTable -Text $Text -Name 'profileKeys' -StartIndex $from
        if (-not $table) { break }
        $body = $Text.Substring($table.Open + 1, $table.Close - $table.Open - 1)
        foreach ($entry in (Get-LuaProfileKey -Body $body)) {
            if ($entry.Key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
                -not $found.Contains($entry.Key)) {
                $found.Add($entry.Key)
            }
        }
        $from = $table.Close + 1
    }
    return @($found)
}

function Resolve-ProfileKeyMapping {
    <#
    .SYNOPSIS
        A mapping with the PTR key replaced by what the game actually wrote,
        where the destination file says.

    .DESCRIPTION
        Both keys are kept when they differ. An extra entry in profileKeys is
        inert — AceDB reads only the one matching the character logging in — so
        writing both costs nothing and means the profile is found whichever of
        the two naming schemes turns out to be right. Getting this wrong is not
        a visible error; it is bars in the wrong places and no clue why.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [psobject[]] $Mapping,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $DestinationText
    )

    $resolved = [System.Collections.Generic.List[psobject]]::new()
    foreach ($pair in @($Mapping)) {
        $resolved.Add($pair)
        if (-not $pair.PSObject.Properties.Name.Contains('ToName') -or -not $pair.ToName) { continue }

        foreach ($actual in (Get-LuaProfileKeyForCharacter -Text $DestinationText -Name $pair.ToName)) {
            if ([string]::Equals($actual, $pair.To, [System.StringComparison]::Ordinal)) { continue }
            $resolved.Add([pscustomobject]@{ From = $pair.From; To = $actual; ToName = $pair.ToName })
        }
    }
    return @($resolved)
}

function New-ProfileKeyPlan {
    <#
    .SYNOPSIS
        Plan the rewritten copies of the .lua files that carry profile keys.

    .DESCRIPTION
        These files are also in the plain copy plan for the same folder, and the
        caller replaces those actions with these — see Merge-FileActionPlan.
        A file that is already correct on the PTR comes back as a skip rather
        than as nothing, so the copy it replaces is suppressed too: without that
        the plain copy would put the unmodified live file back on every run and
        undo the rewrite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [psobject[]] $Mapping,
        [bool] $Overwrite = $true
    )

    $actions = [System.Collections.Generic.List[psobject]]::new()
    if (-not $Mapping) { return @($actions) }
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return @($actions) }

    foreach ($file in (Get-ChildItem -LiteralPath $Source -Filter '*.lua' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if (-not (Test-LuaProfileFile -Path $file.FullName)) { continue }

        $target = Join-Path $Destination $file.Name
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        # Told not to overwrite, the plain copy leaves this file alone and so
        # does this: the option is the user saying the PTR's own file wins.
        if ($exists -and -not $Overwrite) { continue }

        # The destination is read first when it is there, so the keys the game
        # wrote for these characters can be used in place of guessed ones.
        if ($exists) { $destinationText = Read-TextFileUtf8 -Path $target } else { $destinationText = '' }
        $resolved = @(Resolve-ProfileKeyMapping -Mapping $Mapping -DestinationText $destinationText)

        $updated = Update-LuaProfileKey -Text (Read-TextFileUtf8 -Path $file.FullName) -Mapping $resolved
        if ($null -eq $updated) { continue }

        $size = [System.Text.Encoding]::UTF8.GetByteCount($updated)
        $note = 'profile follows your live character'

        if ($exists) {
            # Length first: on the run after this one the two match and the file
            # is read once to be sure; on the run before, they differ and it is
            # not read at all.
            $existing = Get-Item -LiteralPath $target
            if ($existing.Length -eq $size -and
                [string]::Equals($destinationText, $updated, [System.StringComparison]::Ordinal)) {
                $actions.Add((New-FileAction -Kind 'skip' -Destination $target -Size $size -Note 'profile already points at the PTR character'))
                continue
            }
            $actions.Add((New-FileAction -Kind 'overwrite' -Destination $target -Size $size -Note $note -Content $updated))
            continue
        }

        $actions.Add((New-FileAction -Kind 'create' -Destination $target -Size $size -Note $note -Content $updated))
    }

    return @($actions)
}

function Merge-FileActionPlan {
    <#
    .SYNOPSIS
        One plan with another's actions standing in for any that write the same
        file, keeping the original order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [psobject[]] $Action,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [psobject[]] $Override
    )

    if (-not $Override) { return @($Action) }

    $byDestination = @{}
    foreach ($item in $Override) { $byDestination[$item.Destination] = $item }

    $used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $merged = [System.Collections.Generic.List[psobject]]::new()
    foreach ($item in $Action) {
        if ($byDestination.ContainsKey($item.Destination)) {
            $merged.Add($byDestination[$item.Destination])
            $null = $used.Add($item.Destination)
            continue
        }
        $merged.Add($item)
    }
    foreach ($item in $Override) {
        if ($used.Contains($item.Destination)) { continue }
        $merged.Add($item)
    }

    return @($merged)
}
