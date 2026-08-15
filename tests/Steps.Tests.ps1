Describe 'copy_addons' {

    It 'copies the whole addon folder across' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $step = Get-PtrSetupStep -Id 'copy_addons'
        Assert-Equal 'ready' (Get-PtrSetupStepStatus -Step $step -Context $context).State

        $null = Invoke-PtrSetupStep -Step $step -Context $context
        Assert-True (Test-Path -LiteralPath (Join-Path $context.Target.AddOns 'WeakAuras/WeakAuras.toc'))
        Assert-True (Test-Path -LiteralPath (Join-Path $context.Target.AddOns 'Details/Details.lua'))
    }

    It 'is blocked when the live client has no addon folder' {
        $root = Join-Path $script:TestDrive 'World of Warcraft'
        $null = New-FakeInstall -Root $root -Flavor '_classic_' -AddOn @()
        $null = New-FakeInstall -Root $root -Flavor '_classic_ptr_' -AddOn @()
        $installs = @(Get-WowInstall -Path $root -SkipDefaultLocations)
        $context = New-PtrSetupContext -Source ($installs | Where-Object { -not $_.IsPtr }) -Target ($installs | Where-Object { $_.IsPtr })

        $status = Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'copy_addons') -Context $context
        Assert-Equal 'blocked' $status.State
        Assert-True ($status.Detail -match 'AddOns')
    }

    It 'reports done once every file is already there' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $step = Get-PtrSetupStep -Id 'copy_addons'
        $null = Invoke-PtrSetupStep -Step $step -Context $context

        $context.Options['Overwrite'] = $false
        Assert-Equal 'done' (Get-PtrSetupStepStatus -Step $step -Context $context).State
    }
}

Describe 'copy_config_wtf' {

    It 'merges live settings in without stealing the realm list' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $null = Invoke-PtrSetupStep -Step (Get-PtrSetupStep -Id 'copy_config_wtf') -Context $context

        $written = Read-ConfigWtf -Path $context.Target.ConfigWtf
        Assert-Equal '2560x1440' $written['gxResolution']
        Assert-Equal 'us.logon-ptr.worldofwarcraft.com' $written['realmList']
        # checkAddonVersion is not this step's business — allow_out_of_date_addons
        # owns it, and two steps writing one key is how the option that appeared
        # to control it ended up controlling nothing.
        Assert-False $written.Contains('checkAddonVersion')
    }

    It 'reports done, not blocked, once it has run' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $step = Get-PtrSetupStep -Id 'copy_config_wtf'
        $null = Invoke-PtrSetupStep -Step $step -Context $context

        $status = Get-PtrSetupStepStatus -Step $step -Context $context
        Assert-Equal 'done' $status.State
        Assert-True ($status.Detail -match 'up to date')
    }

    It 'is exactly one step that sets checkAddonVersion' {
        # It used to be two, so unticking the step changed nothing: the merge had
        # already written the key on the way past.
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $writers = foreach ($step in (Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' })) {
            $plan = @(New-PtrSetupStepPlan -Step $step -Context $context)
            if (@($plan | Where-Object { $_.Content -match 'checkAddonVersion' })) { $step.Id }
        }
        Assert-Equal @('allow_out_of_date_addons') @($writers)
    }
}

Describe 'copy_account_saved_variables' {

    It 'copies SavedVariables plus the macro and keybind caches' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $null = Invoke-PtrSetupStep -Step (Get-PtrSetupStep -Id 'copy_account_saved_variables') -Context $context

        $accountDir = Get-ContextAccountPath -Context $context -Side 'Target'
        Assert-True (Test-Path -LiteralPath (Join-Path $accountDir 'SavedVariables/WeakAuras.lua'))
        Assert-True (Test-Path -LiteralPath (Join-Path $accountDir 'macros-cache.txt'))
    }

    It 'leaves macros out when the option is off' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $context.Options['IncludeMacrosBindings'] = $false
        $plan = @(New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id 'copy_account_saved_variables') -Context $context)
        Assert-Equal 0 @($plan | Where-Object { $_.Destination -like '*macros-cache*' }).Count
    }

    It 'is blocked without an account on both sides' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $context.TargetAccount = $null
        Assert-Equal 'blocked' (Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'copy_account_saved_variables') -Context $context).State
    }
}

Describe 'copy_character_data' {

    It 'copies into the mapped PTR character, realm rename and all' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $null = Invoke-PtrSetupStep -Step (Get-PtrSetupStep -Id 'copy_character_data') -Context $context

        $characterDir = Join-Path $context.Target.AccountRoot '12345678#1/PTR Whitemane/Bankalt'
        Assert-True (Test-Path -LiteralPath (Join-Path $characterDir 'SavedVariables/WeakAuras.lua'))
        Assert-True (Test-Path -LiteralPath (Join-Path $characterDir 'AddOns.txt'))
        Assert-True (Test-Path -LiteralPath (Join-Path $characterDir 'layout-local.txt'))
    }

    It 'is blocked until a character is mapped' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $context.Character = @()
        $status = Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'copy_character_data') -Context $context
        Assert-Equal 'blocked' $status.State
        Assert-True ($status.Detail -match 'character')
    }

    It 'includes the chat cache only when a script asks for it' {
        # No longer a checkbox, but the module still honours it — the window is
        # what was decluttered, not the capability.
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $sourceDir = Get-WowCharacterPath -Install $context.Source -Character $context.Character[0].Source
        $null = New-TestFile -Path (Join-Path $sourceDir 'chat-cache.txt') -Content 'chat'

        $step = Get-PtrSetupStep -Id 'copy_character_data'
        Assert-Equal 0 @(@(New-PtrSetupStepPlan -Step $step -Context $context) | Where-Object { $_.Destination -like '*chat-cache*' }).Count

        $context.Options['IncludeChatCache'] = $true
        Assert-Equal 1 @(@(New-PtrSetupStepPlan -Step $step -Context $context) | Where-Object { $_.Destination -like '*chat-cache*' }).Count
    }
}

Describe 'allow_out_of_date_addons' {

    It 'flips the setting and then reports done' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $step = Get-PtrSetupStep -Id 'allow_out_of_date_addons'
        Assert-Equal 'ready' (Get-PtrSetupStepStatus -Step $step -Context $context).State

        $null = Invoke-PtrSetupStep -Step $step -Context $context
        Assert-Equal '0' (Read-ConfigWtf -Path $context.Target.ConfigWtf)['checkAddonVersion']
        Assert-Equal 'done' (Get-PtrSetupStepStatus -Step $step -Context $context).State
    }

    It 'keeps the PTR realm list while flipping the setting' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $null = Invoke-PtrSetupStep -Step (Get-PtrSetupStep -Id 'allow_out_of_date_addons') -Context $context
        Assert-Equal 'us.logon-ptr.worldofwarcraft.com' (Read-ConfigWtf -Path $context.Target.ConfigWtf)['realmList']
    }
}

Describe 'Manual steps' {

    It 'tracks the PTR WTF folder for the install step' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        Assert-Equal 'done' (Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'install_ptr_client') -Context $context).State
    }

    It 'needs an acknowledgement for the closing check' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $step = Get-PtrSetupStep -Id 'verify_in_game'
        Assert-Equal 'ready' (Get-PtrSetupStepStatus -Step $step -Context $context).State
        $null = $context.Acknowledged.Add('verify_in_game')
        Assert-Equal 'done' (Get-PtrSetupStepStatus -Step $step -Context $context).State
    }

    It 'succeeds without touching disk' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $result = Invoke-PtrSetupStep -Step (Get-PtrSetupStep -Id 'copy_character') -Context $context
        Assert-True $result.Ok
        Assert-Equal 0 @($result.Actions).Count
    }

    It 'every step carries instructions and a source note' {
        foreach ($step in (Get-PtrSetupStep)) {
            Assert-True ($step.Instructions.Length -gt 0) "Step $($step.Id) has no instructions."
            Assert-True ($step.SourceNote.Length -gt 0) "Step $($step.Id) has no source note."
        }
    }
}

Describe 'Invoke-PtrSetup' {

    It 'previews without writing anything' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $results = @(Invoke-PtrSetup -Context $context -StepId @('copy_addons', 'copy_config_wtf') -PreviewOnly)

        Assert-Equal 2 $results.Count
        Assert-True (@($results | Where-Object { $_.Ok -and $_.PreviewOnly }).Count -eq 2)
        Assert-False (Test-Path -LiteralPath (Join-Path $context.Target.AddOns 'WeakAuras'))
    }

    It 'runs steps in canonical order regardless of the order asked for' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $results = @(Invoke-PtrSetup -Context $context -StepId @('copy_character_data', 'copy_addons') -PreviewOnly)
        Assert-Equal @('copy_addons', 'copy_character_data') @($results.StepId)
    }

    It 'ignores unknown step ids' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        Assert-Equal 0 @(Invoke-PtrSetup -Context $context -StepId @('nope') -PreviewOnly).Count
    }

    It 'leaves nothing outstanding after a full run' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $autoIds = @((Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' }).Id)
        $results = @(Invoke-PtrSetup -Context $context -StepId $autoIds)
        Assert-Equal $autoIds.Count @($results | Where-Object { $_.Ok }).Count

        $context.Options['Overwrite'] = $false
        foreach ($id in $autoIds) {
            $status = Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id $id) -Context $context
            Assert-Equal 'done' $status.State "Step $id should be done after a full run."
        }
    }

    It 'never writes into the live client' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $before = @(Get-RelativeFile -Root $context.Source.Path).Relative
        $null = Invoke-PtrSetup -Context $context -StepId @((Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' }).Id)
        $after = @(Get-RelativeFile -Root $context.Source.Path).Relative
        Assert-Equal $before $after
    }
}

Describe 'Session helpers' {

    It 'guesses clients, accounts and characters' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = Initialize-PtrSetupContext -Install @(Get-WowInstall -Path $root -SkipDefaultLocations)

        Assert-Equal '_classic_' $context.Source.DirName
        Assert-Equal '_classic_ptr_' $context.Target.DirName
        Assert-Equal '12345678#1' $context.SourceAccount
        Assert-Equal '12345678#1' $context.TargetAccount
        Assert-Equal 1 $context.Character.Count
        Assert-Equal 'PTR Whitemane' $context.Character[0].Target.Realm
    }

    It 're-derives the character mapping when a client changes' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $installs = @(Get-WowInstall -Path $root -SkipDefaultLocations)
        $context = Initialize-PtrSetupContext -Install $installs
        Assert-Equal 'Whitemane' $context.Character[0].Source.Realm

        # Switching a client must not leave the old client's characters mapped.
        $ptr = $installs | Where-Object { $_.IsPtr }
        $context = Set-PtrSetupInstall -Context $context -Side 'Source' -Install $ptr
        Assert-True $context.Source.IsPtr
        Assert-Equal 'PTR Whitemane' $context.Character[0].Source.Realm
    }

    It 'clears the mapping outright when the new client has no matching characters' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $null = New-FakeInstall -Root $root -Flavor '_retail_' -Character @('Someoneelse')
        $installs = @(Get-WowInstall -Path $root -SkipDefaultLocations)
        $context = Initialize-PtrSetupContext -Install $installs
        Assert-Equal 1 $context.Character.Count

        $retail = $installs | Where-Object { $_.DirName -eq '_retail_' }
        $context = Set-PtrSetupInstall -Context $context -Side 'Source' -Install $retail
        Assert-Equal 0 $context.Character.Count
    }

    It 'defaults the options to a sensible copy' {
        $context = New-PtrSetupContext
        Assert-True (Get-ContextOption -Context $context -Name 'Overwrite')
        Assert-True (Get-ContextOption -Context $context -Name 'IncludeMacrosBindings')
        Assert-False (Get-ContextOption -Context $context -Name 'IncludeChatCache' -Default $false)
    }
}

Describe 'Reusing a plan' {
    <#
        The window builds each step's plan once and hands it to the status call
        rather than letting it build its own, because working one out walks the
        whole AddOns tree. That is only safe while the two agree.
    #>

    It 'reports the same status whether or not it is given the plan' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root

        foreach ($stage in @('before', 'after')) {
            if ($stage -eq 'after') { $null = Invoke-PtrSetup -Context $context -StepId (Get-PtrSetupStep).Id }

            foreach ($step in (Get-PtrSetupStep)) {
                $planned = @(New-PtrSetupStepPlan -Step $step -Context $context)
                $onItsOwn = Get-PtrSetupStepStatus -Step $step -Context $context
                $given = Get-PtrSetupStepStatus -Step $step -Context $context -Action $planned

                Assert-Equal $onItsOwn.State $given.State "$($step.Id) disagreed about State ($stage a run)."
                Assert-Equal $onItsOwn.Detail $given.Detail "$($step.Id) disagreed about Detail ($stage a run)."
            }
        }
    }

    It 'still works it out for itself when handed nothing' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $step = Get-PtrSetupStep -Id 'copy_addons'

        # An empty plan passed explicitly means "nothing to do", which is not the
        # same as not passing one at all.
        Assert-Equal 'ready' (Get-PtrSetupStepStatus -Step $step -Context $context).State
        Assert-Equal 'done' (Get-PtrSetupStepStatus -Step $step -Context $context -Action @()).State
    }
}

# Resolved here rather than inside an It: $MyInvocation.MyCommand.Path is null
# inside a scriptblock, and the worker needs a real path to import.
$script:WorkerModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PtrUiSetup/PtrUiSetup.psd1'

Describe 'Planning on another thread' {
    <#
        The window plans on a background runspace so the UI stays responsive. It
        cannot hand the live context over — two threads reading and writing the
        same hashtables is how a GUI starts producing nonsense — so it sends a
        snapshot of plain values and the worker rebuilds its own context. That is
        only sound while the rebuilt context plans identically.
    #>

    function Get-PlanText {
        param($Context)
        $out = [ordered]@{}
        foreach ($step in (Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' })) {
            $out[$step.Id] = (@(New-PtrSetupStepPlan -Step $step -Context $Context) |
                    ForEach-Object { '{0}|{1}|{2}' -f $_.Kind, $_.Destination, $_.Content }) -join "`n"
        }
        return $out
    }

    It 'plans the same from a rebuilt snapshot as from the context itself' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $context.Options['IncludeChatCache'] = $true
        $null = $context.Acknowledged.Add('verify_in_game')

        $rebuilt = ConvertFrom-PtrSetupSnapshot -Snapshot (ConvertTo-PtrSetupSnapshot -Context $context)

        Assert-Equal $context.Source.Path $rebuilt.Source.Path
        Assert-Equal $context.Target.Path $rebuilt.Target.Path
        Assert-Equal $context.SourceAccount $rebuilt.SourceAccount
        Assert-Equal $context.TargetAccount $rebuilt.TargetAccount
        Assert-Equal $context.Character.Count $rebuilt.Character.Count
        Assert-Equal $context.Character[0].Source.Id $rebuilt.Character[0].Source.Id
        Assert-Equal $context.Character[0].Target.Id $rebuilt.Character[0].Target.Id
        Assert-True $rebuilt.Options['IncludeChatCache'] 'Options must survive the trip.'
        Assert-True ($rebuilt.Acknowledged.Contains('verify_in_game')) 'Ticked manual steps must survive too.'

        $expected = Get-PlanText $context
        $actual = Get-PlanText $rebuilt
        foreach ($stepId in $expected.Keys) {
            Assert-Equal $expected[$stepId] $actual[$stepId] "$stepId planned differently after a round trip."
        }
    }

    It 'survives a snapshot with nothing selected' {
        $rebuilt = ConvertFrom-PtrSetupSnapshot -Snapshot (ConvertTo-PtrSetupSnapshot -Context (New-PtrSetupContext))
        Assert-True (-not (Test-ContextReady -Context $rebuilt))
        Assert-Equal 0 @(New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id 'copy_addons') -Context $rebuilt).Count
    }

    It 'drops a character that has gone since the snapshot was taken' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $snapshot = ConvertTo-PtrSetupSnapshot -Context $context
        Assert-Equal 1 @($snapshot.Character).Count

        Remove-Item -LiteralPath (Get-WowCharacterPath -Install $context.Target -Character $context.Character[0].Target) -Recurse -Force
        $rebuilt = ConvertFrom-PtrSetupSnapshot -Snapshot $snapshot
        Assert-Equal 0 $rebuilt.Character.Count 'A character that is no longer there must not be rebuilt.'
    }

    It 'produces the same plan inside a real background runspace' {
        # The thing the window actually does, minus the window.
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $expected = Get-PlanText $context

        $modulePath = $script:WorkerModulePath
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        try {
            $worker = [powershell]::Create()
            $worker.Runspace = $runspace
            $null = $worker.AddScript({
                    param($ModulePath, $Snapshot, $StepId)
                    Import-Module $ModulePath -Force
                    $context = ConvertFrom-PtrSetupSnapshot -Snapshot $Snapshot
                    $out = @{}
                    foreach ($id in $StepId) {
                        $out[$id] = @(New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id $id) -Context $context)
                    }
                    return $out
                })
            $null = $worker.AddArgument($modulePath)
            $null = $worker.AddArgument((ConvertTo-PtrSetupSnapshot -Context $context))
            $null = $worker.AddArgument(@($expected.Keys))

            $result = $worker.Invoke()
            Assert-Equal 0 $worker.Streams.Error.Count "The worker reported: $($worker.Streams.Error)"
            $plans = $result[0]
            $worker.Dispose()

            foreach ($stepId in $expected.Keys) {
                $text = (@($plans[$stepId]) | ForEach-Object { '{0}|{1}|{2}' -f $_.Kind, $_.Destination, $_.Content }) -join "`n"
                Assert-Equal $expected[$stepId] $text "$stepId planned differently on the worker thread."
            }
        }
        finally { $runspace.Dispose() }
    }
}

Describe 'A machine with no WoW on it' {
    <#
        The state a fresh PC is in, and the one the window starts in before it
        has found anything. Everything here has to answer rather than throw: an
        exception on this path escapes into the startup scan, and what the user
        sees is a window that opens and closes.
    #>

    It 'builds a context out of nothing at all' {
        $context = Initialize-PtrSetupContext -Install @()
        Assert-Equal $null $context.Source
        Assert-Equal $null $context.Target
        Assert-Equal 0 @(Get-ContextCharacter -Context $context).Count
        Assert-False (Test-ContextReady -Context $context)
    }

    It 'takes an empty install list at its word instead of scanning again' {
        # -Install @() means "I looked and there is nothing", not "I did not
        # look". Reading it as the second sent detection off across the registry
        # and every fixed drive, ignoring the folder the user had chosen.
        $module = Get-Module PtrUiSetup
        $original = & $module { ${function:Get-WowInstall} }
        & $module { function script:Get-WowInstall { throw 'Scanned again when it should not have.' } }
        try {
            $context = Initialize-PtrSetupContext -Install @()
            Assert-Equal $null $context.Source
        }
        finally {
            & $module { param($f) Set-Item -Path function:script:Get-WowInstall -Value $f } $original
        }
    }

    It 'gives every step a status without throwing' {
        $context = Initialize-PtrSetupContext -Install @()
        foreach ($step in (Get-PtrSetupStep)) {
            $status = Get-PtrSetupStepStatus -Step $step -Context $context
            Assert-True ($status.State -in @('blocked', 'ready', 'done')) "$($step.Id) returned $($status.State)."
        }
    }

    It 'fingerprints an empty context, processes and all' {
        # The default, not -IncludeProcesses $false: this is the call the window
        # makes on its timer, and it runs before anything has been found.
        $context = Initialize-PtrSetupContext -Install @()
        $stamp = Get-WowFolderFingerprint -Context $context
        Assert-True ($stamp -match 'Source\|none') "Expected both sides recorded as absent: $stamp"
        Assert-True ($stamp -match 'running\|') 'The process line is missing.'
    }

    It 'plans nothing rather than failing' {
        $context = Initialize-PtrSetupContext -Install @()
        foreach ($step in (Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' })) {
            Assert-Equal 0 @(New-PtrSetupStepPlan -Step $step -Context $context).Count "$($step.Id) planned work with no clients."
        }
    }
}

Describe 'A context with holes in it' {
    <#
        The module runs under Set-StrictMode -Version Latest, where .Count on
        $null is a terminating error rather than 0. Anything that reaches a step
        through the window can hand it a context whose collections have been
        cleared, and a step that falls over on one takes the whole list with it —
        which is exactly how it presented: five identical failures, no file
        counts, and Apply stuck disabled.
    #>

    It 'plans, blocks and reports status without throwing on empty collections' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $full = New-FakeContext -Root $root

        # Every shape a context's collections can arrive in.
        $shapes = @(
            @{ Name = 'no characters'; Character = @() }
            @{ Name = 'null characters'; Character = $null }
            @{ Name = 'one character'; Character = $full.Character }
        )

        foreach ($shape in $shapes) {
            $context = New-PtrSetupContext -Source $full.Source -Target $full.Target `
                -SourceAccount $full.SourceAccount -TargetAccount $full.TargetAccount
            $context.Character = $shape.Character

            foreach ($step in (Get-PtrSetupStep)) {
                # None of these may throw, whatever the context looks like.
                $null = Get-PtrSetupStepBlocker -Step $step -Context $context
                $null = Get-PtrSetupStepStatus -Step $step -Context $context
                $null = @(New-PtrSetupStepPlan -Step $step -Context $context)
            }

            $null = Set-PtrSetupCharacterGuess -Context $context
            $null = ConvertTo-PtrSetupSnapshot -Context $context
        }
    }

    It 'reports the character count from a context that never had one set' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $full = New-FakeContext -Root $root
        $context = New-PtrSetupContext -Source $full.Source -Target $full.Target `
            -SourceAccount $full.SourceAccount -TargetAccount $full.TargetAccount
        $context.Character = $null

        Assert-Equal 'ready' (Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'copy_character') -Context $context).State
        Assert-Equal 'Map at least one character first.' `
        (Get-PtrSetupStepBlocker -Step (Get-PtrSetupStep -Id 'copy_character_data') -Context $context)
    }
}

Describe 'A plan with exactly one file in it' {
    <#
        A statement used as an expression has its output unrolled, so
        "$x = if (...) { @($Action) }" hands back the bare item for a one-item
        plan and $null for an empty one. Under Set-StrictMode, .Count on either
        is a terminating error — so every step with a single file to copy threw,
        and the window reported it as "The property 'Count' cannot be found".
    #>

    It 'reports one file, not an error' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $step = Get-PtrSetupStep -Id 'copy_addons'

        $single = @(New-FileAction -Kind 'create' -Source 'a.lua' -Destination (Join-Path $root 'a.lua') -Size 10)
        Assert-Equal 1 $single.Count

        $status = Get-PtrSetupStepStatus -Step $step -Context $context -Action $single
        Assert-Equal 'ready' $status.State
        Assert-Equal '1 file(s) to copy.' $status.Detail
    }

    It 'handles every plan size the same way' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $step = Get-PtrSetupStep -Id 'copy_addons'

        foreach ($size in 0, 1, 2, 5) {
            # 1..0 counts down and yields two elements, so an empty plan is built
            # explicitly rather than from a range.
            $plan = @(if ($size -gt 0) {
                    1..$size | ForEach-Object {
                        New-FileAction -Kind 'create' -Source "s$_" -Destination (Join-Path $root "f$_") -Size 1
                    }
                })
            Assert-Equal $size $plan.Count "Test fixture built the wrong number of actions."

            $status = Get-PtrSetupStepStatus -Step $step -Context $context -Action $plan
            if ($size -eq 0) {
                Assert-Equal 'done' $status.State
            }
            else {
                Assert-Equal 'ready' $status.State "A $size-file plan should be ready."
                Assert-Equal "$size file(s) to copy." $status.Detail
            }
        }
    }

    It 'is the same through a real Config.wtf step, which is always one file' {
        # copy_config_wtf plans exactly one action, so it hit this every time.
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $step = Get-PtrSetupStep -Id 'copy_config_wtf'
        $plan = @(New-PtrSetupStepPlan -Step $step -Context $context)
        Assert-Equal 1 $plan.Count

        $status = Get-PtrSetupStepStatus -Step $step -Context $context -Action $plan
        Assert-Equal 'ready' $status.State
    }
}

Describe 'Telling the user about their macros and their bars' {

    It 'counts the live macro names that collide' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $cache = Join-Path (Get-ContextAccountPath -Context $context -Side 'Source') 'macros-cache.txt'
        $null = New-TestFile -Path $cache -Content (
            "VER 3 0100000001000001 `" `" `"1`"`n/say a`nEND`n" +
            "VER 3 0100000001000002 `" `" `"1`"`n/say b`nEND`n")

        $status = Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'name_live_macros') -Context $context
        Assert-Equal 'ready' $status.State
        Assert-True ($status.Detail -match '2 macro') "Expected a count of the clashing macros: $($status.Detail)"
    }

    It 'reports itself done when no live macro names collide' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $cache = Join-Path (Get-ContextAccountPath -Context $context -Side 'Source') 'macros-cache.txt'
        $null = New-TestFile -Path $cache -Content "VER 3 0100000001000001 `"solo`" `"1`"`n/say a`nEND`n"

        Assert-Equal 'done' (Get-PtrSetupStepStatus -Step (Get-PtrSetupStep -Id 'name_live_macros') -Context $context).State
    }

    It 'notices whether an action bar saver is installed on the live client' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $step = Get-PtrSetupStep -Id 'save_action_bars'

        $status = Get-PtrSetupStepStatus -Step $step -Context $context
        Assert-True ($status.Detail -match 'No action bar saver') "Expected it to say none is installed: $($status.Detail)"

        $null = New-TestFile -Path (Join-Path $context.Source.AddOns 'ActionBarSaverReloaded/ActionBarSaverReloaded.toc') -Content "## Title: ABS`n"
        $status = Get-PtrSetupStepStatus -Step $step -Context $context
        Assert-True ($status.Detail -match 'ActionBarSaverReloaded') "Expected it to name the addon: $($status.Detail)"
    }

    It 'never tells the user to press Rescan' {
        # The window watches the account folder, every realm under it, and the
        # process list, so a character copied onto the PTR and the game being
        # quit both register on their own. Telling someone to press a button
        # that is only there as a fallback makes the tool look like it cannot
        # see its own folders.
        foreach ($step in (Get-PtrSetupStep)) {
            Assert-True ($step.Instructions -notmatch 'Rescan') "$($step.Id) still tells the user to press Rescan."
            $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
            $detail = (Get-PtrSetupStepStatus -Step $step -Context $context).Detail
            Assert-True ($detail -notmatch 'Rescan') "$($step.Id) mentions Rescan in its status."
        }
    }

    It 'tells the user the restore command when checking the UI' {
        Assert-True ((Get-PtrSetupStep -Id 'verify_in_game').Instructions -match '/abs restore') `
            'The closing step should say how to put the bars back.'
    }

    It 'tells the user the save command before anything is copied' {
        $step = Get-PtrSetupStep -Id 'save_action_bars'
        Assert-True ($step.Instructions -match '/abs save') 'The step should give the save command.'
        $ids = @((Get-PtrSetupStep).Id)
        Assert-True ([array]::IndexOf($ids, 'save_action_bars') -lt [array]::IndexOf($ids, 'copy_addons')) `
            'Saving the bars has to come before anything is copied, or the profile is not there to copy.'
        Assert-True ([array]::IndexOf($ids, 'name_live_macros') -lt [array]::IndexOf($ids, 'save_action_bars')) `
            'The macro names have to be fixed before the profile is saved, or the profile is ambiguous.'
    }
}
