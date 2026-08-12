<#
    End-to-end tests over the real mock folder from tools/New-MockWowFolder.ps1 —
    the same one you build on Windows to try the window by hand. Where the unit
    tests check one function, these walk the guide from start to finish and
    assert on what actually ends up on disk, instruction by instruction.

    Using the shipped mock builder rather than a test-only fixture means the
    builder is tested too: if it stops producing a realistic install, these fail.
#>

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$mockBuilder = Join-Path $repoRoot 'tools/New-MockWowFolder.ps1'

function New-MockEnvironment {
    <#
        Builds the mock folder and returns a context selected the way the window
        selects one on startup.
    #>
    param([string] $Root)

    $null = & $mockBuilder -Path $Root -Force -Quiet
    $wowFolder = Join-Path $Root 'World of Warcraft'
    $installs = @(Get-WowInstall -Path $wowFolder -SkipDefaultLocations)
    return [pscustomobject]@{
        WowFolder = $wowFolder
        Installs  = $installs
        Context   = Initialize-PtrSetupContext -Install $installs
    }
}

function Get-TreeSnapshot {
    <#
        Path + content hash of every file under a folder, so a tree can be
        compared with itself later. Backups are excluded — they are supposed to
        appear.
    #>
    param([string] $Root)

    $lines = foreach ($file in (Get-RelativeFile -Root $Root)) {
        if ($file.Relative -like "_ptrsetup_backups*") { continue }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        '{0}|{1}' -f $file.Relative, $hash
    }
    return (@($lines) -join "`n")
}

function Get-AutoStepId {
    return @((Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' }).Id)
}

Describe 'The mock environment' {

    It 'builds a live client and a PTR client the tool recognises' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        Assert-Equal @('_classic_', '_classic_ptr_') @($mock.Installs.DirName | Sort-Object)
        Assert-True ($mock.Installs | Where-Object { $_.IsPtr }).HasBeenLaunched
    }

    It 'opens with the right clients, accounts and character mapping selected' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $context = $mock.Context

        Assert-Equal '_classic_' $context.Source.DirName
        Assert-Equal '_classic_ptr_' $context.Target.DirName
        Assert-Equal '112233445#1' $context.SourceAccount
        Assert-Equal '112233445#1' $context.TargetAccount

        # Only Sunderfury was copied to the PTR, so only Sunderfury maps —
        # across a realm rename the guide warns about.
        Assert-Equal 1 $context.Character.Count
        Assert-Equal 'Sunderfury' $context.Character[0].Target.Name
        Assert-Equal 'Whitemane' $context.Character[0].Source.Realm
        Assert-Equal 'Classic PTR Realm 1' $context.Character[0].Target.Realm
    }

    It 'starts with every automated step ready and nothing done' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        foreach ($id in (Get-AutoStepId)) {
            $status = Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id $id) -Context $mock.Context
            Assert-Equal 'ready' $status.State "Expected $id to be ready on a fresh mock install."
        }
    }
}

Describe 'Preview' {

    It 'changes nothing on either side' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $beforePtr = Get-TreeSnapshot -Root $mock.Context.Target.Path
        $beforeLive = Get-TreeSnapshot -Root $mock.Context.Source.Path

        $results = @(Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId) -PreviewOnly)
        Assert-Equal (Get-AutoStepId).Count $results.Count
        Assert-True (@($results | Where-Object { $_.Ok }).Count -eq $results.Count)

        Assert-Equal $beforePtr (Get-TreeSnapshot -Root $mock.Context.Target.Path)
        Assert-Equal $beforeLive (Get-TreeSnapshot -Root $mock.Context.Source.Path)
    }

    It 'promises exactly the files the apply then touches' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $previewed = @(Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId) -PreviewOnly |
                ForEach-Object { $_.Actions } | ForEach-Object { '{0}|{1}' -f $_.Kind, $_.Destination })
        $applied = @(Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId) |
                ForEach-Object { $_.Actions } | ForEach-Object { '{0}|{1}' -f $_.Kind, $_.Destination })

        # The apply may do less than the preview promised, never more: each step
        # re-plans against the state the earlier steps left behind. Here
        # copy_config_wtf already sets checkAddonVersion, so by the time
        # allow_out_of_date_addons runs there is nothing left for it to write.
        $surprises = @($applied | Where-Object { $previewed -notcontains $_ })
        Assert-Equal 0 $surprises.Count ("Applied something the preview did not list: " + ($surprises -join ', '))

        # No file is touched that the preview did not name.
        Assert-Equal @($previewed | Sort-Object -Unique) @(@($applied) + @($previewed | Where-Object { $applied -notcontains $_ }) | Sort-Object -Unique)
    }

    It 'only ever promises more than it does when a later step is already satisfied' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $previewed = @(Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId) -PreviewOnly |
                ForEach-Object { $_.Actions } | ForEach-Object { '{0}|{1}' -f $_.Kind, $_.Destination })
        $applied = @(Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId) |
                ForEach-Object { $_.Actions } | ForEach-Object { '{0}|{1}' -f $_.Kind, $_.Destination })

        $extra = @($previewed | Where-Object { $applied -notcontains $_ } | Sort-Object -Unique)
        foreach ($entry in $extra) {
            Assert-True ($entry -like '*Config.wtf') "Preview listed something the apply skipped: $entry"
        }
    }
}

Describe 'A full run, instruction by instruction' {

    It 'copies the addons and clears the ones the live client does not have' {
        # Guide: "Delete any addons there if you have any. Paste your addons."
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $ptrAddons = @(Get-ChildItem -LiteralPath $mock.Context.Target.AddOns -Directory).Name | Sort-Object
        Assert-Equal @('Bartender4', 'Details', 'Plater', 'Questie', 'WeakAuras') $ptrAddons
        Assert-False (Test-Path -LiteralPath (Join-Path $mock.Context.Target.AddOns 'OldPtrAddon'))

        $toc = Get-Content -LiteralPath (Join-Path $mock.Context.Target.AddOns 'WeakAuras/WeakAuras.toc') -Raw
        Assert-True ($toc -match 'LIVE') 'The addon on the PTR should be the live copy.'
    }

    It "copies the character's addon settings" {
        # Guide: character SavedVariables -> the PTR character's SavedVariables.
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $characterDir = Get-WowCharacterPath -Install $mock.Context.Target -Character $mock.Context.Character[0].Target
        $saved = Get-Content -LiteralPath (Join-Path $characterDir 'SavedVariables/WeakAuras.lua') -Raw
        Assert-True ($saved -match 'LIVE WeakAuras profile for Sunderfury') "Character SavedVariables did not come across: $saved"
    }

    It 'copies the account-wide addon settings the guide leaves you to redo by hand' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $accountDir = Get-ContextAccountPath -Context $mock.Context -Side 'Target'
        $saved = Get-Content -LiteralPath (Join-Path $accountDir 'SavedVariables/Plater.lua') -Raw
        Assert-True ($saved -match 'LIVE account-wide') 'Account-wide profiles did not come across.'
    }

    It 'copies the client settings but keeps the PTR realm' {
        # Guide: paste Config.wtf wholesale. This tool merges instead, so the PTR
        # client keeps pointing at PTR realms — see docs/GUIDE.md.
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $config = Read-ConfigWtf -Path $mock.Context.Target.ConfigWtf
        Assert-Equal '2560x1440' $config['gxResolution']
        Assert-Equal '3' $config['weatherDensity']
        Assert-Equal '0.35' $config['Sound_MasterVolume']
        Assert-Equal 'us.logon-ptr.worldofwarcraft.com' $config['realmList']
        Assert-Equal 'us-ptr' $config['portal']
        Assert-Equal '0' $config['checkAddonVersion']
    }

    It "copies the character's own settings" {
        # Guide: config-cache.wtf — max camera distance, floating combat text.
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $characterDir = Get-WowCharacterPath -Install $mock.Context.Target -Character $mock.Context.Character[0].Target
        $cache = ConvertFrom-ConfigWtf -Text (Get-Content -LiteralPath (Join-Path $characterDir 'config-cache.wtf') -Raw)
        Assert-Equal '2.6' $cache['cameraDistanceMaxZoomFactor']
        Assert-Equal '1' $cache['floatingCombatTextCombatDamage']
    }

    It 'copies keybindings at both levels' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $accountDir = Get-ContextAccountPath -Context $mock.Context -Side 'Target'
        $characterDir = Get-WowCharacterPath -Install $mock.Context.Target -Character $mock.Context.Character[0].Target

        Assert-True ((Get-Content -LiteralPath (Join-Path $accountDir 'bindings-cache.wtf') -Raw) -match 'LIVE account-wide keybinds')
        Assert-True ((Get-Content -LiteralPath (Join-Path $characterDir 'bindings-cache.wtf') -Raw) -match 'LIVE character keybinds')
    }

    It 'copies macros at both levels' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $accountDir = Get-ContextAccountPath -Context $mock.Context -Side 'Target'
        $characterDir = Get-WowCharacterPath -Install $mock.Context.Target -Character $mock.Context.Character[0].Target

        Assert-True ((Get-Content -LiteralPath (Join-Path $accountDir 'macros-cache.txt') -Raw) -match 'AccountWide LIVE')
        Assert-True ((Get-Content -LiteralPath (Join-Path $characterDir 'macros-cache.txt') -Raw) -match 'MACRO Pull LIVE')
    }

    It 'leaves the live client byte-for-byte unchanged' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $before = Get-TreeSnapshot -Root $mock.Context.Source.Path
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)
        Assert-Equal $before (Get-TreeSnapshot -Root $mock.Context.Source.Path)
    }

    It 'touches no character that was not mapped' {
        # Mendicant and Bankalt exist on live but were never copied to the PTR.
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $realmDir = Join-Path (Join-Path $mock.Context.Target.AccountRoot '112233445#1') 'Classic PTR Realm 1'
        Assert-Equal @('Sunderfury') @((Get-ChildItem -LiteralPath $realmDir -Directory).Name)
    }

    It 'reports every step done afterwards, and does nothing on a second run' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)

        $mock.Context.Options['Overwrite'] = $false
        foreach ($id in (Get-AutoStepId)) {
            $status = Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id $id) -Context $mock.Context
            Assert-Equal 'done' $status.State "Expected $id to be done after a full run."
        }

        $afterFirst = Get-TreeSnapshot -Root $mock.Context.Target.Path
        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)
        Assert-Equal $afterFirst (Get-TreeSnapshot -Root $mock.Context.Target.Path)
    }
}

Describe 'Undo' {

    It 'puts the PTR client back exactly as it was' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $before = Get-TreeSnapshot -Root $mock.Context.Target.Path

        $null = Invoke-PtrSetup -Context $mock.Context -StepId (Get-AutoStepId)
        Assert-True ((Get-TreeSnapshot -Root $mock.Context.Target.Path) -ne $before) 'The run should have changed something.'

        # Newest first, so the oldest backup is restored last and wins.
        foreach ($backup in (Get-PtrSetupBackup -InstallPath $mock.Context.Target.Path)) {
            $null = Restore-PtrSetupBackup -InstallPath $mock.Context.Target.Path -BackupId $backup.Id
        }
        Assert-Equal $before (Get-TreeSnapshot -Root $mock.Context.Target.Path)
    }

    It 'brings back an addon the run removed' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId @('copy_addons')
        Assert-False (Test-Path -LiteralPath (Join-Path $mock.Context.Target.AddOns 'OldPtrAddon'))

        $backup = @(Get-PtrSetupBackup -InstallPath $mock.Context.Target.Path)[0]
        $undo = Restore-PtrSetupBackup -InstallPath $mock.Context.Target.Path -BackupId $backup.Id

        Assert-True (Test-Path -LiteralPath (Join-Path $mock.Context.Target.AddOns 'OldPtrAddon/OldPtrAddon.toc'))
        Assert-False (Test-Path -LiteralPath (Join-Path $mock.Context.Target.AddOns 'Questie')) 'Added addons should be removed by the undo.'
        Assert-True ($undo.Removed -gt 0)
    }

    It 'can put replaced files back while keeping what was added' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId @('copy_addons')

        $backup = @(Get-PtrSetupBackup -InstallPath $mock.Context.Target.Path)[0]
        $undo = Restore-PtrSetupBackup -InstallPath $mock.Context.Target.Path -BackupId $backup.Id -KeepAdded

        Assert-Equal 0 $undo.Removed
        Assert-True (Test-Path -LiteralPath (Join-Path $mock.Context.Target.AddOns 'Questie'))
        Assert-True (Test-Path -LiteralPath (Join-Path $mock.Context.Target.AddOns 'OldPtrAddon/OldPtrAddon.toc'))
    }
}

Describe 'Options change what a run does' {

    It 'leaves PTR-only addons alone when replacing is off' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $mock.Context.Options['ReplaceAddOns'] = $false
        $null = Invoke-PtrSetup -Context $mock.Context -StepId @('copy_addons')

        Assert-True (Test-Path -LiteralPath (Join-Path $mock.Context.Target.AddOns 'OldPtrAddon'))
        Assert-True (Test-Path -LiteralPath (Join-Path $mock.Context.Target.AddOns 'WeakAuras'))
    }

    It 'leaves keybinds and macros alone when that option is off' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $mock.Context.Options['IncludeMacrosBindings'] = $false
        $null = Invoke-PtrSetup -Context $mock.Context -StepId @('copy_account_saved_variables', 'copy_character_data')

        $accountDir = Get-ContextAccountPath -Context $mock.Context -Side 'Target'
        Assert-True ((Get-Content -LiteralPath (Join-Path $accountDir 'bindings-cache.wtf') -Raw) -match 'PTR account-wide keybinds')
        # Character settings still came across — only the caches were held back.
        $characterDir = Get-WowCharacterPath -Install $mock.Context.Target -Character $mock.Context.Character[0].Target
        Assert-True ((Get-Content -LiteralPath (Join-Path $characterDir 'AddOns.txt') -Raw) -match 'LIVE')
    }

    It 'skips existing files when overwriting is off' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $mock.Context.Options['Overwrite'] = $false
        $mock.Context.Options['ReplaceAddOns'] = $false
        $null = Invoke-PtrSetup -Context $mock.Context -StepId @('copy_character_data')

        $characterDir = Get-WowCharacterPath -Install $mock.Context.Target -Character $mock.Context.Character[0].Target
        # The PTR character already had these, so they stay as they were...
        Assert-True ((Get-Content -LiteralPath (Join-Path $characterDir 'AddOns.txt') -Raw) -match 'PTR')
        # ...while the live-only file still arrives.
        Assert-True ((Get-Content -LiteralPath (Join-Path $characterDir 'SavedVariables/Details.lua') -Raw) -match 'PTR|LIVE')
    }

    It 'can be pointed at one step without touching the others' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $null = Invoke-PtrSetup -Context $mock.Context -StepId @('copy_addons')

        $config = Read-ConfigWtf -Path $mock.Context.Target.ConfigWtf
        Assert-Equal '1920x1080' $config['gxResolution'] 'Config.wtf should be untouched when only the addon step runs.'
    }
}

Describe 'Awkward situations' {

    It 'blocks the character step when nothing has been copied to the PTR yet' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $realmDir = Join-Path (Join-Path $mock.Context.Target.AccountRoot '112233445#1') 'Classic PTR Realm 1'
        Remove-Item -LiteralPath $realmDir -Recurse -Force

        $context = Initialize-PtrSetupContext -Install @(Get-WowInstall -Path $mock.WowFolder -SkipDefaultLocations)
        $status = Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'copy_character_data') -Context $context
        Assert-Equal 'blocked' $status.State
        Assert-Equal 'ready' (Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'copy_character') -Context $context).State
    }

    It 'still copies everything else when the PTR client has never been launched' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        Remove-Item -LiteralPath $mock.Context.Target.Wtf -Recurse -Force

        $context = Initialize-PtrSetupContext -Install @(Get-WowInstall -Path $mock.WowFolder -SkipDefaultLocations)
        Assert-Equal 'ready' (Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'install_ptr_client') -Context $context).State

        $result = @(Invoke-PtrSetup -Context $context -StepId @('copy_addons'))[0]
        Assert-True $result.Ok
        Assert-True (Test-Path -LiteralPath (Join-Path $context.Target.AddOns 'WeakAuras'))
    }

    It 'refuses to treat the live client as the target by accident' {
        # Whatever is selected, a plan may only write inside the chosen PTR folder.
        $mock = New-MockEnvironment -Root $script:TestDrive
        $stray = New-FileAction -Kind 'overwrite' -Destination (Join-Path $mock.Context.Source.Path 'WTF/Config.wtf') -Content 'nope'
        Assert-Throws {
            Invoke-FileActionPlan -Action @($stray) -InstallPath $mock.Context.Target.Path -Label 'stray'
        } -Match 'outside'
    }

    It 'handles a PTR account folder with a different name' {
        $mock = New-MockEnvironment -Root $script:TestDrive
        $oldAccount = Join-Path $mock.Context.Target.AccountRoot '112233445#1'
        Rename-Item -LiteralPath $oldAccount -NewName '998877665#1'

        $context = Initialize-PtrSetupContext -Install @(Get-WowInstall -Path $mock.WowFolder -SkipDefaultLocations)
        Assert-Equal '112233445#1' $context.SourceAccount
        Assert-Equal '998877665#1' $context.TargetAccount

        $null = Invoke-PtrSetup -Context $context -StepId @('copy_account_saved_variables')
        $accountDir = Get-ContextAccountPath -Context $context -Side 'Target'
        Assert-True ((Get-Content -LiteralPath (Join-Path $accountDir 'SavedVariables/Plater.lua') -Raw) -match 'LIVE')
    }
}
