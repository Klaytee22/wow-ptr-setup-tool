<#
.SYNOPSIS
    The window. Copies your live WoW UI, addons and settings onto the PTR client.

.DESCRIPTION
    A WPF front end over the PtrUiSetup module. All the work happens in the
    module — this file only renders state and calls into it, so the tool is
    equally usable from a console if you would rather script it.

    Windows only, because WPF is. The module itself is cross-platform.

.PARAMETER Path
    Folders to look in, instead of the one the window would have started with.
    Not needed in normal use — the window has a folder box, a Browse button and
    a Detect button, and remembers what you pick. This is for scripting and for
    pointing the window at a test tree.

.PARAMETER ListSteps
    Print the step list and exit, without opening a window.

.EXAMPLE
    .\PtrUiSetup.ps1

.EXAMPLE
    .\PtrUiSetup.ps1 -Path 'D:\Games\World of Warcraft'
#>

[CmdletBinding()]
param(
    [string[]] $Path,
    [switch] $ListSteps
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/PtrUiSetup/PtrUiSetup.psd1') -Force

if ($ListSteps) {
    Get-PtrSetupStep | Format-Table -AutoSize Id, Mode, Title
    return
}

if (-not (Test-WindowsHost)) {
    throw 'The window needs Windows. The module still works: Import-Module ./Modules/PtrUiSetup, then Initialize-PtrSetupContext and Invoke-PtrSetup.'
}

# WPF has to be built on a single-threaded-apartment thread. Start-PtrUiSetup.cmd
# passes -STA, and both consoles default to it, but a session started with -MTA
# would otherwise fail several lines later with a much less helpful message.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw @'
This PowerShell session is multi-threaded (MTA), and WPF needs a single-threaded one.

Double-click Start-PtrUiSetup.cmd, or from a prompt:
    powershell.exe -STA -File .\PtrUiSetup.ps1
'@
}

# Nothing can be shown on screen until WPF itself is loaded, and loading it is
# the slowest part of starting up. The console the launcher opened is the only
# surface there is until then, so it says what is happening — a few seconds of
# silence after a double-click reads as a machine that has ignored you.
function Write-Startup {
    param([string] $Message)
    Write-Host "  $Message" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  WoW PTR UI Setup' -ForegroundColor Yellow
Write-Startup 'loading Windows components...'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# --------------------------------------------------------------------------
# Window
# --------------------------------------------------------------------------

Write-Startup 'building the window...'
$xamlPath = Join-Path $PSScriptRoot 'ui/MainWindow.xaml'
# Read as UTF-8 explicitly. Get-Content on Windows PowerShell 5.1 falls back to
# the machine's ANSI code page for a file it cannot prove is Unicode, which turns
# every em dash in the layout into three characters of mojibake.
[xml] $xaml = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

# Every x:Name in the XAML becomes $ui.<Name>.
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $attribute = $node.Attributes['x:Name']
    if (-not $attribute) { continue }
    $ui[$attribute.Value] = $window.FindName($attribute.Value)
}

$script:Context = $null
$script:Installs = @()
# The folder box is the single source of truth for where to look. -Path adds
# extra folders on top, for scripting and for the mock install.
$script:WowFolder = ''
$script:ExtraPaths = [System.Collections.Generic.List[string]]::new()
foreach ($extra in $Path) { if ($extra) { $script:ExtraPaths.Add($extra) } }
$script:Selected = [System.Collections.Generic.HashSet[string]]::new()
# Plans for the current refresh, keyed by step id. Building one walks the whole
# AddOns tree, and the status, the file list and the summary all want the same
# answer, so it is worked out once per refresh and read three times.
$script:Plans = @{}
# The cards currently on screen, so an answer arriving later knows where to go.
$script:Cards = @{}
$script:ModulePath = Join-Path $PSScriptRoot 'Modules/PtrUiSetup/PtrUiSetup.psd1'
$script:Worker = $null
$script:PlanJob = $null
$script:PlanTimer = $null
$script:PlanToken = 0
$script:PlanQueue = $null
$script:PlanTotal = 0
$script:PlanDone = 0
$script:RunIndex = 0
$script:RunTotal = 0
$script:RunJob = $null
$script:RunTimer = $null
$script:AsyncBroken = $false
# Watching the folders, so pressing Rescan is a fallback rather than the way to
# use the tool.
$script:WatchTimer = $null
$script:Fingerprint = $null
$script:MappingTouched = $false
$script:Running = $false
# Workers told to stop, kept until they have and can be disposed.
$script:Abandoned = [System.Collections.Generic.List[psobject]]::new()

# Which steps have to be re-planned when something changes. Picking a character
# cannot alter what the addon copy would do, and re-walking a 30,000-file AddOns
# folder to find that out is the difference between a dropdown that responds and
# one that appears to hang. Anything not listed here clears the lot.
$script:Invalidates = @{
    account               = @('copy_account_saved_variables', 'copy_character_data')
    character             = @('copy_character_data')
    ReplaceAddOns         = @('copy_addons')
    IncludeMacrosBindings = @('copy_account_saved_variables', 'copy_character_data')
    IncludeChatCache      = @('copy_character_data')
    AllowOutOfDate        = @('copy_config_wtf', 'allow_out_of_date_addons')
}
$script:SelectedTouched = $false
# Repopulating a ComboBox raises SelectionChanged; this stops that feeding back.
$script:Suppress = $false

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

function Update-UiNow {
    <#
    .SYNOPSIS
        Let the window repaint mid-copy (WPF's equivalent of DoEvents).
    #>
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null },
        $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Write-Result {
    param([string] $Line)
    $ui.ResultsBox.AppendText($Line + [Environment]::NewLine)
    $ui.ResultsBox.ScrollToEnd()
}

function New-Pill {
    <#
    .SYNOPSIS
        The small coloured status chip next to a step title.
    #>
    param([string] $Text, [string] $Kind)

    $colour = switch ($Kind) {
        'done' { '#6FCF87' }
        'ready' { '#E3B341' }
        'blocked' { '#F07B7B' }
        'manual' { '#7AA7F0' }
        default { '#98A0B3' }
    }
    $border = New-Object System.Windows.Controls.Border
    $border.BorderThickness = New-Object System.Windows.Thickness 1
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($colour)
    $border.CornerRadius = New-Object System.Windows.CornerRadius 8
    $border.Padding = New-Object System.Windows.Thickness 6, 1, 6, 1
    $border.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
    $border.VerticalAlignment = 'Center'

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text.ToUpperInvariant()
    $label.FontSize = 10
    $label.Foreground = $border.BorderBrush
    $border.Child = $label
    return $border
}

function New-TextBlockControl {
    param([string] $Text, [string] $Colour = '#E7E9EF', [double] $Size = 13, [string] $Weight = 'Normal', $Margin = $null)

    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontSize = $Size
    $block.TextWrapping = 'Wrap'
    $block.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Colour)
    $block.FontWeight = $Weight
    if ($Margin) { $block.Margin = $Margin }
    return $block
}

function Get-Brush {
    param([string] $Colour)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Colour)
}

function New-SkipChoice {
    <#
    .SYNOPSIS
        The "leave this character alone" entry in a character mapping row.
    #>
    return [pscustomobject]@{
        PSTypeName = 'PtrUiSetup.SkipChoice'
        Display    = '— skip this character —'
    }
}

function Test-SkipChoice {
    <#
    .SYNOPSIS
        True when a mapping row's selection is not a character to copy from.
    #>
    param($Item)

    if ($null -eq $Item) { return $true }
    if ($Item -is [string]) { return $true }
    if (@($Item.PSObject.TypeNames) -contains 'PtrUiSetup.SkipChoice') { return $true }
    # Decided on shape as well as type name: what comes back out of a WPF
    # ComboBox is not guaranteed to still be wrapped in the PSObject that
    # carries the type name, and mapping the sentinel as if it were a character
    # would fail later, further from the cause.
    return (-not (@($Item.PSObject.Properties.Name) -contains 'Account'))
}

function Invoke-Guarded {
    <#
    .SYNOPSIS
        Run a click handler without letting a failure take the window down.

    .DESCRIPTION
        An exception escaping a WPF event handler reaches the dispatcher
        unhandled and closes the app, losing whatever the user had selected. The
        Results box is a better place for it.
    #>
    param([Parameter(Mandatory)] [scriptblock] $Body)

    try { & $Body }
    catch {
        # With the location and the offending line, not just the message. Most of
        # this file cannot be reached by the test suite, so when something does go
        # wrong here the Results box is the only evidence anyone gets, and
        # "the property 'Count' cannot be found" on its own names no suspect.
        $where = $_.InvocationInfo
        $at = if ($where -and $where.ScriptLineNumber) { " (line $($where.ScriptLineNumber))" } else { '' }
        Write-Result "[fail]$at $($_.Exception.Message)"
        if ($where -and $where.Line) {
            $statement = $where.Line.Trim()
            if ($statement) { Write-Result "       $statement" }
        }
    }
}

function Reset-Plan {
    <#
    .SYNOPSIS
        Throw away the plans that -Change could have altered, keeping the rest.

    .PARAMETER Change
        What the user just changed: an option name, 'account', 'character', or
        anything unrecognised, which clears everything as the safe default.
    #>
    param([string] $Change)

    if ($Change -and $script:Invalidates.ContainsKey($Change)) {
        foreach ($stepId in $script:Invalidates[$Change]) { $script:Plans.Remove($stepId) }
        return
    }
    $script:Plans = @{}
}

function Start-Watching {
    <#
    .SYNOPSIS
        Notice on our own when the folders change, instead of waiting to be told.

    .DESCRIPTION
        Launching the PTR, copying a character, installing an addon and quitting
        the game all change something the window is showing, and every one of
        them used to need a press of Rescan. Get-WowFolderFingerprint is about
        twenty directory timestamps and one process lookup — five milliseconds,
        a few times a minute — so this can simply run.

        A filesystem watcher would be the other way to do it, but its events
        arrive on a thread that must not touch WPF, and WoW rewriting its whole
        WTF tree on exit would deliver them by the hundred. A timer that looks
        costs less and cannot surprise anyone.
    #>
    if ($script:WatchTimer) { return }

    $script:WatchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:WatchTimer.Interval = [TimeSpan]::FromSeconds(4)
    $script:WatchTimer.Add_Tick({ Invoke-Guarded { Update-OnChange } })
    $script:WatchTimer.Start()
    $ui.WatchStatus.Text = 'Watching for changes'
}

function Update-OnChange {
    <#
    .SYNOPSIS
        Refresh if, and only if, something on disk actually moved.
    #>
    if (-not $script:Context) { return }
    # Not while a run is under way, and not on top of planning already going.
    if ($script:Running -or $script:PlanJob -or ($script:PlanQueue -and $script:PlanQueue.Count)) { return }

    $now = Get-WowFolderFingerprint -Context $script:Context
    if ($now -eq $script:Fingerprint) { return }
    $script:Fingerprint = $now

    # Deliberately narrower than Rescan: the installs and the folder box stay as
    # they are, so a refresh cannot move the selection under someone mid-decision.
    $before = @(Get-CharacterId)
    Reset-Plan
    Update-CharacterPanelIfChanged -Before $before
    Update-Steps
    Update-Summary
    Update-Backups
    Write-Result '[auto] Something changed on disk — refreshed.'
}

function Get-CharacterId {
    <#
    .SYNOPSIS
        The characters currently on both clients, as ids, for spotting new ones.
    #>
    $ids = foreach ($side in @('Source', 'Target')) {
        $install = $script:Context.$side
        $account = if ($side -eq 'Source') { $script:Context.SourceAccount } else { $script:Context.TargetAccount }
        if (-not $install -or -not $account) { continue }
        foreach ($character in (Get-WowCharacter -Install $install -Account $account)) { "$side/$($character.Id)" }
    }
    return @($ids)
}

function Update-CharacterPanelIfChanged {
    <#
    .SYNOPSIS
        Rebuild the mapping rows only when the characters themselves changed.
    #>
    param([AllowEmptyCollection()] [string[]] $Before)

    $after = @(Get-CharacterId)
    if ((@($Before) -join '|') -eq ($after -join '|')) { return }

    # A character copied to the PTR should appear mapped, unless the user has
    # already arranged the mapping themselves — then it appears unmapped and they
    # decide, rather than having their choices redone for them.
    if (-not $script:MappingTouched) {
        $script:Context = Set-PtrSetupCharacterGuess -Context $script:Context -Force
    }
    Update-CharacterPanel
}

# --------------------------------------------------------------------------
# The game folder
# --------------------------------------------------------------------------

function Get-StartingFolder {
    <#
    .SYNOPSIS
        What the folder box opens with: the last folder used, else whatever is
        installed, else the conventional location for someone to correct.
    #>
    $saved = (Get-PtrSetupSetting).WowFolder
    if ($saved -and (Test-Path -LiteralPath $saved -PathType Container)) { return $saved }

    $detected = Find-WowFolder
    if ($detected) { return $detected }

    return (Get-WowDefaultRoot)
}

function Update-FolderStatus {
    <#
    .SYNOPSIS
        One line under the folder box saying what is in the folder.
    #>
    $folder = $script:WowFolder
    if (-not $folder) {
        $ui.FolderStatus.Text = 'Pick the folder World of Warcraft is installed in.'
        return
    }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        $ui.FolderStatus.Text = 'That folder does not exist — check the path, or press Detect.'
        return
    }
    if (-not $script:Installs) {
        $ui.FolderStatus.Text = 'No game clients in there. Pick the folder holding _retail_ or _classic_.'
        return
    }

    $names = @($script:Installs | ForEach-Object { $_.Label }) -join ', '
    $ui.FolderStatus.Text = "$(@($script:Installs).Count) client(s) found: $names"
}

function Set-WowFolder {
    <#
    .SYNOPSIS
        Point the tool at a folder, rescan, and remember it if it worked out.
    #>
    param([string] $Folder)

    $script:WowFolder = $Folder.Trim('"', ' ')
    if ($ui.FolderBox.Text -ne $script:WowFolder) { $ui.FolderBox.Text = $script:WowFolder }
    Invoke-Rescan
    # Only worth remembering a folder that turned out to have the game in it.
    if ($script:Installs) { $null = Save-PtrSetupSetting -WowFolder $script:WowFolder }
}

# --------------------------------------------------------------------------
# Planning off the UI thread
# --------------------------------------------------------------------------
#
# Working out a step's plan walks the whole AddOns folder, which on a real
# install is seconds. Done on the UI thread that is seconds of a frozen window,
# so it happens on a background runspace instead and the answers are collected
# by a timer ticking on the UI thread. Nothing touches WPF except that timer and
# the ordinary event handlers, and the worker never sees a live context — only a
# snapshot of plain values it rebuilds for itself.

function Get-PlanWorker {
    <#
    .SYNOPSIS
        The background runspace, opened and loaded on first use.

    .DESCRIPTION
        Returns $null if a runspace cannot be had, which puts the window back on
        the synchronous path rather than leaving it unable to plan at all.
    #>
    if ($script:AsyncBroken) { return $null }
    if ($script:Worker -and $script:Worker.RunspaceStateInfo.State -eq 'Opened') { return $script:Worker }

    try {
        $runspace = [runspacefactory]::CreateRunspace()
        # Left in the default apartment on purpose: the worker only reads files,
        # and asking for STA is one more thing that can fail for no benefit.
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()

        # Import once, here, rather than on every request.
        $loader = [powershell]::Create()
        $loader.Runspace = $runspace
        $null = $loader.AddScript('param($ModulePath) Import-Module $ModulePath -Force').AddArgument($script:ModulePath)
        $null = $loader.Invoke()
        $failed = @($loader.Streams.Error)
        $loader.Dispose()
        if ($failed.Count) { throw "the worker could not load the module: $($failed[0])" }

        $script:Worker = $runspace
        return $script:Worker
    }
    catch {
        $script:AsyncBroken = $true
        Write-Result "[note] Planning in the background is unavailable ($($_.Exception.Message)); the window will do it directly and may pause."
        return $null
    }
}

function Stop-PlanRequest {
    <#
    .SYNOPSIS
        Abandon whatever is in flight, so a new selection is not queued behind it.

    .DESCRIPTION
        BeginStop rather than Stop: Stop waits for the pipeline to notice, and a
        worker part way through a large folder can take a moment. Waiting for it
        on the UI thread would put back exactly the pause this is here to avoid.
        The stopped shell is disposed later, once it has actually finished.
    #>
    if ($script:PlanTimer) { $script:PlanTimer.Stop() }
    if (-not $script:PlanJob) { return }

    $shell = $script:PlanJob.Shell
    $script:PlanJob = $null
    try {
        $null = $shell.BeginStop($null, $null)
        $script:Abandoned.Add($shell)
    }
    catch {
        try { $shell.Dispose() } catch { <# nothing to dispose #> }
    }
}

function Clear-AbandonedRequest {
    <#
    .SYNOPSIS
        Dispose stopped workers once they have come to rest.
    #>
    if (-not $script:Abandoned.Count) { return }

    $stillGoing = [System.Collections.Generic.List[psobject]]::new()
    foreach ($shell in $script:Abandoned) {
        $state = try { $shell.InvocationStateInfo.State } catch { 'Completed' }
        if ($state -in @('Running', 'Stopping')) {
            $stillGoing.Add($shell)
            continue
        }
        try { $shell.Dispose() } catch { <# already gone #> }
    }
    $script:Abandoned = $stillGoing
}

function Start-PlanRequest {
    <#
    .SYNOPSIS
        Plan -StepId in the background, one step at a time, and return at once.

    .DESCRIPTION
        A step per request rather than all of them in one: each answer fills its
        own card as it arrives, so the list populates in front of the user
        instead of sitting on "checking" until the slowest one is done. The extra
        round trips cost nothing next to walking a folder.
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $StepId)

    Stop-PlanRequest
    $script:PlanQueue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($id in @($StepId)) { $script:PlanQueue.Enqueue($id) }
    $script:PlanTotal = $script:PlanQueue.Count
    $script:PlanDone = 0
    Start-NextPlan
}

function Start-NextPlan {
    <#
    .SYNOPSIS
        Send the next step to the worker, or finish if there are none left.
    #>
    if (-not $script:PlanQueue -or -not $script:PlanQueue.Count) {
        Complete-Planning
        return
    }

    $stepId = $script:PlanQueue.Dequeue()
    $runspace = Get-PlanWorker
    if (-not $runspace) {
        # No worker to be had: plan here, exactly as the window used to, and keep
        # going down the queue.
        $script:Plans[$stepId] = @(New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id $stepId) -Context $script:Context)
        Write-StepCardState -StepId $stepId
        $script:PlanDone++
        Update-PlanProgress
        Start-NextPlan
        return
    }

    $script:PlanToken++
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $null = $shell.AddScript({
            param($Snapshot, $StepId)
            $context = ConvertFrom-PtrSetupSnapshot -Snapshot $Snapshot
            # Written out one action at a time rather than as a wrapped array:
            # the caller reads the whole output collection, so an empty plan is
            # simply no output instead of something that has to be indexed into.
            return @(New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id $StepId) -Context $context)
        })
    $null = $shell.AddArgument((ConvertTo-PtrSetupSnapshot -Context $script:Context))
    $null = $shell.AddArgument($stepId)

    $script:PlanJob = [pscustomobject]@{
        Shell  = $shell
        Handle = $shell.BeginInvoke()
        Token  = $script:PlanToken
        StepId = $stepId
    }

    if (-not $script:PlanTimer) {
        $script:PlanTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:PlanTimer.Interval = [TimeSpan]::FromMilliseconds(60)
        # Ticks on the UI thread, so this is the one place a worker's answer
        # meets WPF.
        $script:PlanTimer.Add_Tick({ Invoke-Guarded { Receive-PlanRequest } })
    }
    $script:PlanTimer.Start()
}

function Update-PlanProgress {
    if ($script:PlanTotal -gt 0) {
        $ui.ProgressBar.Value = (100 * $script:PlanDone / $script:PlanTotal)
    }
}

function Receive-PlanRequest {
    <#
    .SYNOPSIS
        Collect a finished step and move on to the next.

    .DESCRIPTION
        Whatever happens to one step, the queue moves on. A step that cannot be
        worked out is recorded as an empty plan and reported, because leaving it
        pending is far worse than getting it wrong: the summary waits on it, Apply
        stays disabled, and the window sits on "working out what needs copying"
        with no way forward.
    #>
    Clear-AbandonedRequest
    $job = $script:PlanJob
    if (-not $job) {
        $script:PlanTimer.Stop()
        return
    }
    if (-not $job.Handle.IsCompleted) { return }

    $script:PlanTimer.Stop()
    $stale = $false
    try {
        $plan = $null
        $failure = $null
        try {
            $result = $job.Shell.EndInvoke($job.Handle)
            $errors = @($job.Shell.Streams.Error)
            if ($errors.Count) { $failure = [string]$errors[0] } else { $plan = @($result) }
        }
        catch {
            $failure = $_.Exception.Message
        }
        finally {
            try { $job.Shell.Dispose() } catch { <# nothing to dispose #> }
            if ($script:PlanJob -and $script:PlanJob.Token -eq $job.Token) { $script:PlanJob = $null }
        }

        # A newer request has been sent since; this answer describes a selection
        # the user has already moved on from, and the newer one drives the queue.
        if ($job.Token -ne $script:PlanToken) {
            $stale = $true
            return
        }

        if ($failure) {
            Write-Result "[fail] Could not work out $($job.StepId): $failure"
        }
        else {
            $script:Plans[$job.StepId] = $plan
        }
        Write-StepCardState -StepId $job.StepId
    }
    finally {
        if (-not $stale) {
            # Recorded either way, so nothing is left pending forever.
            if (-not $script:Plans.ContainsKey($job.StepId)) { $script:Plans[$job.StepId] = @() }
            $script:PlanDone++
            Update-PlanProgress
            # Keep the running total honest as each step lands.
            Update-Summary
            Start-NextPlan
        }
    }
}

function Complete-Planning {
    <#
    .SYNOPSIS
        Everything asked for has arrived: total it up and let the user press Apply.
    #>
    $ui.ProgressBar.Value = 0
    # Pre-ticking only applies to the very first list the user is shown; from
    # here on their ticks are theirs.
    $script:SelectedTouched = $true
    Update-Summary
}

# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

function Update-InstallCombos {
    $script:Suppress = $true
    try {
        $ui.SourceInstallCombo.Items.Clear()
        $ui.TargetInstallCombo.Items.Clear()

        foreach ($install in ($script:Installs | Where-Object { -not $_.IsPtr })) {
            $null = $ui.SourceInstallCombo.Items.Add($install)
            if ($script:Context.Source -and $install.Id -eq $script:Context.Source.Id) {
                $ui.SourceInstallCombo.SelectedItem = $install
            }
        }
        foreach ($install in ($script:Installs | Where-Object { $_.IsPtr })) {
            $null = $ui.TargetInstallCombo.Items.Add($install)
            if ($script:Context.Target -and $install.Id -eq $script:Context.Target.Id) {
                $ui.TargetInstallCombo.SelectedItem = $install
            }
        }
    }
    finally {
        $script:Suppress = $false
    }

    # "Nothing found at all" is the folder box's story to tell, just above this.
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($script:Installs -and -not ($script:Installs | Where-Object { $_.IsPtr })) {
        $warnings.Add('No PTR client in that folder. Install it from the Battle.net launcher, then press Rescan.')
    }
    if ($script:Context.Target -and -not $script:Context.Target.HasBeenLaunched) {
        $warnings.Add('The PTR client has no WTF folder yet — launch it once, quit, then press Rescan.')
    }
    # There was a warning here when the two clients' game lines differed. It has
    # been removed: the line comes from .flavor.info, and Blizzard does not
    # always set it to what the client really is — _ptr2_ reports itself as
    # retail while serving as the Anniversary PTR. A warning that fires on a
    # perfectly normal pairing is worse than no warning, and there is no reliable
    # way to tell from the folder. The two dropdowns say which clients are
    # selected; that is the honest amount to claim.

    $ui.InstallWarning.Text = ($warnings -join '  ')
    $ui.InstallWarning.Visibility = if ($warnings.Count) { 'Visible' } else { 'Collapsed' }
}

function Update-AccountCombos {
    $script:Suppress = $true
    try {
        $ui.SourceAccountCombo.Items.Clear()
        $ui.TargetAccountCombo.Items.Clear()

        if ($script:Context.Source) {
            foreach ($account in (Get-WowAccount -Install $script:Context.Source)) {
                $null = $ui.SourceAccountCombo.Items.Add($account)
            }
            $ui.SourceAccountCombo.SelectedItem = $script:Context.SourceAccount
        }
        if ($script:Context.Target) {
            foreach ($account in (Get-WowAccount -Install $script:Context.Target)) {
                $null = $ui.TargetAccountCombo.Items.Add($account)
            }
            $ui.TargetAccountCombo.SelectedItem = $script:Context.TargetAccount
        }
    }
    finally {
        $script:Suppress = $false
    }
}

function Update-CharacterPanel {
    $ui.CharacterPanel.Children.Clear()

    $targets = @()
    $sources = @()
    if ($script:Context.Target -and $script:Context.TargetAccount) {
        $targets = @(Get-WowCharacter -Install $script:Context.Target -Account $script:Context.TargetAccount)
    }
    if ($script:Context.Source -and $script:Context.SourceAccount) {
        $sources = @(Get-WowCharacter -Install $script:Context.Source -Account $script:Context.SourceAccount)
    }

    if (-not $targets) {
        $null = $ui.CharacterPanel.Children.Add((New-TextBlockControl -Colour '#98A0B3' -Size 12 -Text `
                    'No characters on the PTR client yet. Copy a character to the PTR (step 2 below), then press Rescan.'))
        return
    }

    $header = New-Object System.Windows.Controls.Grid
    $null = $header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $null = $header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $left = New-TextBlockControl -Text 'PTR CHARACTER' -Colour '#98A0B3' -Size 11
    $right = New-TextBlockControl -Text 'GETS SETTINGS FROM' -Colour '#98A0B3' -Size 11
    [System.Windows.Controls.Grid]::SetColumn($right, 1)
    $null = $header.Children.Add($left)
    $null = $header.Children.Add($right)
    $null = $ui.CharacterPanel.Children.Add($header)

    $mapped = @{}
    foreach ($pair in $script:Context.Character) { $mapped[$pair.Target.Id] = $pair.Source.Id }

    foreach ($target in $targets) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        $null = $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $null = $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))

        $name = New-TextBlockControl -Text $target.Name
        $realm = New-TextBlockControl -Text $target.Realm -Colour '#98A0B3' -Size 11
        $stack = New-Object System.Windows.Controls.StackPanel
        $null = $stack.Children.Add($name)
        $null = $stack.Children.Add($realm)
        $null = $row.Children.Add($stack)

        $combo = New-Object System.Windows.Controls.ComboBox
        $combo.DisplayMemberPath = 'Display'
        $combo.Margin = New-Object System.Windows.Thickness 0
        $combo.VerticalAlignment = 'Center'
        $combo.Tag = $target
        # DisplayMemberPath resolves against every item, and a plain string has
        # no Display property — it would render as an empty row. The sentinel
        # carries one, and a type name Sync-CharacterMap can recognise.
        $null = $combo.Items.Add((New-SkipChoice))
        $combo.SelectedIndex = 0
        foreach ($source in $sources) {
            $null = $combo.Items.Add($source)
            if ($mapped.ContainsKey($target.Id) -and $mapped[$target.Id] -eq $source.Id) {
                $combo.SelectedItem = $source
            }
        }
        $combo.Add_SelectionChanged({ if (-not $script:Suppress) { Invoke-Guarded { Sync-CharacterMap } } })
        [System.Windows.Controls.Grid]::SetColumn($combo, 1)
        $null = $row.Children.Add($combo)
        $null = $ui.CharacterPanel.Children.Add($row)
    }
}

function Sync-CharacterMap {
    <#
    .SYNOPSIS
        Read the mapping rows back out of the window into the context.
    #>
    $pairs = [System.Collections.Generic.List[psobject]]::new()
    foreach ($child in $ui.CharacterPanel.Children) {
        if ($child -isnot [System.Windows.Controls.Grid]) { continue }
        foreach ($control in $child.Children) {
            if ($control -isnot [System.Windows.Controls.ComboBox]) { continue }
            $selected = $control.SelectedItem
            if (Test-SkipChoice $selected) { continue }
            $pairs.Add([pscustomobject]@{ Source = $selected; Target = $control.Tag })
        }
    }
    $script:Context.Character = @($pairs)
    $script:MappingTouched = $true
    Reset-Plan -Change 'character'
    Update-Steps
    Update-Summary
}

function Update-Steps {
    <#
    .SYNOPSIS
        Draw the step list, and ask the worker for anything not already planned.

    .DESCRIPTION
        Returns as soon as the cards are on screen. Steps whose plans are still
        cached are filled in straight away; the rest are handed to the background
        runspace and filled in when the answers come back, so no selection ever
        waits on a folder scan.
    #>
    $ui.StepsPanel.Children.Clear()
    $script:Cards = @{}

    foreach ($step in (Get-PtrSetupStep)) {
        # Whether a step can run at all is a handful of Test-Path calls, so it is
        # settled now rather than after its plan arrives. Waiting would leave
        # every tick box dead until the slowest folder had been walked, which
        # reads as a window that does not work.
        $blocker = if ($step.Mode -eq 'auto') { Get-PtrSetupStepBlocker -Step $step -Context $script:Context } else { $null }
        if (-not $script:SelectedTouched -and $step.Mode -eq 'auto' -and -not $blocker) {
            $null = $script:Selected.Add($step.Id)
        }

        # -Blocked:(...) with the colon. Written as "-Blocked (...)" PowerShell
        # reads the switch as simply present and the value as a positional
        # argument, which an advanced function rejects outright.
        $card = New-StepCard -Step $step -Blocked:([bool]$blocker)
        $script:Cards[$step.Id] = $card
        $null = $ui.StepsPanel.Children.Add($card.Card)
    }

    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($step in (Get-PtrSetupStep)) {
        # Manual steps and anything already planned need no worker.
        if ($step.Mode -ne 'auto' -or $script:Plans.ContainsKey($step.Id)) {
            if ($step.Mode -ne 'auto') { $script:Plans[$step.Id] = @() }
            Write-StepCardState -StepId $step.Id
            continue
        }
        $pending.Add($step.Id)
    }

    # Cheapest first, so the single-file steps answer immediately and the addon
    # folder — much the slowest — is the one left filling in.
    $order = @('copy_config_wtf', 'allow_out_of_date_addons', 'copy_character_data',
        'copy_account_saved_variables', 'copy_addons')
    $queued = @($pending | Sort-Object { $order.IndexOf($_) })
    Start-PlanRequest -StepId $queued
}

function Write-StepCardState {
    <#
    .SYNOPSIS
        Fill in one card from the plan now sitting in the cache.
    #>
    param([Parameter(Mandatory)] [string] $StepId)

    if (-not $script:Cards.ContainsKey($StepId)) { return }
    $step = Get-PtrSetupStep -Id $StepId
    $actions = @($script:Plans[$StepId])
    $status = Get-PtrSetupStepStatus -Step $step -Context $script:Context -Action $actions
    Set-StepCardState -Card $script:Cards[$StepId] -Step $step -Status $status -Actions $actions
}

function New-StepCard {
    <#
    .SYNOPSIS
        A step card with the cheap parts filled in and slots for the rest.
    #>
    param(
        [Parameter(Mandatory)] $Step,
        [switch] $Blocked
    )

    $card = New-Object System.Windows.Controls.Border
    $card.Background = Get-Brush '#222634'
    $card.BorderBrush = Get-Brush '#2F3546'
    $card.BorderThickness = New-Object System.Windows.Thickness 1
    $card.CornerRadius = New-Object System.Windows.CornerRadius 6
    $card.Padding = New-Object System.Windows.Thickness 12
    $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8

    $grid = New-Object System.Windows.Controls.Grid
    $checkColumn = New-Object System.Windows.Controls.ColumnDefinition
    $checkColumn.Width = [System.Windows.GridLength]::Auto
    $null = $grid.ColumnDefinitions.Add($checkColumn)
    $null = $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))

    $check = New-Object System.Windows.Controls.CheckBox
    $check.Margin = New-Object System.Windows.Thickness 0, 2, 10, 0
    $check.VerticalAlignment = 'Top'
    $check.Tag = $Step
    if ($Step.Mode -eq 'auto') {
        # Live straight away: ticking a step is choosing to run it, which has
        # nothing to do with knowing yet how many files that will be.
        $check.IsEnabled = (-not $Blocked)
        $check.IsChecked = $script:Selected.Contains($Step.Id)
        $check.ToolTip = 'Include this step when you press Apply'
        $check.Add_Click({
                param($sender, $e)
                Invoke-Guarded {
                    $stepId = $sender.Tag.Id
                    if ($sender.IsChecked) { $null = $script:Selected.Add($stepId) } else { $null = $script:Selected.Remove($stepId) }
                    $script:SelectedTouched = $true
                    Update-Summary
                }
            })
    }
    else {
        $check.IsEnabled = $true
        $check.ToolTip = 'Mark this manual step as done'
        $check.Add_Click({
                param($sender, $e)
                Invoke-Guarded {
                    $stepId = $sender.Tag.Id
                    if ($sender.IsChecked) { $null = $script:Context.Acknowledged.Add($stepId) }
                    else { $null = $script:Context.Acknowledged.Remove($stepId) }
                    # Only this step's own status can have changed.
                    Update-Steps
                }
            })
    }
    $null = $grid.Children.Add($check)

    $body = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetColumn($body, 1)

    $titleRow = New-Object System.Windows.Controls.StackPanel
    $titleRow.Orientation = 'Horizontal'
    $null = $titleRow.Children.Add((New-TextBlockControl -Text $Step.Title -Weight 'SemiBold'))
    $null = $titleRow.Children.Add((New-Pill -Text 'checking' -Kind 'pending'))
    $null = $body.Children.Add($titleRow)

    $null = $body.Children.Add((New-TextBlockControl -Text $Step.Summary -Colour '#98A0B3' -Size 12 `
                -Margin (New-Object System.Windows.Thickness 0, 3, 0, 0)))

    $detail = New-TextBlockControl -Text '' -Colour '#98A0B3' -Size 12
    if ($Step.Mode -eq 'auto') {
        $detail.Text = 'Working out what will change…'
        $detail.Visibility = 'Visible'
    }
    else {
        $detail.Visibility = 'Collapsed'
    }
    $null = $body.Children.Add($detail)

    # Only the hand-held steps get their instructions on the card. An automated
    # one is described by what it does and the file list underneath it; a
    # paragraph explaining where the idea came from is for the docs.
    if ($Step.Mode -eq 'manual' -and $Step.Instructions) {
        $null = $body.Children.Add((New-TextBlockControl -Text $Step.Instructions -Size 12.5 `
                    -Margin (New-Object System.Windows.Thickness 0, 6, 0, 0)))
    }

    # Where the file list goes once there is one.
    $slot = New-Object System.Windows.Controls.StackPanel
    $null = $body.Children.Add($slot)

    $null = $grid.Children.Add($body)
    $card.Child = $grid

    return [pscustomobject]@{
        Card     = $card
        Check    = $check
        TitleRow = $titleRow
        Detail   = $detail
        Slot     = $slot
    }
}

function Set-StepCardState {
    <#
    .SYNOPSIS
        Fill in the parts of a card that needed the plan.
    #>
    param(
        [Parameter(Mandatory)] $Card,
        [Parameter(Mandatory)] $Step,
        [Parameter(Mandatory)] $Status,
        [AllowEmptyCollection()] [psobject[]] $Actions
    )

    $actions = @($Actions)
    # Skips are files already on the PTR. They belong in the list, so you can see
    # they were considered, but not in the counts of what will change.
    $changing = @($actions | Where-Object { $_.Kind -ne 'skip' })

    $Card.Card.BorderBrush = Get-Brush $(if ($Status.State -eq 'done') { '#33613F' } else { '#2F3546' })

    if ($Step.Mode -eq 'auto') {
        # Whether it is ticked is the user's business by now; only its being
        # runnable can have changed.
        $Card.Check.IsEnabled = ($Status.State -ne 'blocked')
    }
    else {
        $Card.Check.IsChecked = ($Status.State -eq 'done')
    }

    # Swap the placeholder pill for the real one.
    $kind = if ($Step.Mode -eq 'manual') { 'manual' } else { $Status.State }
    $Card.TitleRow.Children.RemoveAt($Card.TitleRow.Children.Count - 1)
    $null = $Card.TitleRow.Children.Add((New-Pill -Text $kind -Kind $kind))

    if ($Status.Detail) {
        $Card.Detail.Text = $Status.Detail
        $Card.Detail.Visibility = 'Visible'
    }
    else {
        # Otherwise the "working out what will change" placeholder would stay up.
        $Card.Detail.Visibility = 'Collapsed'
    }

    $Card.Slot.Children.Clear()
    if ($Step.Mode -ne 'auto' -or -not $actions.Count) { return }

    # Bytes are what will be written, so deletes are counted as files but not as
    # data: adding the size of a file being removed to "how much will be copied"
    # makes the total disagree with the folder the user is looking at.
    $writes = @($changing | Where-Object { $_.Kind -ne 'delete' })
    $removals = $changing.Count - $writes.Count
    $bytes = [long](($writes | Measure-Object -Property Size -Sum).Sum)
    $unchanged = $actions.Count - $changing.Count

    $expander = New-Object System.Windows.Controls.Expander
    $expander.Header = "Show the $($writes.Count) file(s) — $(Format-ByteSize $bytes)" +
        $(if ($removals) { " · $removals to remove" } else { '' }) +
        $(if ($unchanged) { " · $unchanged already on the PTR" } else { '' })
    $expander.Foreground = Get-Brush '#F0C674'
    $expander.FontSize = 12
    $expander.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    $expander.Tag = $actions
    # The list is built the first time it is opened. Formatting tens of thousands
    # of lines for a panel nobody has looked at is most of a refresh wasted.
    $expander.Add_Expanded({
            param($sender, $e)
            Invoke-Guarded {
                if ($sender.Content) { return }
                $sender.Content = New-FileListBox -Actions $sender.Tag
            }
        })
    $null = $Card.Slot.Children.Add($expander)
}

function New-FileListBox {
    <#
    .SYNOPSIS
        The read-only list of planned files inside a step's expander.
    #>
    param([AllowEmptyCollection()] [psobject[]] $Actions)

    $list = New-Object System.Windows.Controls.TextBox
    $list.IsReadOnly = $true
    # Without AcceptsReturn a TextBox is single-line and the whole file list
    # renders on one row.
    $list.AcceptsReturn = $true
    $list.MaxHeight = 160
    $list.FontFamily = 'Consolas'
    $list.FontSize = 11
    $list.Background = Get-Brush '#171A22'
    $list.Foreground = Get-Brush '#98A0B3'
    $list.BorderBrush = Get-Brush '#2F3546'
    $list.VerticalScrollBarVisibility = 'Auto'
    $list.TextWrapping = 'NoWrap'

    $builder = New-Object System.Text.StringBuilder
    foreach ($action in @($Actions)) {
        $note = if ($action.Note) { "  · $($action.Note)" } else { '' }
        $null = $builder.AppendLine(('{0,-9} {1}{2}' -f $action.Kind, $action.Destination, $note))
    }
    $list.Text = $builder.ToString().TrimEnd()
    return $list
}

function Update-Summary {
    $files = 0
    $bytes = [long]0
    # Never plans anything itself: this runs while the worker is still going, and
    # a synchronous plan here would put the pause back that the worker removes.
    $waiting = $false
    foreach ($step in (Get-PtrSetupStep)) {
        if (-not $script:Selected.Contains($step.Id)) { continue }
        if (-not $script:Plans.ContainsKey($step.Id)) { $waiting = $true; continue }
        $actions = @($script:Plans[$step.Id] | Where-Object { $_.Kind -ne 'skip' })
        $files += $actions.Count
        # As above: only what gets written counts towards the byte total.
        $written = @($actions | Where-Object { $_.Kind -ne 'delete' })
        $bytes += ([long](($written | Measure-Object -Property Size -Sum).Sum))
    }

    $ready = Test-ContextReady -Context $script:Context
    # Applying half a plan would copy less than the window is showing.
    $ui.PreviewButton.IsEnabled = ($ready -and -not $waiting -and $files -gt 0)
    $ui.ApplyButton.IsEnabled = ($ready -and -not $waiting -and $files -gt 0)
    $ui.SummaryText.Text = if ($waiting) {
        'Working out what needs copying…'
    }
    elseif (-not $ready) {
        'Pick a live client and a PTR client to begin.'
    }
    elseif (-not $script:Selected.Count) {
        'No steps ticked — tick the ones you want to run.'
    }
    elseif ($files -eq 0) {
        "$($script:Selected.Count) step(s) selected · already up to date, nothing to copy."
    }
    else {
        "$($script:Selected.Count) step(s) selected · $files file(s) · $(Format-ByteSize $bytes)"
    }
}

function Update-Backups {
    $ui.BackupCombo.Items.Clear()
    if ($script:Context.Target) {
        foreach ($backup in (Get-PtrSetupBackup -InstallPath $script:Context.Target.Path)) {
            $null = $ui.BackupCombo.Items.Add($backup)
        }
        if ($ui.BackupCombo.Items.Count) { $ui.BackupCombo.SelectedIndex = 0 }
    }
    # Set last, and on every path — returning early here used to leave the button
    # looking usable with no backups behind it.
    $ui.RestoreButton.IsEnabled = ($ui.BackupCombo.Items.Count -gt 0)
}

function Update-Options {
    $script:Suppress = $true
    try {
        $ui.OverwriteOption.IsChecked = [bool]$script:Context.Options['Overwrite']
        $ui.ReplaceAddOnsOption.IsChecked = [bool]$script:Context.Options['ReplaceAddOns']
        $ui.MacrosOption.IsChecked = [bool]$script:Context.Options['IncludeMacrosBindings']
        $ui.ChatOption.IsChecked = [bool]$script:Context.Options['IncludeChatCache']
        $ui.OutOfDateOption.IsChecked = [bool]$script:Context.Options['AllowOutOfDate']
    }
    finally {
        $script:Suppress = $false
    }
}

function Update-All {
    # Anything that gets here has just re-read the folders, so the watch starts
    # from what is there now rather than reporting the same change again.
    if ($script:Context) { $script:Fingerprint = Get-WowFolderFingerprint -Context $script:Context }

    <#
    .SYNOPSIS
        Redraw everything, from scratch.

    .DESCRIPTION
        Every caller of this reaches it because something wholesale changed — a
        different client picked, a rescan, or an Apply or Restore that just moved
        files about. So the cached plans go first: keeping one after writing to
        the PTR folder would leave a step reporting work it has already done. The
        narrower changes (account, character, an option) call Update-Steps
        directly and throw away only what they have to.
    #>
    Reset-Plan
    Update-FolderStatus
    Update-InstallCombos
    Update-AccountCombos
    Update-CharacterPanel
    Update-Steps
    Update-Summary
    Update-Backups
}

function Invoke-Rescan {
    Reset-Plan
    $ui.SummaryText.Text = 'Reading folders…'
    $ui.PreviewButton.IsEnabled = $false
    $ui.ApplyButton.IsEnabled = $false
    Update-UiNow

    # The box is authoritative: look where the user said, not everywhere. -Path
    # adds anything passed on the command line on top of it.
    $paths = [System.Collections.Generic.List[string]]::new()
    if ($script:WowFolder) { $paths.Add($script:WowFolder) }
    foreach ($extra in $script:ExtraPaths) { $paths.Add($extra) }
    $script:Installs = @(Get-WowInstall -Path $paths -SkipDefaultLocations)
    if ($null -eq $script:Context) {
        $script:Context = Initialize-PtrSetupContext -Install $script:Installs
        Update-Options
    }
    else {
        # Keep the current selection if those folders are still there.
        $ids = @($script:Installs | ForEach-Object { $_.Id })
        if ($script:Context.Source -and $ids -notcontains $script:Context.Source.Id) { $script:Context.Source = $null }
        if ($script:Context.Target -and $ids -notcontains $script:Context.Target.Id) { $script:Context.Target = $null }
        $script:Context = Set-PtrSetupAccountGuess -Context $script:Context
        $script:Context = Set-PtrSetupCharacterGuess -Context $script:Context -Force
    }
    Update-All
}

function Invoke-Run {
    <#
    .SYNOPSIS
        Preview or apply the ticked steps, on the worker, without freezing.

    .DESCRIPTION
        Applying used to run on the UI thread. Copying pumps the window between
        files, but the phases around it do not — validating the whole batch,
        copying every replaced file into the backup, writing a manifest listing
        thousands of paths — and on a real install that is long enough for
        Windows to grey the window out and call it not responding.

        It runs on the same background runspace the planning uses. Progress comes
        back through a synchronized hashtable the worker writes and a timer here
        reads, so the only thing crossing threads is a table of numbers.
    #>
    param([switch] $PreviewOnly)

    if ($script:Running) { return }
    $stepIds = @((Get-PtrSetupStep | Where-Object { $script:Selected.Contains($_.Id) }).Id)
    if (-not $stepIds) { return }

    if (-not $PreviewOnly) {
        # Already worked out; Apply is only enabled once every selected step has a plan.
        $planned = @(foreach ($id in $stepIds) { $script:Plans[$id] })
        $deletes = @($planned | Where-Object { $_.Kind -eq 'delete' }).Count
        $message = "Apply $($stepIds.Count) step(s) to $($script:Context.Target.Path)?"
        if ($deletes) { $message += "`n`n$deletes file(s) will be REMOVED from the PTR folder." }
        $message += "`n`nEverything overwritten or removed is backed up first."

        # WoW rewrites WTF as it exits, so copying under a running client is wasted work.
        $running = @(Get-RunningWowProcess)
        if ($running.Count) {
            $message += "`n`nWarning: World of Warcraft is still running ($((@($running.Name | Select-Object -Unique)) -join ', ')). Quit it first, or the game will overwrite what is copied."
        }

        $answer = [System.Windows.MessageBox]::Show($message, 'WoW PTR UI Setup', 'OKCancel', 'Warning')
        if ($answer -ne 'OK') { return }
    }

    $script:Running = $true
    $ui.ApplyButton.IsEnabled = $false
    $ui.PreviewButton.IsEnabled = $false
    $ui.ProgressBar.Value = 0
    Write-Result $(if ($PreviewOnly) { '--- Preview (nothing is written) ---' } else { '--- Applying ---' })

    $runspace = Get-PlanWorker
    if (-not $runspace) {
        Invoke-RunHere -StepId $stepIds -PreviewOnly:$PreviewOnly
        return
    }

    # Written by the worker, read by the timer below. A hashtable of numbers is
    # the whole of what crosses between the two.
    $progress = [hashtable]::Synchronized(@{
            Title = ''; Index = 0; Total = @($stepIds).Count; Done = 0; Files = 0
        })

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $null = $shell.AddScript({
            param($Snapshot, $StepId, $PreviewOnly, $Progress)
            $context = ConvertFrom-PtrSetupSnapshot -Snapshot $Snapshot
            $ids = @($StepId)
            $index = 0
            $results = New-Object System.Collections.ArrayList
            foreach ($id in $ids) {
                $step = Get-PtrSetupStep -Id $id
                $Progress['Title'] = $step.Title
                $Progress['Index'] = $index
                $Progress['Total'] = $ids.Count
                $Progress['Done'] = 0
                $Progress['Files'] = 0

                $result = Invoke-PtrSetupStep -Step $step -Context $context -PreviewOnly:$PreviewOnly -OnProgress {
                    param($Done, $FileCount)
                    $Progress['Done'] = $Done
                    $Progress['Files'] = $FileCount
                }
                $null = $results.Add([pscustomobject]@{
                        Title = $step.Title; Ok = [bool]$result.Ok; Message = [string]$result.Message
                    })
                $index++
            }
            return $results.ToArray()
        })
    $null = $shell.AddArgument((ConvertTo-PtrSetupSnapshot -Context $script:Context))
    $null = $shell.AddArgument($stepIds)
    $null = $shell.AddArgument([bool]$PreviewOnly)
    $null = $shell.AddArgument($progress)

    $script:RunJob = [pscustomobject]@{
        Shell    = $shell
        Handle   = $shell.BeginInvoke()
        Progress = $progress
    }

    if (-not $script:RunTimer) {
        $script:RunTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:RunTimer.Interval = [TimeSpan]::FromMilliseconds(120)
        $script:RunTimer.Add_Tick({ Invoke-Guarded { Receive-Run } })
    }
    $script:RunTimer.Start()
}

function Receive-Run {
    <#
    .SYNOPSIS
        Show how far the run has got, and finish up when it is done.
    #>
    $job = $script:RunJob
    if (-not $job) {
        $script:RunTimer.Stop()
        return
    }

    # One bar across the whole run: each step gets its share of the width, so it
    # never restarts part way through.
    $progress = $job.Progress
    $total = [double]([math]::Max(1, $progress['Total']))
    $files = [double]([math]::Max(1, $progress['Files']))
    $withinStep = [math]::Min(1.0, $progress['Done'] / $files)
    $ui.ProgressBar.Value = [math]::Min(100, 100 * (($progress['Index'] + $withinStep) / $total))
    if ($progress['Title']) {
        $ui.SummaryText.Text = "Step $([int]$progress['Index'] + 1) of $([int]$progress['Total']): $($progress['Title'])"
    }

    if (-not $job.Handle.IsCompleted) { return }
    $script:RunTimer.Stop()

    try {
        $results = @($job.Shell.EndInvoke($job.Handle))
        $errors = @($job.Shell.Streams.Error)
        if ($errors.Count) { Write-Result "[fail] $($errors[0])" }
        foreach ($result in $results) {
            $mark = if ($result.Ok) { '[ok]  ' } else { '[fail]' }
            Write-Result "$mark $($result.Title) — $($result.Message)"
        }
    }
    catch {
        Write-Result "[fail] $($_.Exception.Message)"
    }
    finally {
        try { $job.Shell.Dispose() } catch { <# nothing to dispose #> }
        $script:RunJob = $null
        Complete-Run
    }
}

function Invoke-RunHere {
    <#
    .SYNOPSIS
        The same run on this thread, for a machine that will not give a runspace.
    #>
    param(
        [Parameter(Mandatory)] [string[]] $StepId,
        [switch] $PreviewOnly
    )

    $script:RunIndex = 0
    $script:RunTotal = @($StepId).Count
    try {
        foreach ($stepId in $StepId) {
            $step = Get-PtrSetupStep -Id $stepId
            $ui.SummaryText.Text = "Step $($script:RunIndex + 1) of $($script:RunTotal): $($step.Title)"
            Update-UiNow

            $result = Invoke-PtrSetupStep -Step $step -Context $script:Context -PreviewOnly:$PreviewOnly -OnProgress {
                param($Done, $Total)
                $withinStep = $Done / [math]::Max(1, $Total)
                $ui.ProgressBar.Value = [math]::Min(100, 100 * ($script:RunIndex + $withinStep) / $script:RunTotal)
                Update-UiNow
            }
            $script:RunIndex++

            $mark = if ($result.Ok) { '[ok]  ' } else { '[fail]' }
            Write-Result "$mark $($step.Title) — $($result.Message)"
            Update-UiNow
        }
    }
    catch {
        Write-Result "[fail] $($_.Exception.Message)"
    }
    finally {
        Complete-Run
    }
}

function Complete-Run {
    <#
    .SYNOPSIS
        Put the window back together after a run, however it ended.
    #>
    $script:Running = $false
    $ui.ProgressBar.Value = 0
    Update-All
}

# --------------------------------------------------------------------------
# Events
# --------------------------------------------------------------------------

$ui.RescanButton.Add_Click({ Invoke-Guarded { Invoke-Rescan } })

$ui.BrowseButton.Add_Click({
        Invoke-Guarded {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Pick your "World of Warcraft" folder (or a client folder inside it)'
            # Open where they already are rather than at the top of the tree.
            if ($script:WowFolder -and (Test-Path -LiteralPath $script:WowFolder -PathType Container)) {
                $dialog.SelectedPath = $script:WowFolder
            }
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-WowFolder $dialog.SelectedPath
            }
        }
    })

$ui.DetectButton.Add_Click({
        Invoke-Guarded {
            $ui.FolderStatus.Text = 'Looking…'
            Update-UiNow
            $found = Find-WowFolder
            if ($found) {
                Set-WowFolder $found
            }
            else {
                $ui.FolderStatus.Text = 'Could not find an install — use Browse to point at the folder.'
            }
        }
    })

# Enter commits the typed path. Leaving the box commits it too, so a click
# straight onto Preview does not quietly use the old folder.
$ui.FolderBox.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -ne [System.Windows.Input.Key]::Return) { return }
        $e.Handled = $true
        Invoke-Guarded { Set-WowFolder $sender.Text }
    })

$ui.FolderBox.Add_LostFocus({
        param($sender, $e)
        Invoke-Guarded {
            if ($sender.Text.Trim('"', ' ') -ne $script:WowFolder) { Set-WowFolder $sender.Text }
        }
    })

$ui.SourceInstallCombo.Add_SelectionChanged({
        if ($script:Suppress) { return }
        Invoke-Guarded {
            $script:Context = Set-PtrSetupInstall -Context $script:Context -Side 'Source' -Install $ui.SourceInstallCombo.SelectedItem
            Update-All
        }
    })

$ui.TargetInstallCombo.Add_SelectionChanged({
        if ($script:Suppress) { return }
        Invoke-Guarded {
            $script:Context = Set-PtrSetupInstall -Context $script:Context -Side 'Target' -Install $ui.TargetInstallCombo.SelectedItem
            Update-All
        }
    })

$ui.SourceAccountCombo.Add_SelectionChanged({
        if ($script:Suppress) { return }
        Invoke-Guarded {
            $script:Context = Set-PtrSetupAccount -Context $script:Context -Side 'Source' -Account ([string]$ui.SourceAccountCombo.SelectedItem)
            # Changing the account re-guesses the character mapping too.
            Reset-Plan -Change 'account'
            Update-CharacterPanel; Update-Steps; Update-Summary
        }
    })

$ui.TargetAccountCombo.Add_SelectionChanged({
        if ($script:Suppress) { return }
        Invoke-Guarded {
            $script:Context = Set-PtrSetupAccount -Context $script:Context -Side 'Target' -Account ([string]$ui.TargetAccountCombo.SelectedItem)
            # Changing the account re-guesses the character mapping too.
            Reset-Plan -Change 'account'
            Update-CharacterPanel; Update-Steps; Update-Summary
        }
    })

$optionMap = @{
    OverwriteOption     = 'Overwrite'
    ReplaceAddOnsOption = 'ReplaceAddOns'
    MacrosOption        = 'IncludeMacrosBindings'
    ChatOption          = 'IncludeChatCache'
    OutOfDateOption     = 'AllowOutOfDate'
}
foreach ($controlName in $optionMap.Keys) {
    $ui[$controlName].Tag = $optionMap[$controlName]
    $ui[$controlName].Add_Click({
            param($sender, $e)
            if ($script:Suppress) { return }
            Invoke-Guarded {
                $script:Context.Options[$sender.Tag] = [bool]$sender.IsChecked
                Reset-Plan -Change $sender.Tag
                Update-Steps
                Update-Summary
            }
        })
}

$ui.RefreshBackupsButton.Add_Click({ Invoke-Guarded { Update-Backups } })

$ui.RestoreButton.Add_Click({
        Invoke-Guarded {
            $backup = $ui.BackupCombo.SelectedItem
            if (-not $backup) { return }
            $answer = [System.Windows.MessageBox]::Show(
                "Undo $($backup.Id)?`n`n$($backup.FileCount) replaced file(s) go back, and $($backup.AddedCount) file(s) this run added are removed." +
                "`n`nThis undoes one step. An Apply that ran several steps leaves one backup per step, so undoing the whole run means restoring each of them.",
                'WoW PTR UI Setup', 'OKCancel', 'Question')
            if ($answer -ne 'OK') { return }

            $undo = Restore-PtrSetupBackup -InstallPath $script:Context.Target.Path -BackupId $backup.Id
            Write-Result "[ok]   Undid $($backup.Id): put back $($undo.Restored) file(s), removed $($undo.Removed) added file(s)."
            Update-All
        }
    })

$ui.PreviewButton.Add_Click({ Invoke-Guarded { Invoke-Run -PreviewOnly } })
$ui.ApplyButton.Add_Click({ Invoke-Guarded { Invoke-Run } })

# --------------------------------------------------------------------------
# Go
# --------------------------------------------------------------------------

Write-Result 'Quit World of Warcraft before applying — it rewrites WTF when it exits.'
$ui.SummaryText.Text = 'Starting…'

# The first scan happens after the window is on screen, not before it. Reading a
# real AddOns folder takes a moment, and doing it first means the user double
# clicks and watches nothing happen; doing it here means they watch it happen.
# ContentRendered can fire again later, so this only runs the once.
$script:Started = $false
$window.Add_ContentRendered({
        if ($script:Started) { return }
        $script:Started = $true
        Invoke-Guarded {
            try {
                # -Path wins when given; otherwise pick up where the user left off.
                $ui.FolderBox.Text = 'Looking for World of Warcraft…'
                $ui.FolderStatus.Text = 'Checking the usual places and the registry…'
                # Detection has no sensible percentage, so the bar just moves.
                $ui.ProgressBar.IsIndeterminate = $true
                Update-UiNow
                $script:WowFolder = if ($script:ExtraPaths.Count) { $script:ExtraPaths[0] } else { Get-StartingFolder }
                $ui.FolderBox.Text = $script:WowFolder
            }
            finally {
                # Left on, this would keep sweeping over the real progress the
                # step list reports from here on.
                $ui.ProgressBar.IsIndeterminate = $false
            }
            Invoke-Rescan
            Start-Watching
        }
    })

$window.Add_Closed({
        # The worker holds a thread; without this the console lingers after the
        # window has gone.
        if ($script:WatchTimer) { $script:WatchTimer.Stop() }
        if ($script:RunTimer) { $script:RunTimer.Stop() }
        Stop-PlanRequest
        Clear-AbandonedRequest
        if ($script:Worker) {
            try { $script:Worker.Close() } catch { <# already gone #> }
            try { $script:Worker.Dispose() } catch { <# already gone #> }
            $script:Worker = $null
        }
    })

Write-Startup 'opening...'
Write-Host ''
Write-Host '  The window is open. Closing it closes this console too.' -ForegroundColor DarkGray
Write-Host ''

$null = $window.ShowDialog()
