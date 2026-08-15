<#
    The profile-key rewrite. It edits files the game wrote and the game will read
    back, so the tests care about two things in equal measure: that the right key
    lands, and that nothing else in the file moves.
#>

function New-AceDbFile {
    param(
        [hashtable] $ProfileKey = @{ 'Sunderfury - Whitemane' = 'Sunderfury - Whitemane' },
        [string] $Name = 'Bartender4DB'
    )

    $keys = ''
    foreach ($key in ($ProfileKey.Keys | Sort-Object)) {
        $keys += "`t`t[`"$key`"] = `"$($ProfileKey[$key])`",`n"
    }
    return "$Name = {`n`t[`"profileKeys`"] = {`n$keys`t},`n`t[`"profiles`"] = {`n`t`t[`"Sunderfury - Whitemane`"] = {`n`t`t`t[`"bar1`"] = `"BOTTOM`",`n`t`t},`n`t},`n}`n"
}

function New-Mapping {
    param([string] $From = 'Sunderfury - Whitemane', [string] $To = 'Sunderfury - Classic PTR Realm 1')
    return @([pscustomobject]@{ From = $From; To = $To })
}

Describe 'Lua string literals' {

    It 'round-trips a name the game had to escape' {
        # WoW writes every byte over 126 as a decimal escape, so an accented
        # character name never appears as itself in the file.
        foreach ($name in @('Sunderfury', 'Ölrún', 'Ægir - Ravencrest', 'Quote"Inside', 'Back\slash')) {
            $literal = ConvertTo-LuaString -Value $name
            Assert-Equal $name (ConvertFrom-LuaString -Literal $literal) "Round-trip failed for $name"
        }
    }

    It 'writes non-ASCII the way the game does, as UTF-8 bytes' {
        Assert-Equal '\195\169' (ConvertTo-LuaString -Value ([char]0xE9))
        Assert-Equal ([string][char]0xE9) (ConvertFrom-LuaString -Literal '\195\169')
    }

    It 'pads escapes to three digits so a following digit is not swallowed' {
        # \1959 would be read by Lua as byte 195 then the character "9"; the
        # danger is the other way round — \79 for byte 7 reads as byte 79.
        $literal = ConvertTo-LuaString -Value ("$([char]7)9")
        Assert-Equal '\0079' $literal
        Assert-Equal ("$([char]7)9") (ConvertFrom-LuaString -Literal $literal)
    }

    It 'stops a decimal escape at three digits' {
        Assert-Equal 'A9' (ConvertFrom-LuaString -Literal '\0659')
    }
}

Describe 'Finding a table in a saved variables file' {

    It 'matches the brace that closes it, not the first one it sees' {
        $text = New-AceDbFile
        $table = Find-LuaTable -Text $text -Name 'profiles'
        Assert-True ($null -ne $table) 'profiles was not found'
        $body = $text.Substring($table.Open + 1, $table.Close - $table.Open - 1)
        Assert-True ($body.IndexOf('bar1') -ge 0) 'the block stopped short of its contents'
        Assert-True ($body.IndexOf('profileKeys') -lt 0) 'the block ran past its own closing brace'
    }

    It 'ignores braces inside strings' {
        $text = 'DB = { ["profileKeys"] = { ["A - B"] = "}{ not a brace", }, }'
        $table = Find-LuaTable -Text $text -Name 'profileKeys'
        Assert-True ($null -ne $table) 'the table was not found'
        $body = $text.Substring($table.Open + 1, $table.Close - $table.Open - 1)
        Assert-True ($body.IndexOf('not a brace') -ge 0) 'the block ended inside the string'
    }

    It 'gives up on a table that never closes' {
        Assert-Equal $null (Find-LuaTable -Text 'DB = { ["profileKeys"] = { ["A - B"] = "x",' -Name 'profileKeys')
    }

    It 'finds nothing when there is nothing to find' {
        Assert-Equal $null (Find-LuaTable -Text 'WeakAurasSaved = { displays = { } }' -Name 'profileKeys')
    }
}

Describe 'Pointing a profile at the PTR character' {

    It 'adds the PTR key with the live character''s profile' {
        $updated = Update-LuaProfileKey -Text (New-AceDbFile) -Mapping (New-Mapping)
        Assert-True ($null -ne $updated) 'nothing was rewritten'
        Assert-True ($updated.IndexOf('["Sunderfury - Classic PTR Realm 1"] = "Sunderfury - Whitemane"') -ge 0) `
            "the PTR key is not there:`n$updated"
    }

    It 'leaves the live key and everything else exactly as it was' {
        $before = New-AceDbFile
        $after = Update-LuaProfileKey -Text $before -Mapping (New-Mapping)
        # The only difference is the one added line.
        $added = @($after -split "`n" | Where-Object { $_ -notin @($before -split "`n") })
        Assert-Equal 1 $added.Count "more than the new key changed:`n$($added -join "`n")"
        Assert-True ($after.IndexOf('["Sunderfury - Whitemane"] = "Sunderfury - Whitemane"') -ge 0) 'the live key was disturbed'
        Assert-True ($after.IndexOf('["bar1"] = "BOTTOM"') -ge 0) 'the profiles table was disturbed'
    }

    It 'copies the profile name rather than assuming it matches the character' {
        $text = New-AceDbFile -ProfileKey @{ 'Mendicant - Whitemane' = 'Healer' }
        $updated = Update-LuaProfileKey -Text $text -Mapping (New-Mapping -From 'Mendicant - Whitemane' -To 'Mendicant - Classic PTR Realm 1')
        Assert-True ($updated.IndexOf('["Mendicant - Classic PTR Realm 1"] = "Healer"') -ge 0) `
            "the shared profile name did not come across:`n$updated"
    }

    It 'corrects a PTR key that points somewhere else' {
        $text = New-AceDbFile -ProfileKey @{
            'Sunderfury - Whitemane'            = 'Raid'
            'Sunderfury - Classic PTR Realm 1'  = 'Default'
        }
        $updated = Update-LuaProfileKey -Text $text -Mapping (New-Mapping)
        Assert-True ($updated.IndexOf('["Sunderfury - Classic PTR Realm 1"] = "Raid"') -ge 0) `
            "the wrong profile is still selected:`n$updated"
        Assert-True ($updated.IndexOf('"Default"') -lt 0) 'the old value was left behind as well'
    }

    It 'changes nothing the second time' {
        $once = Update-LuaProfileKey -Text (New-AceDbFile) -Mapping (New-Mapping)
        Assert-Equal $null (Update-LuaProfileKey -Text $once -Mapping (New-Mapping)) `
            'a second pass wanted to rewrite the file again, so a second Apply would never report itself done'
    }

    It 'does nothing for a character the live client has no profile for' {
        Assert-Equal $null (Update-LuaProfileKey -Text (New-AceDbFile) -Mapping (New-Mapping -From 'Nobody - Whitemane' -To 'Nobody - PTR'))
    }

    It 'does nothing to a file with no profileKeys at all' {
        Assert-Equal $null (Update-LuaProfileKey -Text "WeakAurasSaved = {`n`t['displays'] = { },`n}`n" -Mapping (New-Mapping))
    }

    It 'handles a file holding more than one database' {
        $text = (New-AceDbFile -Name 'Bartender4DB') + (New-AceDbFile -ProfileKey @{ 'Sunderfury - Whitemane' = 'Tank' } -Name 'ElvDB')
        $updated = Update-LuaProfileKey -Text $text -Mapping (New-Mapping)
        Assert-Equal 1 ([regex]::Matches($updated, '"Sunderfury - Classic PTR Realm 1"\] = "Sunderfury - Whitemane"').Count)
        Assert-Equal 1 ([regex]::Matches($updated, '"Sunderfury - Classic PTR Realm 1"\] = "Tank"').Count)
    }

    It 'carries a name the game had to escape' {
        $text = New-AceDbFile -ProfileKey @{ '\195\150lr\195\186n - Whitemane' = 'Healer' }
        $mapping = New-Mapping -From "$([char]0xD6)lr$([char]0xFA)n - Whitemane" -To "$([char]0xD6)lr$([char]0xFA)n - Classic PTR Realm 1"
        $updated = Update-LuaProfileKey -Text $text -Mapping $mapping
        Assert-True ($null -ne $updated) 'the escaped key was not matched'
        Assert-True ($updated.IndexOf('["\195\150lr\195\186n - Classic PTR Realm 1"] = "Healer"') -ge 0) `
            "the new key was not escaped the way the game escapes it:`n$updated"
    }

    It 'keeps the file''s own line endings' {
        $text = (New-AceDbFile) -replace "`n", "`r`n"
        $updated = Update-LuaProfileKey -Text $text -Mapping (New-Mapping)
        Assert-Equal 0 ([regex]::Matches($updated, "(?<!`r)`n").Count) 'a bare newline was introduced into a CRLF file'
    }

    It 'does nothing when no characters are mapped' {
        Assert-Equal $null (Update-LuaProfileKey -Text (New-AceDbFile) -Mapping @())
    }
}

Describe 'Deciding which files to open' {

    It 'says yes only to files that mention profileKeys' {
        $yes = New-TestFile -Path (Join-Path $script:TestDrive 'Bartender4.lua') -Content (New-AceDbFile)
        $no = New-TestFile -Path (Join-Path $script:TestDrive 'WeakAuras.lua') -Content "WeakAurasSaved = { }`n"
        Assert-True (Test-LuaProfileFile -Path $yes)
        Assert-False (Test-LuaProfileFile -Path $no)
    }

    It 'finds the word even when it straddles a read boundary' {
        # The probe reads in chunks and keeps a few characters of overlap; without
        # that, a file whose only mention lands on the seam reads as "no".
        $padding = 'x' * (65536 - 5)
        $path = New-TestFile -Path (Join-Path $script:TestDrive 'Seam.lua') -Content ($padding + 'profileKeys = { }')
        Assert-True (Test-LuaProfileFile -Path $path) 'a match spanning two chunks was missed'
    }

    It 'says no rather than throwing when the file is not there' {
        Assert-False (Test-LuaProfileFile -Path (Join-Path $script:TestDrive 'missing.lua'))
    }

    It 'answers again for a file that has changed since it last looked' {
        # The answer is remembered so that changing a dropdown does not re-read
        # the whole folder. It is keyed on size and write time, so an edit has to
        # get through — a cache that cannot notice a change is a bug waiting for
        # someone who saves their addon settings between runs.
        Clear-LuaProbeCache
        $path = New-TestFile -Path (Join-Path $script:TestDrive 'Late.lua') -Content "WeakAurasSaved = { }`n"
        Assert-False (Test-LuaProfileFile -Path $path)

        $null = New-TestFile -Path $path -Content (New-AceDbFile)
        Assert-True (Test-LuaProfileFile -Path $path) 'a remembered answer was served for a file that had changed'
    }

    It 'gives the same answer twice for a file that has not' {
        Clear-LuaProbeCache
        $path = New-TestFile -Path (Join-Path $script:TestDrive 'Steady.lua') -Content (New-AceDbFile)
        Assert-True (Test-LuaProfileFile -Path $path)
        Assert-True (Test-LuaProfileFile -Path $path)
    }
}

Describe 'Planning the rewrite' {

    It 'plans a rewrite of the file, not a copy of it' {
        $source = Join-Path $script:TestDrive 'live'
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $source 'Bartender4.lua') -Content (New-AceDbFile)
        $null = New-TestFile -Path (Join-Path $target 'Bartender4.lua') -Content "-- the PTR's own`n"

        $plan = @(New-ProfileKeyPlan -Source $source -Destination $target -Mapping (New-Mapping))
        Assert-Equal 1 $plan.Count
        Assert-Equal 'overwrite' $plan[0].Kind
        Assert-Equal '' $plan[0].Source 'the action still copies from the live file, so the rewrite would be lost'
        Assert-True ($plan[0].Content.IndexOf('["Sunderfury - Classic PTR Realm 1"]') -ge 0)
        Assert-Equal ([System.Text.Encoding]::UTF8.GetByteCount($plan[0].Content)) $plan[0].Size
    }

    It 'creates the file when the PTR does not have one' {
        $source = Join-Path $script:TestDrive 'live'
        $null = New-TestFile -Path (Join-Path $source 'Bartender4.lua') -Content (New-AceDbFile)
        $plan = @(New-ProfileKeyPlan -Source $source -Destination (Join-Path $script:TestDrive 'ptr') -Mapping (New-Mapping))
        Assert-Equal 'create' $plan[0].Kind
    }

    It 'plans a skip once the PTR file is already right' {
        # A skip rather than nothing on purpose: the caller uses these to stand in
        # for the plain copies of the same files, and without one here the copy
        # would put the unrewritten live file back on the next Apply.
        $source = Join-Path $script:TestDrive 'live'
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $source 'Bartender4.lua') -Content (New-AceDbFile)
        $null = New-TestFile -Path (Join-Path $target 'Bartender4.lua') `
            -Content (Update-LuaProfileKey -Text (New-AceDbFile) -Mapping (New-Mapping))

        $plan = @(New-ProfileKeyPlan -Source $source -Destination $target -Mapping (New-Mapping))
        Assert-Equal 1 $plan.Count
        Assert-Equal 'skip' $plan[0].Kind
    }

    It 'leaves files it has no key for to the plain copy' {
        $source = Join-Path $script:TestDrive 'live'
        $null = New-TestFile -Path (Join-Path $source 'WeakAuras.lua') -Content "WeakAurasSaved = { }`n"
        Assert-Equal 0 @(New-ProfileKeyPlan -Source $source -Destination (Join-Path $script:TestDrive 'ptr') -Mapping (New-Mapping)).Count
    }

    It 'stays out of the way when overwriting is turned off' {
        $source = Join-Path $script:TestDrive 'live'
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $source 'Bartender4.lua') -Content (New-AceDbFile)
        $null = New-TestFile -Path (Join-Path $target 'Bartender4.lua') -Content "-- the PTR's own`n"
        Assert-Equal 0 @(New-ProfileKeyPlan -Source $source -Destination $target -Mapping (New-Mapping) -Overwrite $false).Count
    }
}

Describe 'Using the key the game actually wrote' {
    <#
        The bug this exists for. The PTR key was built as "<name> - <realm>" from
        the realm's *folder* name, while the addon looks it up with what
        GetRealmName returns in game. Those are usually the same string. When
        they are not, the key written is a key nothing reads: the addon starts on
        its default, the right profile sits unused in the same file, and the only
        symptom is a UI that looks wrong with no error anywhere.

        The PTR's own copy of the file already answers the question — the game
        wrote a key for that character the first time it logged in — so it is
        read rather than guessed at.
    #>

    It 'finds the keys a file holds for one character' {
        $text = New-AceDbFile -ProfileKey @{
            'Klay - Whitemane'      = 'Main'
            'Klay - PTR Realm One'  = 'Default'
            'Klayton - Whitemane'   = 'Other'
        }
        $found = @(Get-LuaProfileKeyForCharacter -Text $text -Name 'Klay')
        Assert-Equal @('Klay - PTR Realm One', 'Klay - Whitemane') @($found | Sort-Object)
    }

    It 'splits on the first separator, not one inside the realm name' {
        $text = New-AceDbFile -ProfileKey @{ 'Klay - Ravencrest - PvP' = 'Main' }
        Assert-Equal @('Klay - Ravencrest - PvP') @(Get-LuaProfileKeyForCharacter -Text $text -Name 'Klay')
    }

    It 'does not mistake a different character with the same start' {
        $text = New-AceDbFile -ProfileKey @{ 'Klayton - Whitemane' = 'Main' }
        Assert-Equal 0 @(Get-LuaProfileKeyForCharacter -Text $text -Name 'Klay').Count
    }

    It 'prefers what the PTR file says over the folder-name guess' {
        # The realm folder is "Classic PTR Realm 1"; in game it answers to
        # something else, and the game's own key is the one that gets read.
        $mapping = @([pscustomobject]@{
                From   = 'Klay - Whitemane'
                To     = 'Klay - Classic PTR Realm 1'
                ToName = 'Klay'
            })
        $destination = New-AceDbFile -ProfileKey @{ 'Klay - PTRRealm1' = 'Default' }

        $resolved = @(Resolve-ProfileKeyMapping -Mapping $mapping -DestinationText $destination)
        Assert-Equal @('Klay - Classic PTR Realm 1', 'Klay - PTRRealm1') @($resolved.To | Sort-Object)
        Assert-Equal @('Klay - Whitemane', 'Klay - Whitemane') @($resolved.From)
    }

    It 'writes both keys, so whichever the addon looks up is there' {
        $live = New-AceDbFile -ProfileKey @{ 'Klay - Whitemane' = 'Main' }
        $mapping = @([pscustomobject]@{
                From   = 'Klay - Whitemane'
                To     = 'Klay - Classic PTR Realm 1'
                ToName = 'Klay'
            })
        $resolved = @(Resolve-ProfileKeyMapping -Mapping $mapping `
                -DestinationText (New-AceDbFile -ProfileKey @{ 'Klay - PTRRealm1' = 'Default' }))

        $updated = Update-LuaProfileKey -Text $live -Mapping $resolved
        Assert-True ($updated.IndexOf('["Klay - PTRRealm1"] = "Main"') -ge 0) `
            "The key the game wrote is not pointed at the live profile:`n$updated"
        Assert-True ($updated.IndexOf('["Klay - Classic PTR Realm 1"] = "Main"') -ge 0) `
            'The folder-name key should still be written as a fallback.'
    }

    It 'adds nothing extra when the two agree' {
        $mapping = @([pscustomobject]@{
                From   = 'Klay - Whitemane'
                To     = 'Klay - PTRRealm1'
                ToName = 'Klay'
            })
        $resolved = @(Resolve-ProfileKeyMapping -Mapping $mapping `
                -DestinationText (New-AceDbFile -ProfileKey @{ 'Klay - PTRRealm1' = 'Default' }))
        Assert-Equal 1 $resolved.Count
    }

    It 'falls back to the guess when the PTR has no file yet' {
        $mapping = @([pscustomobject]@{ From = 'Klay - Whitemane'; To = 'Klay - PTR'; ToName = 'Klay' })
        $resolved = @(Resolve-ProfileKeyMapping -Mapping $mapping -DestinationText '')
        Assert-Equal 1 $resolved.Count
        Assert-Equal 'Klay - PTR' $resolved[0].To
    }

    It 'plans the discovered key end to end' {
        $source = Join-Path $script:TestDrive 'live'
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $source 'Bartender4.lua') `
            -Content (New-AceDbFile -ProfileKey @{ 'Klay - Whitemane' = 'Main' })
        $null = New-TestFile -Path (Join-Path $target 'Bartender4.lua') `
            -Content (New-AceDbFile -ProfileKey @{ 'Klay - PTRRealm1' = 'Default' })

        $mapping = @([pscustomobject]@{ From = 'Klay - Whitemane'; To = 'Klay - Classic PTR Realm 1'; ToName = 'Klay' })
        $plan = @(New-ProfileKeyPlan -Source $source -Destination $target -Mapping $mapping)
        Assert-Equal 1 $plan.Count
        Assert-True ($plan[0].Content.IndexOf('["Klay - PTRRealm1"] = "Main"') -ge 0) `
            "The planned file does not point the game's own key at the live profile:`n$($plan[0].Content)"
    }
}

Describe 'Merging the rewrite into the copy plan' {

    It 'replaces the copy of the same file and keeps the order' {
        $copies = @(
            New-FileAction -Kind 'create' -Source 'a' -Destination 'X:\ptr\Details.lua' -Size 1
            New-FileAction -Kind 'create' -Source 'b' -Destination 'X:\ptr\Bartender4.lua' -Size 2
            New-FileAction -Kind 'create' -Source 'c' -Destination 'X:\ptr\Plater.lua' -Size 3
        )
        $override = @(New-FileAction -Kind 'overwrite' -Destination 'X:\ptr\Bartender4.lua' -Size 9 -Content 'new')

        $merged = @(Merge-FileActionPlan -Action $copies -Override $override)
        Assert-Equal 3 $merged.Count 'the rewrite was added alongside the copy instead of replacing it'
        Assert-Equal @('Details.lua', 'Bartender4.lua', 'Plater.lua') @($merged | ForEach-Object { Split-Path -Leaf $_.Destination })
        Assert-Equal 'new' $merged[1].Content
    }

    It 'appends an override with no copy to replace' {
        $merged = @(Merge-FileActionPlan -Action @() -Override @(New-FileAction -Kind 'create' -Destination 'X:\ptr\New.lua' -Content 'x'))
        Assert-Equal 1 $merged.Count
    }

    It 'hands the plan straight back when there is nothing to override' {
        $copies = @(New-FileAction -Kind 'create' -Source 'a' -Destination 'X:\ptr\Details.lua')
        Assert-Equal 1 @(Merge-FileActionPlan -Action $copies -Override @()).Count
    }
}

Describe 'Reading the mapping off a context' {

    It 'builds the AceDB key from the character and realm folder names' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $mapping = @(Get-PtrSetupProfileMapping -Context $context)
        Assert-Equal 1 $mapping.Count
        Assert-Equal 'Bankalt - Whitemane' $mapping[0].From
        Assert-Equal 'Bankalt - PTR Whitemane' $mapping[0].To
    }

    It 'leaves out a pair whose two sides are already the same key' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $context.Character = @([pscustomobject]@{
                Source = $context.Character[0].Source
                Target = $context.Character[0].Source
            })
        Assert-Equal 0 @(Get-PtrSetupProfileMapping -Context $context).Count
    }

    It 'copes with a context whose mapping has been cleared' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $context.Character = @()
        Assert-Equal 0 @(Get-PtrSetupProfileMapping -Context $context).Count
    }
}
