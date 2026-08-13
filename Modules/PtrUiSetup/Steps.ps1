<#
.SYNOPSIS
    The steps of "get my live UI onto the PTR", in the order they happen.

.DESCRIPTION
    A step is one item in the guide. Both kinds live behind the same shape so
    the window can render them in one list:

    auto    The tool can do it. Plan returns the file actions; Invoke performs
            them (or previews them with -PreviewOnly).
    manual  Only the player can do it — installing the PTR client, running a
            character copy. The step supplies instructions and a Status check
            that watches the filesystem, so it ticks itself off once it is done.

    Each step also carries a SourceNote saying why it exists, so the list can be
    checked against the written guide it mirrors (see docs/GUIDE.md).
#>

# Per-character files that carry UI state alongside SavedVariables.
# config-cache.wtf is the character's own settings — camera distance, floating
# combat text — and bindings/macros are the per-character halves of those.
# The guide writes the macro cache as "macros-cache.wtf"; the file WoW actually
# writes is macros-cache.txt. Both names are planned, and whichever exists gets
# copied, so the tool is right either way.
$script:CharacterLayoutFiles = @('AddOns.txt', 'layout-local.txt')
$script:CharacterSettingFiles = @('config-cache.wtf')
$script:CharacterExtraFiles = @('macros-cache.txt', 'macros-cache.wtf', 'bindings-cache.wtf')
$script:AccountExtraFiles = @('macros-cache.txt', 'macros-cache.wtf', 'bindings-cache.wtf', 'config-cache.wtf')

function New-PtrSetupContext {
    <#
    .SYNOPSIS
        Everything a step needs to know: what to copy, where, and how.
    #>
    [CmdletBinding()]
    param(
        [psobject] $Source,
        [psobject] $Target,
        [string] $SourceAccount,
        [string] $TargetAccount,
        [psobject[]] $Character = @(),
        [hashtable] $Options
    )

    $defaults = @{
        Overwrite             = $true
        IncludeMacrosBindings = $true
        IncludeChatCache      = $false
        AllowOutOfDate        = $true
        # The guide clears the PTR addon folder before pasting. Everything removed
        # is backed up, so this stays reversible.
        ReplaceAddOns         = $true
    }
    if ($Options) {
        foreach ($key in $Options.Keys) { $defaults[$key] = $Options[$key] }
    }

    [pscustomobject]@{
        PSTypeName    = 'PtrUiSetup.Context'
        Source        = $Source
        Target        = $Target
        SourceAccount = $SourceAccount
        TargetAccount = $TargetAccount
        # Each entry is @{ Source = <character>; Target = <character> } — realm
        # names differ between live and PTR, so the mapping is explicit.
        Character     = @($Character)
        Options       = $defaults
        Acknowledged  = [System.Collections.Generic.HashSet[string]]::new()
    }
}

function Test-ContextReady {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [psobject] $Context)
    return ($null -ne $Context.Source -and $null -ne $Context.Target)
}

function Get-ContextOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Context,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $true
    )

    if ($Context.Options -and $Context.Options.ContainsKey($Name)) { return [bool]$Context.Options[$Name] }
    return $Default
}

function Get-ContextCharacter {
    <#
    .SYNOPSIS
        The character pairs on a context, as a list that is never $null.

    .DESCRIPTION
        Everything here runs under Set-StrictMode, where .Count on $null is a
        terminating error rather than 0, and @($null).Count is 1 rather than 0 —
        so a context whose mapping has been cleared reads as one character unless
        the nulls are filtered out. Both traps are worth having in one place
        instead of at every use.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [psobject] $Context)

    if ($null -eq $Context.Character) { return @() }
    return @($Context.Character | Where-Object { $null -ne $_ })
}

function Get-ContextAccountPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Context,
        [Parameter(Mandatory)] [ValidateSet('Source', 'Target')] [string] $Side
    )

    $install = $Context.$Side
    $account = if ($Side -eq 'Source') { $Context.SourceAccount } else { $Context.TargetAccount }
    if (-not $install -or -not $account) { return $null }
    return Join-Path $install.AccountRoot $account
}

function New-PtrSetupStepStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('blocked', 'ready', 'done')] [string] $State,
        [string] $Detail = ''
    )
    [pscustomobject]@{ State = $State; Detail = $Detail }
}

function New-PtrSetupStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Summary,
        [Parameter(Mandatory)] [ValidateSet('auto', 'manual')] [string] $Mode,
        [string] $Instructions = '',
        [string] $SourceNote = '',
        [scriptblock] $Prerequisite,
        [scriptblock] $Plan,
        [scriptblock] $Status
    )

    [pscustomobject]@{
        PSTypeName   = 'PtrUiSetup.Step'
        Id           = $Id
        Title        = $Title
        Summary      = $Summary
        Mode         = $Mode
        Instructions = $Instructions
        SourceNote   = $SourceNote
        Prerequisite = $Prerequisite
        Plan         = $Plan
        Status       = $Status
    }
}

# --------------------------------------------------------------------------
# The step list
# --------------------------------------------------------------------------

$script:PtrSetupSteps = @(

    New-PtrSetupStep -Id 'install_ptr_client' -Mode 'manual' `
        -Title 'Install and launch the PTR client once' `
        -Summary 'The PTR builds its own WTF and Interface folders on first launch — nothing can be copied before that.' `
        -SourceNote 'Standard prerequisite: the folders this tool writes into do not exist until first launch.' `
        -Instructions @'
1. Open the Battle.net launcher.
2. In the game dropdown above the Play button, choose the PTR version of your client.
3. Install it if you have not already, then launch it once and sit at the character screen.
4. Quit the PTR client before continuing — WoW rewrites WTF on exit and would undo the copy.
'@ `
        -Status {
        param($Context)
        if (-not $Context.Target) { return New-PtrSetupStepStatus -State 'blocked' -Detail 'No PTR client selected yet.' }
        if (-not $Context.Target.HasBeenLaunched) {
            return New-PtrSetupStepStatus -State 'ready' -Detail "No WTF folder in $($Context.Target.DirName) yet — launch the PTR client once."
        }
        return New-PtrSetupStepStatus -State 'done' -Detail "$($Context.Target.DirName) has a WTF folder."
    }

    New-PtrSetupStep -Id 'copy_character' -Mode 'manual' `
        -Title 'Copy your character to the PTR' `
        -Summary 'Per-character settings can only land once the character exists on a PTR realm.' `
        -SourceNote 'Prerequisite for the per-character step; the copy itself happens on Blizzard''s side.' `
        -Instructions @'
1. Log into the PTR client and pick a PTR realm.
2. At the character-select screen use Copy Character (or the character-copy page on the PTR website, depending on the season) and copy your live character across.
3. Log in as the copied character once, then quit the client.
4. Come back here and press Rescan — the character will show up in the mapping list.
'@ `
        -Status {
        param($Context)
        if ($Context.Acknowledged.Contains('copy_character')) { return New-PtrSetupStepStatus -State 'done' -Detail 'Marked done.' }
        $mapped = @(Get-ContextCharacter -Context $Context).Count
        if ($mapped -gt 0) {
            return New-PtrSetupStepStatus -State 'done' -Detail "$mapped character(s) mapped."
        }
        return New-PtrSetupStepStatus -State 'ready' -Detail 'No PTR characters found yet.'
    }

    New-PtrSetupStep -Id 'quit_the_game' -Mode 'manual' `
        -Title 'Quit World of Warcraft before copying' `
        -Summary 'WoW rewrites its settings files when it exits, undoing anything copied while it is open.' `
        -SourceNote 'Guide: "Make sure the PTR client is closed, as some settings will not save if you have it open."' `
        -Instructions @'
1. Quit both the live client and the PTR client — not just the character screen, the whole game.
2. The Battle.net launcher can stay open.
3. This step ticks itself once no WoW process is running.
'@ `
        -Status {
        param($Context)
        $running = @(Get-RunningWowProcess)
        if ($running.Count -gt 0) {
            return New-PtrSetupStepStatus -State 'ready' -Detail ("Still running: " + (@($running.Name | Select-Object -Unique) -join ', ') + '. Quit the game, then press Rescan.')
        }
        return New-PtrSetupStepStatus -State 'done' -Detail 'No WoW client is running.'
    }

    New-PtrSetupStep -Id 'copy_addons' -Mode 'auto' `
        -Title 'Copy your addons' `
        -Summary 'Copies Interface\AddOns from the live client to the PTR client.' `
        -SourceNote 'The addon folder itself — without it, the copied settings have nothing to configure.' `
        -Instructions 'Addons are plain folders, so this is a straight copy. With "Replace the PTR addon folder" ticked (the guide''s "delete any addons there, then paste yours") anything on the PTR that is not in your live client is removed as well. Everything removed or overwritten is backed up first.' `
        -Prerequisite {
        param($Context)
        if (-not (Test-Path -LiteralPath $Context.Source.AddOns -PathType Container)) {
            return "No Interface\AddOns folder in $($Context.Source.DirName)."
        }
        return $null
    } `
        -Plan {
        param($Context)
        return New-TreeCopyPlan -Source $Context.Source.AddOns -Destination $Context.Target.AddOns `
            -Overwrite (Get-ContextOption -Context $Context -Name 'Overwrite') `
            -Prune:(Get-ContextOption -Context $Context -Name 'ReplaceAddOns')
    }

    New-PtrSetupStep -Id 'copy_config_wtf' -Mode 'auto' `
        -Title 'Carry over Config.wtf' `
        -Summary "Merges the live client's video, sound and interface settings into the PTR's Config.wtf." `
        -SourceNote 'Config.wtf holds the client-wide settings — resolution, window mode, and friends.' `
        -Instructions "This is a merge rather than a copy: realm and account keys stay on the PTR's own values so the PTR client keeps pointing at PTR realms. Everything else comes from your live client." `
        -Prerequisite {
        param($Context)
        if (-not (Test-Path -LiteralPath $Context.Source.ConfigWtf -PathType Leaf)) {
            return "No Config.wtf in $($Context.Source.DirName) — launch the live client once."
        }
        return $null
    } `
        -Plan {
        param($Context)
        $before = Read-ConfigWtf -Path $Context.Target.ConfigWtf
        $override = [ordered]@{}
        if (Get-ContextOption -Context $Context -Name 'AllowOutOfDate') { $override['checkAddonVersion'] = '0' }
        $after = Merge-ConfigWtf -Source (Read-ConfigWtf -Path $Context.Source.ConfigWtf) -Target $before -Override $override

        $changes = Compare-ConfigWtf -Before $before -After $after
        if (-not $changes) { return @() }

        $text = ConvertTo-ConfigWtf -Settings $after
        $kind = if (Test-Path -LiteralPath $Context.Target.ConfigWtf) { 'overwrite' } else { 'create' }
        $note = (@($changes | Select-Object -First 6 | ForEach-Object { '{0}={1}' -f $_.Key, $_.After }) -join ', ')
        $changeCount = @($changes).Count
        if ($changeCount -gt 6) { $note += ", +$($changeCount - 6) more" }

        return @(New-FileAction -Kind $kind -Destination $Context.Target.ConfigWtf `
                -Size ([System.Text.Encoding]::UTF8.GetByteCount($text)) -Note $note -Content $text)
    }

    New-PtrSetupStep -Id 'copy_account_saved_variables' -Mode 'auto' `
        -Title 'Copy account-wide addon settings' `
        -Summary 'Copies WTF\Account\<ACCOUNT>\SavedVariables — the profiles shared by all your characters.' `
        -SourceNote 'Account-level SavedVariables: where most addons keep their profiles.' `
        -Instructions 'Your live and PTR account folder names are usually identical, but if they differ pick the right pair above — copying into the wrong account folder silently does nothing in game. The guide skips this folder, which is why it then tells you to re-pick each addon profile in game; copying it means your account-wide profiles come across and you do not have to.' `
        -Prerequisite {
        param($Context)
        if (-not $Context.SourceAccount -or -not $Context.TargetAccount) {
            return 'Pick an account folder on both clients first.'
        }
        return $null
    } `
        -Plan {
        param($Context)
        $sourceDir = Get-ContextAccountPath -Context $Context -Side 'Source'
        $targetDir = Get-ContextAccountPath -Context $Context -Side 'Target'
        if (-not $sourceDir -or -not $targetDir) { return @() }

        $overwrite = Get-ContextOption -Context $Context -Name 'Overwrite'
        $actions = [System.Collections.Generic.List[psobject]]::new()
        foreach ($action in (New-TreeCopyPlan -Source (Join-Path $sourceDir 'SavedVariables') -Destination (Join-Path $targetDir 'SavedVariables') -Overwrite $overwrite)) {
            $actions.Add($action)
        }
        if (Get-ContextOption -Context $Context -Name 'IncludeMacrosBindings') {
            foreach ($name in $script:AccountExtraFiles) {
                foreach ($action in (New-SingleFileCopyPlan -Source (Join-Path $sourceDir $name) -Destination (Join-Path $targetDir $name) -Overwrite $overwrite)) {
                    $actions.Add($action)
                }
            }
        }
        return @($actions)
    }

    New-PtrSetupStep -Id 'copy_character_data' -Mode 'auto' `
        -Title 'Copy per-character settings' `
        -Summary "Copies each mapped character's SavedVariables, addon list and frame layout." `
        -SourceNote 'Character-level SavedVariables, plus the layout files that make the UI come up arranged.' `
        -Instructions 'Each row maps one live character onto one PTR character. Realm names differ between live and PTR (the PTR realm is usually something like "Classic PTR Realm 1"), so check the mapping before applying. Covers the character''s addon settings, addon list, frame layout, config-cache.wtf (camera distance, floating combat text), keybinds and macros.' `
        -Prerequisite {
        param($Context)
        if (@(Get-ContextCharacter -Context $Context).Count -eq 0) { return 'Map at least one character first.' }
        return $null
    } `
        -Plan {
        param($Context)
        $overwrite = Get-ContextOption -Context $Context -Name 'Overwrite'
        $names = @($script:CharacterLayoutFiles) + $script:CharacterSettingFiles
        if (Get-ContextOption -Context $Context -Name 'IncludeMacrosBindings') { $names += $script:CharacterExtraFiles }
        if (Get-ContextOption -Context $Context -Name 'IncludeChatCache' -Default $false) { $names += 'chat-cache.txt' }

        $actions = [System.Collections.Generic.List[psobject]]::new()
        foreach ($pair in (Get-ContextCharacter -Context $Context)) {
            $sourceDir = Get-WowCharacterPath -Install $Context.Source -Character $pair.Source
            $targetDir = Get-WowCharacterPath -Install $Context.Target -Character $pair.Target

            foreach ($action in (New-TreeCopyPlan -Source (Join-Path $sourceDir 'SavedVariables') -Destination (Join-Path $targetDir 'SavedVariables') -Overwrite $overwrite)) {
                $actions.Add($action)
            }
            foreach ($name in $names) {
                foreach ($action in (New-SingleFileCopyPlan -Source (Join-Path $sourceDir $name) -Destination (Join-Path $targetDir $name) -Overwrite $overwrite)) {
                    $actions.Add($action)
                }
            }
        }
        return @($actions)
    }

    New-PtrSetupStep -Id 'allow_out_of_date_addons' -Mode 'auto' `
        -Title 'Allow out-of-date addons' `
        -Summary 'Sets checkAddonVersion "0" so addons built for live still load on the PTR.' `
        -SourceNote 'The PTR runs a higher interface version, so every copied addon reads as out of date.' `
        -Instructions 'Equivalent to ticking "Load out of date AddOns" on the character-select addon list, but set directly in Config.wtf so it survives the copy.' `
        -Plan {
        param($Context)
        $current = Read-ConfigWtf -Path $Context.Target.ConfigWtf
        if ($current['checkAddonVersion'] -eq '0') { return @() }

        $merged = [ordered]@{}
        foreach ($key in $current.Keys) { $merged[$key] = $current[$key] }
        $merged['checkAddonVersion'] = '0'
        $text = ConvertTo-ConfigWtf -Settings $merged
        $kind = if (Test-Path -LiteralPath $Context.Target.ConfigWtf) { 'overwrite' } else { 'create' }

        return @(New-FileAction -Kind $kind -Destination $Context.Target.ConfigWtf `
                -Size ([System.Text.Encoding]::UTF8.GetByteCount($text)) -Note 'checkAddonVersion "0"' -Content $text)
    } `
        -Status {
        param($Context)
        if (-not (Test-ContextReady -Context $Context)) {
            return New-PtrSetupStepStatus -State 'blocked' -Detail 'Pick a live client and a PTR client first.'
        }
        if ((Read-ConfigWtf -Path $Context.Target.ConfigWtf)['checkAddonVersion'] -eq '0') {
            return New-PtrSetupStepStatus -State 'done' -Detail 'Already enabled on the PTR client.'
        }
        return New-PtrSetupStepStatus -State 'ready' -Detail 'Will set checkAddonVersion to 0.'
    }

    New-PtrSetupStep -Id 'verify_in_game' -Mode 'manual' `
        -Title 'Launch the PTR and check the UI' `
        -Summary 'Confirm the addons loaded and your layout came across.' `
        -SourceNote 'Closing check — the copy is only good if the client comes up with it.' `
        -Instructions @'
1. Launch the PTR client and log in on the copied character.
2. At character select, open AddOns and confirm your list is there and enabled.
3. In game, run /reload once — some addons only settle their profile on a reload.
4. If something is missing, use Restore below to undo, then re-apply with the affected step ticked on.
'@ `
        -Status {
        param($Context)
        if ($Context.Acknowledged.Contains('verify_in_game')) { return New-PtrSetupStepStatus -State 'done' -Detail 'Marked done.' }
        return New-PtrSetupStepStatus -State 'ready'
    }
)

function Get-PtrSetupStep {
    <#
    .SYNOPSIS
        The ordered step list, or the single step matching -Id.
    #>
    [CmdletBinding()]
    param([string] $Id)

    if ($PSBoundParameters.ContainsKey('Id')) {
        return $script:PtrSetupSteps | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    }
    return $script:PtrSetupSteps
}

function New-PtrSetupStepPlan {
    <#
    .SYNOPSIS
        The file actions a step would perform. Manual steps plan nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Step,
        [Parameter(Mandatory)] [psobject] $Context
    )

    if ($Step.Mode -ne 'auto' -or -not $Step.Plan) { return @() }
    if (-not (Test-ContextReady -Context $Context)) { return @() }
    if (Get-PtrSetupStepBlocker -Step $Step -Context $Context) { return @() }
    return @(& $Step.Plan $Context)
}

function Get-PtrSetupStepBlocker {
    <#
    .SYNOPSIS
        Why a step cannot run yet, or $null if it can.

    .DESCRIPTION
        Separates "there is nothing to copy from" (blocked) from "everything is
        already copied" (done) — an empty plan only means the second once the
        prerequisites are satisfied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Step,
        [Parameter(Mandatory)] [psobject] $Context
    )

    if (-not (Test-ContextReady -Context $Context)) { return 'Pick a live client and a PTR client first.' }
    if ($Step.Prerequisite) { return (& $Step.Prerequisite $Context) }
    return $null
}

function Get-PtrSetupStepStatus {
    <#
    .SYNOPSIS
        Where a step stands right now. Recomputed on every refresh.

    .PARAMETER Action
        A plan for this step that the caller has already built. Working it out
        means walking the whole AddOns tree, and the window needs the same plan
        to render the file list and total the summary — without this it would be
        built three times per refresh, which on a real install is the difference
        between a window that opens and one that appears to hang.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Step,
        [Parameter(Mandatory)] [psobject] $Context,
        [AllowEmptyCollection()] [psobject[]] $Action
    )

    if ($Step.Status) { return & $Step.Status $Context }

    if ($Step.Mode -eq 'manual') {
        $done = $Context.Acknowledged.Contains($Step.Id)
        return New-PtrSetupStepStatus -State $(if ($done) { 'done' } else { 'ready' })
    }

    $blocker = Get-PtrSetupStepBlocker -Step $Step -Context $Context
    if ($blocker) { return New-PtrSetupStepStatus -State 'blocked' -Detail $blocker }

    $actions = if ($PSBoundParameters.ContainsKey('Action')) {
        @($Action)
    }
    else {
        @(New-PtrSetupStepPlan -Step $Step -Context $Context)
    }
    if (-not $actions) { return New-PtrSetupStepStatus -State 'done' -Detail 'Already up to date — nothing left to copy.' }
    if (-not ($actions | Where-Object { $_.Kind -ne 'skip' })) {
        return New-PtrSetupStepStatus -State 'done' -Detail 'Every file is already on the PTR.'
    }
    return New-PtrSetupStepStatus -State 'ready' -Detail "$($actions.Count) file(s) to copy."
}

function Invoke-PtrSetupStep {
    <#
    .SYNOPSIS
        Run one step. Automated steps copy; manual steps just record the tick.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Step,
        [Parameter(Mandatory)] [psobject] $Context,
        [switch] $PreviewOnly,
        [scriptblock] $OnProgress
    )

    if ($Step.Mode -eq 'manual') {
        return [pscustomobject]@{
            StepId = $Step.Id; Ok = $true; PreviewOnly = [bool]$PreviewOnly
            Message = 'Manual step — nothing to automate.'; Actions = @(); BackupPath = $null
        }
    }

    if (-not (Test-ContextReady -Context $Context)) {
        return [pscustomobject]@{
            StepId = $Step.Id; Ok = $false; PreviewOnly = [bool]$PreviewOnly
            Message = 'No live client / PTR client selected.'; Actions = @(); BackupPath = $null
        }
    }

    $actions = @(New-PtrSetupStepPlan -Step $Step -Context $Context)
    if (-not $actions) {
        return [pscustomobject]@{
            StepId = $Step.Id; Ok = $true; PreviewOnly = [bool]$PreviewOnly
            Message = 'Nothing to do.'; Actions = @(); BackupPath = $null
        }
    }
    # A plan of nothing but skips means every file is already where it belongs.
    # Saying so beats "Copied 0 file(s)", which reads like something went wrong.
    if (-not ($actions | Where-Object { $_.Kind -ne 'skip' })) {
        return [pscustomobject]@{
            StepId = $Step.Id; Ok = $true; PreviewOnly = [bool]$PreviewOnly
            Message = 'Already up to date.'; Actions = $actions; BackupPath = $null
        }
    }

    try {
        $result = Invoke-FileActionPlan -Action $actions -InstallPath $Context.Target.Path -Label $Step.Id `
            -PreviewOnly:$PreviewOnly -OnProgress $OnProgress
    }
    catch {
        return [pscustomobject]@{
            StepId = $Step.Id; Ok = $false; PreviewOnly = [bool]$PreviewOnly
            Message = $_.Exception.Message; Actions = $actions; BackupPath = $null
        }
    }

    if ($PreviewOnly) {
        return [pscustomobject]@{
            StepId = $Step.Id; Ok = $true; PreviewOnly = $true
            Message = "Preview: $($actions.Count) file(s)."; Actions = $actions; BackupPath = $null
        }
    }

    $message = "Copied $(@($result.Performed).Count) file(s)."
    if ($result.BackupPath) { $message += " Overwritten files backed up to $(Split-Path -Path $result.BackupPath -Leaf)." }
    return [pscustomobject]@{
        StepId = $Step.Id; Ok = $true; PreviewOnly = $false
        Message = $message; Actions = $actions; BackupPath = $result.BackupPath
    }
}

function Invoke-PtrSetup {
    <#
    .SYNOPSIS
        Run several steps in canonical order, skipping unknown ids.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Context,
        [Parameter(Mandatory)] [string[]] $StepId,
        [switch] $PreviewOnly,
        [scriptblock] $OnProgress
    )

    $results = foreach ($step in (Get-PtrSetupStep)) {
        if ($StepId -notcontains $step.Id) { continue }
        Invoke-PtrSetupStep -Step $step -Context $Context -PreviewOnly:$PreviewOnly -OnProgress $OnProgress
    }
    return @($results)
}
