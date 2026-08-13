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

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# --------------------------------------------------------------------------
# Window
# --------------------------------------------------------------------------

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
    catch { Write-Result "[fail] $($_.Exception.Message)" }
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
    if ($script:Context.Source -and $script:Context.Target -and $script:Context.Source.Line -ne $script:Context.Target.Line) {
        $warnings.Add('Heads up: those two clients are different versions of the game, so settings may not carry over cleanly.')
    }

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
    Update-Steps
    Update-Summary
}

function Update-Steps {
    $ui.StepsPanel.Children.Clear()

    foreach ($step in (Get-PtrSetupStep)) {
        $status = Get-PtrSetupStepStatus -Step $step -Context $script:Context
        $actions = @(New-PtrSetupStepPlan -Step $step -Context $script:Context)
        # Skips are files already on the PTR. They belong in the list, so you can
        # see they were considered, but not in the counts of what will change.
        $changing = @($actions | Where-Object { $_.Kind -ne 'skip' })
        $bytes = ($changing | Measure-Object -Property Size -Sum).Sum

        # First render pre-ticks every automated step that has work to do.
        if (-not $script:SelectedTouched -and $step.Mode -eq 'auto' -and $status.State -ne 'blocked') {
            $null = $script:Selected.Add($step.Id)
        }

        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-Brush '#222634'
        $card.BorderBrush = Get-Brush $(if ($status.State -eq 'done') { '#33613F' } else { '#2F3546' })
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
        $check.Tag = $step
        if ($step.Mode -eq 'auto') {
            $check.IsChecked = $script:Selected.Contains($step.Id)
            $check.IsEnabled = ($status.State -ne 'blocked')
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
            $check.IsChecked = ($status.State -eq 'done')
            $check.ToolTip = 'Mark this manual step as done'
            $check.Add_Click({
                    param($sender, $e)
                    Invoke-Guarded {
                        $stepId = $sender.Tag.Id
                        if ($sender.IsChecked) { $null = $script:Context.Acknowledged.Add($stepId) }
                        else { $null = $script:Context.Acknowledged.Remove($stepId) }
                        Update-Steps
                    }
                })
        }
        $null = $grid.Children.Add($check)

        $body = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($body, 1)

        $titleRow = New-Object System.Windows.Controls.StackPanel
        $titleRow.Orientation = 'Horizontal'
        $null = $titleRow.Children.Add((New-TextBlockControl -Text $step.Title -Weight 'SemiBold'))
        $pillKind = if ($step.Mode -eq 'manual') { 'manual' } else { $status.State }
        $pillText = if ($step.Mode -eq 'manual') { 'manual' } else { $status.State }
        $null = $titleRow.Children.Add((New-Pill -Text $pillText -Kind $pillKind))
        $null = $body.Children.Add($titleRow)

        $null = $body.Children.Add((New-TextBlockControl -Text $step.Summary -Colour '#98A0B3' -Size 12 `
                    -Margin (New-Object System.Windows.Thickness 0, 3, 0, 0)))
        if ($status.Detail) {
            $null = $body.Children.Add((New-TextBlockControl -Text $status.Detail -Colour '#98A0B3' -Size 12))
        }
        if ($step.Instructions) {
            $null = $body.Children.Add((New-TextBlockControl -Text $step.Instructions -Size 12.5 `
                        -Margin (New-Object System.Windows.Thickness 0, 6, 0, 0)))
        }

        if ($step.Mode -eq 'auto' -and $actions.Count) {
            $unchanged = $actions.Count - $changing.Count
            $expander = New-Object System.Windows.Controls.Expander
            $expander.Header = "Show the $($changing.Count) file(s) — $(Format-ByteSize ([long]$bytes))" +
                $(if ($unchanged) { " · $unchanged already on the PTR" } else { '' })
            $expander.Foreground = Get-Brush '#F0C674'
            $expander.FontSize = 12
            $expander.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0

            $list = New-Object System.Windows.Controls.TextBox
            $list.IsReadOnly = $true
            # Without AcceptsReturn a TextBox is single-line and the whole file
            # list renders on one row.
            $list.AcceptsReturn = $true
            $list.MaxHeight = 160
            $list.FontFamily = 'Consolas'
            $list.FontSize = 11
            $list.Background = Get-Brush '#171A22'
            $list.Foreground = Get-Brush '#98A0B3'
            $list.BorderBrush = Get-Brush '#2F3546'
            $list.VerticalScrollBarVisibility = 'Auto'
            $list.TextWrapping = 'NoWrap'
            $list.Text = (@($actions | ForEach-Object {
                        $note = if ($_.Note) { "  · $($_.Note)" } else { '' }
                        '{0,-9} {1}{2}' -f $_.Kind, $_.Destination, $note
                    }) -join [Environment]::NewLine)
            $expander.Content = $list
            $null = $body.Children.Add($expander)
        }

        if ($step.SourceNote) {
            $note = New-TextBlockControl -Text $step.SourceNote -Colour '#6E768C' -Size 11 `
                -Margin (New-Object System.Windows.Thickness 0, 8, 0, 0)
            $note.FontStyle = 'Italic'
            $null = $body.Children.Add($note)
        }

        $null = $grid.Children.Add($body)
        $card.Child = $grid
        $null = $ui.StepsPanel.Children.Add($card)
    }

    $script:SelectedTouched = $true
}

function Update-Summary {
    $files = 0
    $bytes = [long]0
    foreach ($step in (Get-PtrSetupStep)) {
        if (-not $script:Selected.Contains($step.Id)) { continue }
        $actions = @(New-PtrSetupStepPlan -Step $step -Context $script:Context | Where-Object { $_.Kind -ne 'skip' })
        $files += $actions.Count
        $bytes += ([long](($actions | Measure-Object -Property Size -Sum).Sum))
    }

    $ready = Test-ContextReady -Context $script:Context
    $ui.PreviewButton.IsEnabled = ($ready -and $files -gt 0)
    $ui.ApplyButton.IsEnabled = ($ready -and $files -gt 0)
    $ui.SummaryText.Text = if (-not $ready) {
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
    Update-FolderStatus
    Update-InstallCombos
    Update-AccountCombos
    Update-CharacterPanel
    Update-Steps
    Update-Summary
    Update-Backups
}

function Invoke-Rescan {
    $ui.SummaryText.Text = 'Reading folders…'
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
    param([switch] $PreviewOnly)

    $stepIds = @((Get-PtrSetupStep | Where-Object { $script:Selected.Contains($_.Id) }).Id)
    if (-not $stepIds) { return }

    if (-not $PreviewOnly) {
        $planned = @(foreach ($id in $stepIds) { New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id $id) -Context $script:Context })
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

    $ui.ApplyButton.IsEnabled = $false
    $ui.PreviewButton.IsEnabled = $false
    $ui.ProgressBar.Value = 0
    Write-Result $(if ($PreviewOnly) { '--- Preview (nothing is written) ---' } else { '--- Applying ---' })

    try {
        foreach ($stepId in $stepIds) {
            $step = Get-PtrSetupStep -Id $stepId
            $result = Invoke-PtrSetupStep -Step $step -Context $script:Context -PreviewOnly:$PreviewOnly -OnProgress {
                param($Done, $Total)
                $ui.ProgressBar.Value = [math]::Min(100, ($Done / [math]::Max(1, $Total)) * 100)
                Update-UiNow
            }
            $mark = if ($result.Ok) { '[ok]  ' } else { '[fail]' }
            Write-Result "$mark $($step.Title) — $($result.Message)"
            Update-UiNow
        }
    }
    catch {
        Write-Result "[fail] $($_.Exception.Message)"
    }
    finally {
        $ui.ProgressBar.Value = 0
        Update-All
    }
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
            Update-CharacterPanel; Update-Steps; Update-Summary
        }
    })

$ui.TargetAccountCombo.Add_SelectionChanged({
        if ($script:Suppress) { return }
        Invoke-Guarded {
            $script:Context = Set-PtrSetupAccount -Context $script:Context -Side 'Target' -Account ([string]$ui.TargetAccountCombo.SelectedItem)
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

# -Path wins when given; otherwise pick up where the user left off, or detect.
$script:WowFolder = if ($script:ExtraPaths.Count) { $script:ExtraPaths[0] } else { Get-StartingFolder }
$ui.FolderBox.Text = $script:WowFolder

Invoke-Rescan
Write-Result 'Quit World of Warcraft before applying — it rewrites WTF when it exits.'
$null = $window.ShowDialog()
