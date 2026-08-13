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
        Assert-Equal '0' $written['checkAddonVersion']
    }

    It 'reports done, not blocked, once it has run' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $step = Get-PtrSetupStep -Id 'copy_config_wtf'
        $null = Invoke-PtrSetupStep -Step $step -Context $context

        $status = Get-PtrSetupStepStatus -Step $step -Context $context
        Assert-Equal 'done' $status.State
        Assert-True ($status.Detail -match 'up to date')
    }

    It 'leaves checkAddonVersion alone when the option is off' {
        $context = New-FakeContext -Root (New-FakeWowRoot -Parent $script:TestDrive)
        $context.Options['AllowOutOfDate'] = $false
        $null = Invoke-PtrSetupStep -Step (Get-PtrSetupStep -Id 'copy_config_wtf') -Context $context

        $written = Read-ConfigWtf -Path $context.Target.ConfigWtf
        Assert-False $written.Contains('checkAddonVersion')
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

    It 'includes the chat cache only when asked' {
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
