<#
    Naming blank macros. The file is read by the game and feeds the action bars,
    so these care as much about what survives untouched as about the new names.
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

Describe 'Invisible macro names' {

    It 'is made of characters that draw as nothing' {
        foreach ($index in 0..40) {
            $name = Get-BlankMacroName -Index $index
            Assert-True ($name.Length -gt 0) "Index $index gave an empty name."
            foreach ($char in $name.ToCharArray()) {
                Assert-True ([int]$char -in @(0x20, 0xA0)) ("Index {0} used U+{1:X4}, which may render as a box." -f $index, [int]$char)
            }
        }
    }

    It 'gives a different name to every macro' {
        $names = @(0..99 | ForEach-Object { Get-BlankMacroName -Index $_ })
        Assert-Equal 100 @($names | Select-Object -Unique).Count 'Two macros would share a name.'
    }

    It 'stays short enough for any name limit' {
        # Bijective base two: 100 macros need seven characters, and WoW's own
        # macro naming stops well above that.
        $longest = (@(0..99 | ForEach-Object { (Get-BlankMacroName -Index $_).Length }) | Measure-Object -Maximum).Maximum
        Assert-True ($longest -le 8) "Longest name was $longest characters."
    }

    It 'starts with the single space these macros already have' {
        Assert-Equal ' ' (Get-BlankMacroName -Index 0)
    }

    It 'keeps the two scopes apart' {
        # Account-wide and character macros are one namespace in game, so the
        # same index in each must not produce the same name.
        $account = @(0..30 | ForEach-Object { Get-BlankMacroName -Index $_ -Scope 'Account' })
        $character = @(0..30 | ForEach-Object { Get-BlankMacroName -Index $_ -Scope 'Character' })
        $shared = @($account | Where-Object { $_ -cin $character })
        Assert-Equal 0 $shared.Count 'An account macro and a character macro would share a name.'
    }
}

Describe 'Reading a macro cache' {

    It 'finds every macro and spots the blank names' {
        $entries = @(Get-MacroCacheEntry -Text (New-MacroCache -Name @(' ', 'weps', '  ', 'br mock')))
        Assert-Equal 4 $entries.Count
        Assert-Equal @($true, $false, $true, $false) @($entries | ForEach-Object { $_.IsBlank })
    }

    It 'is not fooled by a body line that looks like a header' {
        $text = "VER 3 0100000001000001 `" `" `"134400`"`n#showtooltip`n/say VER 3 nope`nEND`n"
        Assert-Equal 1 @(Get-MacroCacheEntry -Text $text).Count
    }

    It 'finds nothing in an empty cache' {
        Assert-Equal 0 @(Get-MacroCacheEntry -Text '').Count
    }
}

Describe 'Naming the blanks' {

    It 'gives every macro a name of its own' {
        $named = Set-BlankMacroName -Text (New-MacroCache -Name @(' ', ' ', ' ', ' ', ' '))
        $names = @(Get-MacroCacheEntry -Text $named | ForEach-Object { $_.Name })
        Assert-Equal 5 @($names | Select-Object -Unique).Count "Names still collide: $($names.Count)"
    }

    It 'leaves the bodies, ids and icons exactly as they were' {
        $before = New-MacroCache -Name @(' ', ' ', ' ')
        $after = Set-BlankMacroName -Text $before

        $bodyBefore = @($before -split "`n" | Where-Object { $_ -notmatch '^VER ' })
        $bodyAfter = @($after -split "`n" | Where-Object { $_ -notmatch '^VER ' })
        Assert-Equal ($bodyBefore -join '|') ($bodyAfter -join '|') 'A macro body changed.'

        $idsBefore = @($before -split "`n" | Where-Object { $_ -match '^VER ' } | ForEach-Object { ($_ -split ' ')[2] })
        $idsAfter = @($after -split "`n" | Where-Object { $_ -match '^VER ' } | ForEach-Object { ($_ -split ' ')[2] })
        Assert-Equal ($idsBefore -join ',') ($idsAfter -join ',') 'A macro id changed.'
        Assert-True ($after -match '"134400"') 'The icon was lost.'
    }

    It 'never touches a macro the user named' {
        $named = Set-BlankMacroName -Text (New-MacroCache -Name @(' ', 'weps', ' ', 'br mock'))
        $names = @(Get-MacroCacheEntry -Text $named | ForEach-Object { $_.Name })
        Assert-Equal 'weps' $names[1]
        Assert-Equal 'br mock' $names[3]
    }

    It 'cannot hand a generated name to a macro that already has one' {
        # A user who named a macro with a single space would otherwise collide
        # with the first generated name.
        $named = Set-BlankMacroName -Text (New-MacroCache -Name @('', ' ', ''))
        $names = @(Get-MacroCacheEntry -Text $named | ForEach-Object { $_.Name })
        Assert-Equal 3 @($names | Select-Object -Unique).Count "Collided with an existing name: $($names.Count)"
    }

    It 'does nothing when every macro is already named' {
        Assert-Equal $null (Set-BlankMacroName -Text (New-MacroCache -Name @('one', 'two')))
    }

    It 'changes nothing the second time' {
        $once = Set-BlankMacroName -Text (New-MacroCache -Name @(' ', ' ', ' '))
        Assert-Equal $null (Set-BlankMacroName -Text $once) 'A second pass would make every Apply report work forever.'
    }

    It 'keeps the line endings the file had' {
        $text = (New-MacroCache -Name @(' ', ' ')) -replace "`n", "`r`n"
        $named = Set-BlankMacroName -Text $text
        Assert-Equal 0 ([regex]::Matches($named, "(?<!`r)`n").Count) 'A bare newline was introduced into a CRLF file.'
    }
}

Describe 'Planning the rename into a copy' {

    It 'replaces the copy of the cache with a named-up one' {
        $source = Join-Path $script:TestDrive 'live'
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $source 'macros-cache.txt') -Content (New-MacroCache)
        $null = New-TestFile -Path (Join-Path $source 'bindings-cache.wtf') -Content "bindings`n"

        $copies = @(New-TreeCopyPlan -Source $source -Destination $target)
        $renamed = @(New-MacroNamePlan -Action $copies)
        Assert-Equal 1 $renamed.Count 'Only the macro cache should be rewritten.'
        Assert-Equal 'macros-cache.txt' (Split-Path -Leaf $renamed[0].Destination)
        Assert-Equal '' $renamed[0].Source 'It must carry content, not copy the blank-named original.'
    }

    It 'reports a skip once the PTR copy is already named' {
        $source = Join-Path $script:TestDrive 'live'
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $source 'macros-cache.txt') -Content (New-MacroCache)
        $null = New-TestFile -Path (Join-Path $target 'macros-cache.txt') -Content (Set-BlankMacroName -Text (New-MacroCache))

        $renamed = @(New-MacroNamePlan -Action (New-TreeCopyPlan -Source $source -Destination $target))
        Assert-Equal 1 $renamed.Count
        Assert-Equal 'skip' $renamed[0].Kind
    }

    It 'never plans anything outside the PTR folder' {
        $source = Join-Path $script:TestDrive 'live'
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $source 'macros-cache.txt') -Content (New-MacroCache)
        foreach ($action in (New-MacroNamePlan -Action (New-TreeCopyPlan -Source $source -Destination $target))) {
            Assert-True (Test-PathWithin -Path $action.Destination -Parent $target) `
                "A rename action targets $($action.Destination), outside the PTR folder."
        }
    }
}
