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

    # Overwrite and IncludeChatCache are not in here any more, so they are not
    # checkboxes. Both still work if a script sets them — Get-ContextOption
    # falls back to the sensible default when a key is absent — but neither
    # earned a place in the window: unticking Overwrite turned most of the tool
    # into a no-op and read as a fault, and nobody sets a PTR up for their chat
    # window.
    $defaults = @{
        IncludeMacrosBindings = $true
        # The guide clears the PTR addon folder before pasting. Everything removed
        # is backed up, so this stays reversible.
        ReplaceAddOns         = $true
        # Add the PTR character's key to each copied addon's profileKeys table so
        # the profile its live counterpart used is the one that loads.
        PointProfilesAtPtr    = $true
        # Give AceDB's region lookup a fallback in the PTR's copy of the library,
        # without which every Ace3 addon fails to initialise on a PTR realm. On
        # by default: the failure it prevents is a UI that comes up broken with
        # nothing but an in-game Lua traceback to explain it, and someone who
        # would know to tick this is someone who already knows to patch it.
        PatchPtrLibraries     = $true
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
        # Which install this step writes into. Everything writes to the PTR bar
        # one, and that one is opt-in for exactly that reason.
        [ValidateSet('Source', 'Target')] [string] $WritesTo = 'Target',
        # Left unticked when the window first draws the list, however ready it
        # is. For anything a user should choose rather than be handed.
        [switch] $OptIn,
        # Write without keeping a copy of what was replaced.
        [switch] $NoBackup,
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
        WritesTo     = $WritesTo
        OptIn        = [bool]$OptIn
        NoBackup     = [bool]$NoBackup
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
4. The character turns up in the mapping list on its own — the window watches the folders.
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
            return New-PtrSetupStepStatus -State 'ready' -Detail ("Still running: " + (@($running.Name | Select-Object -Unique) -join ', ') + '. Quit the game and this ticks itself off.')
        }
        return New-PtrSetupStepStatus -State 'done' -Detail 'No WoW client is running.'
    }

    New-PtrSetupStep -Id 'name_live_macros' -Mode 'auto' -WritesTo 'Source' -OptIn -NoBackup `
        -Title 'Break ties between macros on your LIVE client' `
        -Summary 'The only step that writes to your live client. Off unless you tick it.' `
        -SourceNote 'Not in the guide. An action bar saver records the name of the macro in each slot, and it does that on live.' `
        -Instructions 'An action bar saver writes down, for every slot, the name of the macro in it — and it does that on your live client. Thirty macros all called " " make that profile ambiguous the moment it is saved, and no amount of fixing on the PTR side can recover which slot wanted which macro. This gives the duplicates a suffix built from spaces, so they read exactly the same on your bars and are unique to anything looking them up. The first macro of each name keeps it untouched. Do this, then log in on live and save your action bar profile — in that order, or the profile is written from the old names. It runs once: afterwards the names are unique and it reports itself done, so it leaves no backup folder behind in your live client.' `
        -Prerequisite {
        param($Context)
        if (-not $Context.SourceAccount) { return 'Pick an account folder on the live client first.' }
        return $null
    } `
        -Plan {
        param($Context)
        # Every file in one call: they share a namespace in game, so a name used
        # in two of them has to be settled between them rather than in each.
        return @(New-MacroNameFixPlan -File (Get-LiveMacroCachePath -Context $Context))
    } `
        -Status {
        param($Context)
        if (-not $Context.Source -or -not $Context.SourceAccount) {
            return New-PtrSetupStepStatus -State 'blocked' -Detail 'Pick a live client and an account folder first.'
        }

        $conflicts = @(Get-LiveMacroNameConflict -File (Get-LiveMacroCachePath -Context $Context))
        $shared = $conflicts.Count
        $macros = (@($conflicts | ForEach-Object { $_.Count }) | Measure-Object -Sum).Sum
        if (-not $macros) { $macros = 0 }

        if ($shared -eq 0) {
            return New-PtrSetupStepStatus -State 'done' -Detail 'Every macro on the live client already has a name of its own.'
        }
        return New-PtrSetupStepStatus -State 'ready' `
            -Detail "$macros macro(s) share $shared name(s) on the live client — an action bar saver cannot tell them apart. Tick this to fix it."
    }

    New-PtrSetupStep -Id 'save_action_bars' -Mode 'manual' `
        -Title 'Save your action bars on the live client' `
        -Summary 'Nothing outside the game can read your bars, so an addon has to record them before anything is copied.' `
        -SourceNote 'Not in the guide. What is in each action slot is server-side, and the character copy does not reliably bring it.' `
        -Instructions @'
What sits in each action slot is held on Blizzard's servers, not in any file, so this tool cannot copy it and the character copy does not reliably bring it either. An addon can, and its saved data is then just another file that gets copied over with everything else.

1. On the LIVE client, install ActionBarSaver: Reloaded.
2. Deal with the macro step above first if it is offering to do anything. A profile saved while macros share a name is ambiguous the moment it is written, and nothing done afterwards recovers it.
3. Log in on the character whose bars you want, and run:  /abs save live
4. Quit the game. WoW only writes an addon's saved data when it exits.

Doing this now means the profile is already on the PTR when you get there, rather than finding out later and running everything a second time.
'@ `
        -Status {
        param($Context)
        if ($Context.Acknowledged.Contains('save_action_bars')) { return New-PtrSetupStepStatus -State 'done' -Detail 'Marked done.' }
        if (-not $Context.Source) { return New-PtrSetupStepStatus -State 'blocked' -Detail 'Pick a live client first.' }

        $addon = @(Get-ActionBarAddOn -Install $Context.Source)
        if ($addon.Count -eq 0) {
            return New-PtrSetupStepStatus -State 'ready' -Detail 'No action bar saver installed on the live client — install one, save a profile, then tick this off.'
        }
        return New-PtrSetupStepStatus -State 'ready' -Detail ("$($addon -join ', ') is installed on the live client. Save a profile with it, then tick this off.")
    }

    New-PtrSetupStep -Id 'copy_addons' -Mode 'auto' `
        -Title 'Copy your addons' `
        -Summary 'Copies Interface\AddOns from the live client to the PTR client.' `
        -SourceNote 'The addon folder itself — without it, the copied settings have nothing to configure.' `
        -Instructions 'Addons are plain folders, so this is a straight copy. With "Replace the PTR addon folder" ticked (the guide''s "delete any addons there, then paste yours") anything on the PTR that is not in your live client is removed as well. Everything removed or overwritten is backed up first. An addon carrying an old copy of the Ace3 libraries cannot start on a PTR realm at all; where that is found, the PTR''s copy of the library gets the one-line fix on the way over and your live client is left untouched.' `
        -Prerequisite {
        param($Context)
        if (-not (Test-Path -LiteralPath $Context.Source.AddOns -PathType Container)) {
            return "No Interface\AddOns folder in $($Context.Source.DirName)."
        }
        return $null
    } `
        -Plan {
        param($Context)
        $overwrite = Get-ContextOption -Context $Context -Name 'Overwrite'
        $copies = @(New-TreeCopyPlan -Source $Context.Source.AddOns -Destination $Context.Target.AddOns `
                -Overwrite $overwrite `
                -Prune:(Get-ContextOption -Context $Context -Name 'ReplaceAddOns'))

        # The patched library stands in for the plain copy of the same file, so
        # it is written once and a second Apply still reports itself done.
        if (Get-ContextOption -Context $Context -Name 'PatchPtrLibraries') {
            $patched = @(New-AceDbPatchPlan -Action $copies -Overwrite $overwrite)
            $copies = @(Merge-FileActionPlan -Action $copies -Override $patched)
        }
        return @($copies)
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
        # No override for checkAddonVersion here. Its own step sets it, and two
        # steps writing the same key meant the second always found the first had
        # already done it — so the step that exists to do the job reported
        # "nothing to do" and the option that appeared to control it did not.
        $before = Read-ConfigWtf -Path $Context.Target.ConfigWtf
        $after = Merge-ConfigWtf -Source (Read-ConfigWtf -Path $Context.Source.ConfigWtf) -Target $before -Override ([ordered]@{})

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
        -Instructions 'Your live and PTR account folder names are usually identical, but if they differ pick the right pair above — copying into the wrong account folder silently does nothing in game. The guide skips this folder, which is why it then tells you to re-pick each addon profile in game; copying it means your account-wide profiles come across, and with "Point addon profiles at your PTR character" ticked the right one is already selected when you log in.' `
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
        $sourceSaved = Join-Path $sourceDir 'SavedVariables'
        $targetSaved = Join-Path $targetDir 'SavedVariables'

        $copies = @(New-TreeCopyPlan -Source $sourceSaved -Destination $targetSaved -Overwrite $overwrite)
        # The profile rewrite replaces the plain copy of the same file rather
        # than following it, so nothing is written twice and the preview shows
        # each file once.
        if (Get-ContextOption -Context $Context -Name 'PointProfilesAtPtr') {
            # Held in a variable first: an empty array returned from a function and
            # read straight into a parameter arrives as $null, because writing @()
            # to the pipeline writes nothing at all.
            $mapping = @(Get-PtrSetupProfileMapping -Context $Context)
            $rewritten = @(New-ProfileKeyPlan -Source $sourceSaved -Destination $targetSaved `
                    -Mapping $mapping -Overwrite $overwrite)
            $copies = @(Merge-FileActionPlan -Action $copies -Override $rewritten)
        }

        $actions = [System.Collections.Generic.List[psobject]]::new()
        foreach ($action in $copies) { $actions.Add($action) }
        if (Get-ContextOption -Context $Context -Name 'IncludeMacrosBindings') {
            $extras = [System.Collections.Generic.List[psobject]]::new()
            foreach ($name in $script:AccountExtraFiles) {
                foreach ($action in (New-SingleFileCopyPlan -Source (Join-Path $sourceDir $name) -Destination (Join-Path $targetDir $name) -Overwrite $overwrite)) {
                    $extras.Add($action)
                }
            }
            foreach ($action in $extras) { $actions.Add($action) }
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

        $pointProfiles = Get-ContextOption -Context $Context -Name 'PointProfilesAtPtr'
        $actions = [System.Collections.Generic.List[psobject]]::new()
        foreach ($pair in (Get-ContextCharacter -Context $Context)) {
            $sourceDir = Get-WowCharacterPath -Install $Context.Source -Character $pair.Source
            $targetDir = Get-WowCharacterPath -Install $Context.Target -Character $pair.Target
            $sourceSaved = Join-Path $sourceDir 'SavedVariables'
            $targetSaved = Join-Path $targetDir 'SavedVariables'

            $copies = @(New-TreeCopyPlan -Source $sourceSaved -Destination $targetSaved -Overwrite $overwrite)
            # Most addons keep profileKeys in the account-level file, but a few
            # keep a per-character database as well, and it is keyed the same way.
            if ($pointProfiles) {
                $mapping = @([pscustomobject]@{
                        From = '{0} - {1}' -f $pair.Source.Name, $pair.Source.Realm
                        To   = '{0} - {1}' -f $pair.Target.Name, $pair.Target.Realm
                    })
                $rewritten = @(New-ProfileKeyPlan -Source $sourceSaved -Destination $targetSaved -Mapping $mapping -Overwrite $overwrite)
                $copies = @(Merge-FileActionPlan -Action $copies -Override $rewritten)
            }
            foreach ($action in $copies) {
                $actions.Add($action)
            }
            $extras = [System.Collections.Generic.List[psobject]]::new()
            foreach ($name in $names) {
                foreach ($action in (New-SingleFileCopyPlan -Source (Join-Path $sourceDir $name) -Destination (Join-Path $targetDir $name) -Overwrite $overwrite)) {
                    $extras.Add($action)
                }
            }
            foreach ($action in $extras) { $actions.Add($action) }
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
2. At character select, open AddOns and confirm your list is there and enabled. One that is listed but unticked just needs enabling; one that is missing entirely was installed after the last copy, so run this again.
3. Put your action bars back:  /abs restore live  — whatever you called the profile when you saved it. /abs list shows what came across.
4. Errors naming an item id are normal: the addon can only place an item you are actually carrying, so anything still in your live bags cannot be restored. Errors naming a macro mean the names are still ambiguous — see the macro step near the top.
5. If something is missing, use Restore below to undo, then re-apply with the affected step ticked on.
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

    # Assigned in each branch rather than from the if itself. A statement used as
    # an expression has its output unrolled: a one-item plan comes back as the
    # bare item and an empty one as $null, and .Count on either is a terminating
    # error under Set-StrictMode. Every step with exactly one file to copy failed
    # that way, which was most of them.
    if ($PSBoundParameters.ContainsKey('Action')) {
        $actions = @($Action)
    }
    else {
        $actions = @(New-PtrSetupStepPlan -Step $Step -Context $Context)
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
        # Fenced to whichever install the step declares, not always the PTR —
        # the fence itself is what stops a mis-planned action escaping, so it
        # has to name the folder actually being written to.
        $result = Invoke-FileActionPlan -Action $actions -InstallPath $Context.($Step.WritesTo).Path -Label $Step.Id `
            -PreviewOnly:$PreviewOnly -SkipBackup:$Step.NoBackup -OnProgress $OnProgress
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
