<#
    Making macro names unique. The problem is duplication, not blankness — two
    macros called "weps" break an action bar saver exactly as thoroughly as
    thirty called " ". The file is read by the game and feeds the action bars, so
    these care as much about what survives untouched as about the new names.
#>

function New-MacroCache {
    param([string[]] $Name = @(' ', ' ', ' '))

    $out = ''
    $id = 1
    foreach ($macroName in $Name) {
        $out += ('VER 3 010000000100{0:X4} "{1}" "134400"' -f $id, $macroName) + "`n"
        $out += "#showtooltip spell$id`n/cast spell$id`nEND`n"
        $id++
    }
    return $out
}

Describe 'Invisible suffixes' {

    It 'is made of characters that draw as nothing' {
        foreach ($index in 0..40) {
            $name = Get-InvisibleMacroSuffix -Index $index
            Assert-True ($name.Length -gt 0) "Index $index gave an empty suffix, which would change nothing."
            foreach ($char in $name.ToCharArray()) {
                Assert-True ([int]$char -in @(0x20, 0xA0)) ("Index {0} used U+{1:X4}, which may render as a box." -f $index, [int]$char)
            }
        }
    }

    It 'gives a different suffix to every conflict' {
        $names = @(0..99 | ForEach-Object { Get-InvisibleMacroSuffix -Index $_ })
        Assert-Equal 100 @($names | Select-Object -Unique).Count 'Two conflicting macros would still share a name.'
    }

    It 'stays short enough for any name limit' {
        # Bijective base two: 100 macros need seven characters, and WoW's own
        # macro naming stops well above that.
        $longest = (@(0..99 | ForEach-Object { (Get-InvisibleMacroSuffix -Index $_).Length }) | Measure-Object -Maximum).Maximum
        Assert-True ($longest -le 8) "Longest name was $longest characters."
    }

    It 'starts with a single space' {
        Assert-Equal ' ' (Get-InvisibleMacroSuffix -Index 0)
    }

    It 'keeps the two scopes apart' {
        # Account-wide and character macros are one namespace in game, so the
        # same index in each must not produce the same name.
        $account = @(0..30 | ForEach-Object { Get-InvisibleMacroSuffix -Index $_ -Scope 'Account' })
        $character = @(0..30 | ForEach-Object { Get-InvisibleMacroSuffix -Index $_ -Scope 'Character' })
        $shared = @($account | Where-Object { $_ -cin $character })
        Assert-Equal 0 $shared.Count 'An account macro and a character macro would get the same suffix.'
    }
}

Describe 'Reading a macro cache' {

    It 'finds every macro and reads its name' {
        $entries = @(Get-MacroCacheEntry -Text (New-MacroCache -Name @(' ', 'weps', '  ', 'br mock')))
        Assert-Equal 4 $entries.Count
        Assert-Equal @(' ', 'weps', '  ', 'br mock') @($entries | ForEach-Object { $_.Name })
    }

    It 'reports which names are used more than once' {
        $conflicts = @(Get-MacroNameConflict -Text (New-MacroCache -Name @(' ', 'weps', ' ', 'weps', ' ', 'solo')))
        Assert-Equal 2 $conflicts.Count
        Assert-Equal ' ' $conflicts[0].Name 'The worst offender should come first.'
        Assert-Equal 3 $conflicts[0].Count
    }

    It 'reports nothing when every name is its own' {
        Assert-Equal 0 @(Get-MacroNameConflict -Text (New-MacroCache -Name @('one', 'two', 'three'))).Count
    }

    It 'is not fooled by a body line that looks like a header' {
        $text = "VER 3 0100000001000001 `" `" `"134400`"`n#showtooltip`n/say VER 3 nope`nEND`n"
        Assert-Equal 1 @(Get-MacroCacheEntry -Text $text).Count
    }

    It 'finds nothing in an empty cache' {
        Assert-Equal 0 @(Get-MacroCacheEntry -Text '').Count
    }
}

Describe 'Breaking the ties' {

    It 'gives every macro a name of its own' {
        $named = Resolve-MacroNameConflict -Text (New-MacroCache -Name @(' ', ' ', ' ', ' ', ' '))
        $names = @(Get-MacroCacheEntry -Text $named | ForEach-Object { $_.Name })
        Assert-Equal 5 @($names | Select-Object -Unique).Count "Names still collide: $($names.Count)"
    }

    It 'leaves the bodies, ids and icons exactly as they were' {
        $before = New-MacroCache -Name @(' ', ' ', ' ')
        $after = Resolve-MacroNameConflict -Text $before

        $bodyBefore = @($before -split "`n" | Where-Object { $_ -notmatch '^VER ' })
        $bodyAfter = @($after -split "`n" | Where-Object { $_ -notmatch '^VER ' })
        Assert-Equal ($bodyBefore -join '|') ($bodyAfter -join '|') 'A macro body changed.'

        $idsBefore = @($before -split "`n" | Where-Object { $_ -match '^VER ' } | ForEach-Object { ($_ -split ' ')[2] })
        $idsAfter = @($after -split "`n" | Where-Object { $_ -match '^VER ' } | ForEach-Object { ($_ -split ' ')[2] })
        Assert-Equal ($idsBefore -join ',') ($idsAfter -join ',') 'A macro id changed.'
        Assert-True ($after -match '"134400"') 'The icon was lost.'
    }

    It 'leaves a name nobody else is using completely alone' {
        $named = Resolve-MacroNameConflict -Text (New-MacroCache -Name @(' ', 'weps', ' ', 'br mock'))
        $names = @(Get-MacroCacheEntry -Text $named | ForEach-Object { $_.Name })
        Assert-Equal 'weps' $names[1]
        Assert-Equal 'br mock' $names[3]
    }

    It 'breaks a tie between two macros the user named, keeping the text' {
        # The general case, and the one "rename the blanks" would have missed.
        $named = Resolve-MacroNameConflict -Text (New-MacroCache -Name @('weps', 'weps'))
        $names = @(Get-MacroCacheEntry -Text $named | ForEach-Object { $_.Name })
        Assert-Equal 'weps' $names[0] 'The first should keep the name exactly.'
        Assert-True ($names[1] -cne $names[0]) 'The second is still identical to the first.'
        Assert-True ($names[1].StartsWith('weps')) "The visible text changed: [$($names[1])]"
        foreach ($char in $names[1].Substring(4).ToCharArray()) {
            Assert-True ([int]$char -in @(0x20, 0xA0)) ('The suffix used U+{0:X4}, which may be visible.' -f [int]$char)
        }
    }

    It 'keeps the first of every group and changes only the rest' {
        $named = Resolve-MacroNameConflict -Text (New-MacroCache -Name @('a', 'b', 'a', 'b', 'a'))
        $names = @(Get-MacroCacheEntry -Text $named | ForEach-Object { $_.Name })
        Assert-Equal 'a' $names[0]
        Assert-Equal 'b' $names[1]
        Assert-Equal 5 @($names | Select-Object -Unique).Count
    }

    It 'cannot generate a name some other macro already has' {
        # "" twice plus a real " " — the first generated suffix would be " ",
        # which is taken.
        $named = Resolve-MacroNameConflict -Text (New-MacroCache -Name @('', ' ', ''))
        $names = @(Get-MacroCacheEntry -Text $named | ForEach-Object { $_.Name })
        Assert-Equal 3 @($names | Select-Object -Unique).Count "Collided with an existing name: $($names.Count)"
    }

    It 'does nothing when no two macros share a name' {
        Assert-Equal $null (Resolve-MacroNameConflict -Text (New-MacroCache -Name @('one', 'two', '')))
    }

    It 'changes nothing the second time' {
        $once = Resolve-MacroNameConflict -Text (New-MacroCache -Name @(' ', ' ', ' '))
        Assert-Equal $null (Resolve-MacroNameConflict -Text $once) 'A second pass would make every Apply report work forever.'
    }

    It 'keeps the line endings the file had' {
        $text = (New-MacroCache -Name @(' ', ' ')) -replace "`n", "`r`n"
        $named = Resolve-MacroNameConflict -Text $text
        Assert-Equal 0 ([regex]::Matches($named, "(?<!`r)`n").Count) 'A bare newline was introduced into a CRLF file.'
    }
}

Describe 'Planning the fix on the live client' {

    function New-CacheFile {
        param([string] $Name, [string[]] $MacroName, [string] $Scope = 'Account')
        [pscustomobject]@{
            Path  = (New-TestFile -Path (Join-Path $script:TestDrive $Name) -Content (New-MacroCache -Name $MacroName))
            Scope = $Scope
        }
    }

    It 'plans a rewrite of the file where it already sits' {
        $file = New-CacheFile -Name 'macros-cache.txt' -MacroName @(' ', ' ', ' ')
        $plan = @(New-MacroNameFixPlan -File @($file))
        Assert-Equal 1 $plan.Count
        Assert-Equal 'overwrite' $plan[0].Kind
        Assert-Equal $file.Path $plan[0].Destination 'It must rewrite the file in place, not copy it somewhere.'
        Assert-Equal '' $plan[0].Source 'It must carry content rather than copy the conflicted original.'
    }

    It 'plans nothing when the names are already unique' {
        $file = New-CacheFile -Name 'macros-cache.txt' -MacroName @('one', 'two')
        Assert-Equal 0 @(New-MacroNameFixPlan -File @($file)).Count
    }

    It 'plans nothing at all for a file that is not there' {
        $missing = [pscustomobject]@{ Path = (Join-Path $script:TestDrive 'missing.txt'); Scope = 'Account' }
        Assert-Equal 0 @(New-MacroNameFixPlan -File @($missing)).Count
    }

    It 'says how many it is renaming' {
        $file = New-CacheFile -Name 'macros-cache.txt' -MacroName @(' ', ' ', ' ', 'weps')
        $plan = @(New-MacroNameFixPlan -File @($file))
        Assert-True ($plan[0].Note -match '2 macro') "The note should count what changes: $($plan[0].Note)"
    }

    It 'breaks a tie that spans the account and character files' {
        # The one this exists for. Each file is fine on its own — one "CORE"
        # apiece — but in game they are one namespace, and an action bar saver
        # reports "found 2 macros named CORE".
        $account = New-CacheFile -Name 'account.txt' -MacroName @('CORE', 'other')
        $character = New-CacheFile -Name 'char.txt' -MacroName @('CORE', 'mine') -Scope 'Character'

        Assert-Equal 0 @(Get-MacroNameConflict -Text (Get-Content -LiteralPath $account.Path -Raw)).Count `
            'Neither file conflicts with itself, which is what made this invisible.'

        $plan = @(New-MacroNameFixPlan -File @($account, $character))
        Assert-Equal 1 $plan.Count 'Only the character file should change — the account file keeps its name.'
        Assert-Equal $character.Path $plan[0].Destination

        $names = @(Get-MacroCacheEntry -Text $plan[0].Content | ForEach-Object { $_.Name })
        Assert-True ($names[0] -cne 'CORE') 'The character copy still holds the account name.'
        Assert-True ($names[0].StartsWith('CORE')) "The visible text changed: [$($names[0])]"
    }

    It 'settles the whole set against itself, not file by file' {
        $account = New-CacheFile -Name 'account.txt' -MacroName @(' ', ' ')
        $one = New-CacheFile -Name 'one.txt' -MacroName @(' ') -Scope 'Character'
        $two = New-CacheFile -Name 'two.txt' -MacroName @(' ') -Scope 'Character'

        # Apply the plan, then read every name back off disk — the rewritten
        # files for the ones that changed, the original for any that did not.
        foreach ($action in (New-MacroNameFixPlan -File @($account, $one, $two))) {
            Write-TextFileNoBom -Path $action.Destination -Content $action.Content
        }
        $all = foreach ($file in @($account, $one, $two)) {
            Get-MacroCacheEntry -Text (Get-Content -LiteralPath $file.Path -Raw) | ForEach-Object { $_.Name }
        }
        Assert-Equal 4 @($all).Count
        Assert-Equal @($all).Count @($all | Select-Object -Unique).Count `
            'Two macros somewhere in the set still share a name.'
    }

    It 'leaves the account file alone and moves the character one' {
        $account = New-CacheFile -Name 'account.txt' -MacroName @('CORE')
        $character = New-CacheFile -Name 'char.txt' -MacroName @('CORE') -Scope 'Character'
        $before = Get-Content -LiteralPath $account.Path -Raw

        $plan = @(New-MacroNameFixPlan -File @($account, $character))
        Assert-Equal 1 $plan.Count
        Assert-Equal $before (Get-Content -LiteralPath $account.Path -Raw) 'Planning must not write anything.'
        Assert-Equal $character.Path $plan[0].Destination 'The account file should be the one that keeps the name.'
    }

    It 'counts conflicts across the set, not within each file' {
        $account = New-CacheFile -Name 'account.txt' -MacroName @('CORE')
        $character = New-CacheFile -Name 'char.txt' -MacroName @('CORE') -Scope 'Character'
        $conflicts = @(Get-LiveMacroNameConflict -File @($account, $character))
        Assert-Equal 1 $conflicts.Count
        Assert-Equal 'CORE' $conflicts[0].Name
        Assert-Equal 2 $conflicts[0].Count
    }

    It 'changes nothing on a second pass over the set' {
        $account = New-CacheFile -Name 'account.txt' -MacroName @(' ', ' ', 'CORE')
        $character = New-CacheFile -Name 'char.txt' -MacroName @(' ', 'CORE') -Scope 'Character'

        foreach ($action in (New-MacroNameFixPlan -File @($account, $character))) {
            Write-TextFileNoBom -Path $action.Destination -Content $action.Content
        }
        Assert-Equal 0 @(New-MacroNameFixPlan -File @($account, $character)).Count `
            'A second pass wanted to rewrite, so every Apply would report work forever.'
        Assert-Equal 0 @(Get-LiveMacroNameConflict -File @($account, $character)).Count `
            'Conflicts survived the fix.'
    }
}
