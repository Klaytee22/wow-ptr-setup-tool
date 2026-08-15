<#
    The Ace3 region workaround. AceDB looks its region up in a five-entry table
    and a PTR realm reports an id that is not in it, so the key comes back nil
    and the concatenation on the next line throws while the addon is starting.
    Every Ace3 addon shares one copy of the library through LibStub, so one stale
    copy takes them all down at once and the user sees a UI that simply does not
    work.

    The patch is one expression in somebody else's code, so these care as much
    about what is left alone as about what changes.
#>

function New-AceDbSource {
    param([string] $Assignment = 'local regionKey = regionTable[GetCurrentRegion()]')

    return @"
-- AceDB-3.0
local regionTable = { "US", "KR", "EU", "TW", "CN" }
local charKey = UnitName("player") .. " - " .. GetRealmName()
local classKey = UnitClass("player")
	$Assignment
local factionrealmregionKey = factionrealmKey .. " - " .. regionKey
return AceDB
"@
}

Describe 'Spotting the Ace3 region bug' {

    It 'recognises the assignment that fails on a PTR realm' {
        Assert-True (Test-AceDbRegionBug -Text (New-AceDbSource))
    }

    It 'leaves a copy that already has a fallback alone' {
        Assert-False (Test-AceDbRegionBug -Text (New-AceDbSource -Assignment 'local regionKey = regionTable[GetCurrentRegion()] or "US"'))
        Assert-Equal $null (Update-AceDbRegionKey -Text (New-AceDbSource -Assignment 'local regionKey = regionTable[GetCurrentRegion()] or "US"'))
    }

    It 'leaves a copy that guards the index instead alone' {
        Assert-False (Test-AceDbRegionBug -Text (New-AceDbSource -Assignment 'local regionKey = regionTable[GetCurrentRegion() or 1]'))
    }

    It 'copes with the spacing and naming Ace3 has shipped' {
        foreach ($assignment in @(
                'local regionKey = regionTable[GetCurrentRegion()]',
                'local region  =  REGION_TABLE[ GetCurrentRegion() ]',
                "local regionKey`t=`tregionTable[GetCurrentRegion()]")) {
            Assert-True (Test-AceDbRegionBug -Text (New-AceDbSource -Assignment $assignment)) "Missed: $assignment"
        }
    }

    It 'says nothing about a file that is not AceDB at all' {
        Assert-False (Test-AceDbRegionBug -Text "local x = 1`nreturn x`n")
    }
}

Describe 'Patching the region lookup' {

    It 'gives the lookup a fallback' {
        $fixed = Update-AceDbRegionKey -Text (New-AceDbSource)
        Assert-True ($fixed -match 'regionTable\[GetCurrentRegion\(\)\] or "US"') "Not patched:`n$fixed"
    }

    It 'changes that one line and nothing else' {
        $before = New-AceDbSource
        $after = Update-AceDbRegionKey -Text $before
        $changed = @($after -split "`n" | Where-Object { $_ -notin @($before -split "`n") })
        Assert-Equal 1 $changed.Count "More than the one assignment changed:`n$($changed -join "`n")"
        Assert-True ($after -match 'UnitName\("player"\) \.\. " - " \.\. GetRealmName\(\)') 'The character key was disturbed.'
        Assert-True ($after -match 'return AceDB') 'The tail of the file was lost.'
    }

    It 'keeps the indentation the line had' {
        $fixed = Update-AceDbRegionKey -Text (New-AceDbSource)
        Assert-True ($fixed -match "`tlocal regionKey") 'The leading tab was eaten.'
    }

    It 'is a no-op the second time' {
        $once = Update-AceDbRegionKey -Text (New-AceDbSource)
        Assert-Equal $null (Update-AceDbRegionKey -Text $once) 'Running twice would make every Apply report work forever.'
    }
}

Describe 'Planning the patch into an addon copy' {

    function New-AddOnTree {
        param([string] $Root, [string] $Origin = 'LIVE', [string] $Assignment)

        $lib = Join-Path $Root 'Bartender4/Libs/AceDB-3.0/AceDB-3.0.lua'
        if ($PSBoundParameters.ContainsKey('Assignment')) {
            $null = New-TestFile -Path $lib -Content (New-AceDbSource -Assignment $Assignment)
        }
        else {
            $null = New-TestFile -Path $lib -Content (New-AceDbSource)
        }
        $null = New-TestFile -Path (Join-Path $Root 'Bartender4/Bartender4.lua') -Content "-- $Origin`n"
        return $Root
    }

    It 'replaces the copy of the library with a patched one' {
        $source = New-AddOnTree -Root (Join-Path $script:TestDrive 'live')
        $target = Join-Path $script:TestDrive 'ptr'

        $copies = @(New-TreeCopyPlan -Source $source -Destination $target)
        $patched = @(New-AceDbPatchPlan -Action $copies)
        Assert-Equal 1 $patched.Count 'Exactly the one library file should be patched.'
        Assert-Equal 'create' $patched[0].Kind
        Assert-Equal '' $patched[0].Source 'A patched file must carry content, not copy the unpatched original.'
        Assert-True ($patched[0].Content -match 'or "US"')

        $merged = @(Merge-FileActionPlan -Action $copies -Override $patched)
        Assert-Equal $copies.Count $merged.Count 'The patch should stand in for the copy, not be added to it.'
    }

    It 'leaves every other file in the addon to the plain copy' {
        $source = New-AddOnTree -Root (Join-Path $script:TestDrive 'live')
        $copies = @(New-TreeCopyPlan -Source $source -Destination (Join-Path $script:TestDrive 'ptr'))
        $patched = @(New-AceDbPatchPlan -Action $copies)
        Assert-Equal @('AceDB-3.0.lua') @($patched | ForEach-Object { Split-Path -Leaf $_.Destination })
    }

    It 'plans nothing for an addon whose Ace3 is current' {
        $source = New-AddOnTree -Root (Join-Path $script:TestDrive 'live') -Assignment 'local regionKey = regionTable[GetCurrentRegion()] or "US"'
        $copies = @(New-TreeCopyPlan -Source $source -Destination (Join-Path $script:TestDrive 'ptr'))
        Assert-Equal 0 @(New-AceDbPatchPlan -Action $copies).Count
    }

    It 'reports a skip once the PTR copy is already patched' {
        # Not nothing: these stand in for the plain copies, and without one here
        # the copy would put the unpatched library back on the next Apply.
        $source = New-AddOnTree -Root (Join-Path $script:TestDrive 'live')
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $target 'Bartender4/Libs/AceDB-3.0/AceDB-3.0.lua') `
            -Content (Update-AceDbRegionKey -Text (New-AceDbSource))

        $copies = @(New-TreeCopyPlan -Source $source -Destination $target)
        $patched = @(New-AceDbPatchPlan -Action $copies)
        Assert-Equal 1 $patched.Count
        Assert-Equal 'skip' $patched[0].Kind
    }

    It 'stays out of the way when overwriting is turned off' {
        $source = New-AddOnTree -Root (Join-Path $script:TestDrive 'live')
        $target = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $target 'Bartender4/Libs/AceDB-3.0/AceDB-3.0.lua') -Content '-- the PTR own'
        Assert-Equal 0 @(New-AceDbPatchPlan -Action (New-TreeCopyPlan -Source $source -Destination $target -Overwrite $false) -Overwrite $false).Count
    }

    It 'only ever touches files named AceDB-3.0.lua' {
        # The scoping guarantee. The pattern is narrow, but "narrow" is not the
        # promise — the promise is that nothing but the library is rewritten, and
        # an addon is free to have a line that happens to look like AceDB's.
        $source = New-AddOnTree -Root (Join-Path $script:TestDrive 'live')
        $null = New-TestFile -Path (Join-Path $source 'Bartender4/Regions.lua') -Content (New-AceDbSource)
        $null = New-TestFile -Path (Join-Path $source 'Bartender4/Libs/AceDB-3.0/AceDB-3.0.bak.lua') -Content (New-AceDbSource)

        $copies = @(New-TreeCopyPlan -Source $source -Destination (Join-Path $script:TestDrive 'ptr'))
        $patched = @(New-AceDbPatchPlan -Action $copies)
        Assert-Equal @('AceDB-3.0.lua') @($patched | ForEach-Object { Split-Path -Leaf $_.Destination }) `
            'Something other than the library was rewritten.'
    }

    It 'never plans anything outside the PTR folder' {
        # The invariant the whole tool rests on: the live client is read, never
        # written. A patch action pointing at the source would break it.
        $source = New-AddOnTree -Root (Join-Path $script:TestDrive 'live')
        $target = Join-Path $script:TestDrive 'ptr'
        foreach ($action in (New-AceDbPatchPlan -Action (New-TreeCopyPlan -Source $source -Destination $target))) {
            Assert-True (Test-PathWithin -Path $action.Destination -Parent $target) `
                "A patch action targets $($action.Destination), which is outside the PTR folder."
        }
    }
}
