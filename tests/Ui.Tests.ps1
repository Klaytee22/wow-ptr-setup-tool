<#
    The window itself cannot be exercised off Windows — WPF is not there to load.
    What can be checked anywhere is the contract between the two files: every
    control the script reaches for must exist in the XAML, and both files must
    parse. That catches the failure mode this pairing actually has — a renamed
    or mistyped x:Name that only blows up in front of a user.
#>

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPath = Join-Path $repoRoot 'PtrUiSetup.ps1'
$xamlPath = Join-Path $repoRoot 'ui/MainWindow.xaml'

function Get-XamlName {
    param([string] $Path)
    [xml] $document = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $names = foreach ($node in $document.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $attribute = $node.Attributes['x:Name']
        if ($attribute) { $attribute.Value }
    }
    return @($names)
}

function Get-UiReference {
    <#
        Finds every $ui.<Name> in the script, so the set can be compared with
        the names the XAML actually defines.
    #>
    param([string] $Path)

    $text = Get-Content -LiteralPath $Path -Raw
    $matched = [regex]::Matches($text, '\$ui\.([A-Za-z][A-Za-z0-9_]*)')
    $names = foreach ($match in $matched) { $match.Groups[1].Value }
    return @($names | Sort-Object -Unique)
}

Describe 'The window and its XAML' {

    It 'both files parse' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)
        Assert-Equal 0 @($errors).Count ("PtrUiSetup.ps1 has parse errors: " + (@($errors) -join '; '))

        # A well-formed XAML document is the least the loader needs.
        [xml] $document = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
        Assert-Equal 'Window' $document.DocumentElement.LocalName
    }

    It 'every control the script uses is named in the XAML' {
        $defined = Get-XamlName -Path $xamlPath
        $used = Get-UiReference -Path $scriptPath
        $missing = @($used | Where-Object { $defined -notcontains $_ })
        Assert-Equal 0 $missing.Count ("Referenced but not defined in the XAML: " + ($missing -join ', '))
    }

    It 'every named control in the XAML is wired up' {
        $defined = Get-XamlName -Path $xamlPath
        $used = Get-UiReference -Path $scriptPath
        # ResultsBox and friends are all touched somewhere; an unused name means
        # a control was added and then forgotten.
        $unused = @($defined | Where-Object { $used -notcontains $_ })
        Assert-Equal 0 $unused.Count ("Defined in the XAML but never used: " + ($unused -join ', '))
    }

    It 'names every control it needs for the four sections' {
        $defined = Get-XamlName -Path $xamlPath
        foreach ($required in @(
                'FolderBox', 'BrowseButton', 'DetectButton', 'FolderStatus',
                'SourceInstallCombo', 'TargetInstallCombo', 'RescanButton', 'InstallWarning',
                'SourceAccountCombo', 'TargetAccountCombo', 'CharacterPanel',
                'StepsPanel',
                'OverwriteOption', 'MacrosOption', 'ChatOption', 'OutOfDateOption',
                'BackupCombo', 'RefreshBackupsButton', 'RestoreButton',
                'ResultsBox', 'SummaryText', 'ProgressBar', 'PreviewButton', 'ApplyButton')) {
            Assert-True ($defined -contains $required) "The XAML is missing $required."
        }
    }

    It 'uses only colours WPF can parse' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        foreach ($match in [regex]::Matches($text, "'(#[0-9A-Fa-f]*[^0-9A-Fa-f'][^']*)'")) {
            $value = $match.Groups[1].Value
            Assert-True ($value -match '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$') "Not a valid colour literal: $value"
        }
        foreach ($match in [regex]::Matches($text, "Get-Brush '([^']+)'")) {
            Assert-True ($match.Groups[1].Value -match '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$') `
                "Get-Brush called with a bad colour: $($match.Groups[1].Value)"
        }
    }

    It 'puts every scrolling text box into multi-line mode' {
        # A WPF TextBox without AcceptsReturn is single-line: text set on it
        # renders on one row whatever newlines it contains, and the vertical
        # scrollbar never shows. Both boxes here are read-only logs, so the only
        # thing AcceptsReturn changes is whether they are readable.
        [xml] $document = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
        foreach ($node in $document.SelectNodes('//*[local-name()="TextBox"]')) {
            if ($node.GetAttribute('VerticalScrollBarVisibility') -ne 'Auto') { continue }
            Assert-Equal 'True' $node.GetAttribute('AcceptsReturn') `
                "TextBox $($node.GetAttribute('x:Name')) scrolls vertically but is still single-line."
        }

        # The file list the step cards build in code is the same shape.
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-True ($text -match '\$list\.AcceptsReturn\s*=\s*\$true') `
            'The planned-file list box needs AcceptsReturn or it renders on one line.'
    }

    It 'never puts a bare string into a list that displays a property' {
        # DisplayMemberPath binds that property on every item. A plain string has
        # no such property, so it renders as an empty row.
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-True ($text -notmatch "Items\.Add\('") `
            'Adding a string literal to a DisplayMemberPath list gives a blank entry — use an object with that property.'
        Assert-True ($text -match 'PtrUiSetup\.SkipChoice') `
            'The skip entry should be a typed object the mapping code can recognise.'
    }

    It 'runs every click handler inside the guard' {
        # An exception escaping a WPF event handler is unhandled and closes the
        # window, taking the user's selection with it. Found through the AST
        # rather than a regex so single-line handlers are checked too.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $subscriptions = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Member.Value -in @('Add_Click', 'Add_SelectionChanged', 'Add_KeyDown', 'Add_LostFocus')
                }, $true))

        Assert-True ($subscriptions.Count -ge 12) "Expected to find the event handlers, found $($subscriptions.Count)."
        foreach ($subscription in $subscriptions) {
            $body = $subscription.Arguments[0].Extent.Text
            Assert-True ($body -match 'Invoke-Guarded') `
                ("An event handler is unguarded at line $($subscription.Extent.StartLineNumber): " +
                    ($body.Trim() -split "`n")[0])
        }
    }

    It 'can reach every folder it needs without a command-line flag' {
        # -Path stays for scripting, but nothing in the window may depend on it:
        # the folder box, Browse and Detect have to cover it between them.
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-True ($text -match 'Get-StartingFolder') 'The box needs a starting value on first launch.'
        Assert-True ($text -match 'Find-WowFolder') 'Detect needs to be wired to detection.'
        Assert-True ($text -match 'FolderBrowserDialog') 'Browse needs a folder picker.'
        Assert-True ($text -match 'Save-PtrSetupSetting') 'A corrected folder should be remembered.'
    }

    It 'checks for an STA thread before asking WPF for a window' {
        # Only Start-PtrUiSetup.cmd passes -STA. Someone running the script from
        # an MTA session should be told what to do, not handed a WPF stack trace.
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-True ($text -match 'GetApartmentState') 'The window should check its apartment state first.'
        $staCheck = $text.IndexOf('GetApartmentState')
        $addType = $text.IndexOf('Add-Type -AssemblyName PresentationFramework')
        Assert-True ($staCheck -lt $addType) 'The check has to come before WPF is loaded.'
    }

    It 'keeps the step ids in the module and the launcher in step' {
        # -ListSteps is the console path through the same registry the window renders.
        $ids = @((Get-PtrSetupStep).Id)
        Assert-True ($ids -contains 'copy_addons')
        Assert-True ($ids -contains 'quit_the_game')
        Assert-Equal 9 $ids.Count
        Assert-Equal @($ids | Sort-Object -Unique).Count $ids.Count 'Step ids must be unique.'
    }
}

Describe 'The double-click launchers' {
    <#
        Windows does not run a .ps1 on double-click — Explorer opens it in
        Notepad, and so does Command Prompt. The .cmd files are the only entry
        points a person can actually click, so they have to point at real files.
    #>

    It 'every launcher points at a script that exists' {
        $launchers = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.cmd' -File)
        Assert-True ($launchers.Count -ge 3) "Expected the launchers, found $($launchers.Count)."

        foreach ($launcher in $launchers) {
            $text = Get-Content -LiteralPath $launcher.FullName -Raw
            $referenced = @([regex]::Matches($text, '%~dp0([^"]+\.ps1)'))
            Assert-Equal 1 $referenced.Count "$($launcher.Name) should run exactly one script."

            $relative = $referenced[0].Groups[1].Value -replace '\\', '/'
            Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $relative)) `
                "$($launcher.Name) runs $relative, which is not there."
        }
    }

    It 'opens the window on a thread WPF will accept' {
        # -STA is the whole reason these files exist rather than a bare .ps1.
        foreach ($name in @('Start-PtrUiSetup.cmd', 'Try-It-Safely.cmd')) {
            $text = Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw
            Assert-True ($text -match '-STA') "$name must pass -STA or WPF will refuse to start."
            Assert-True ($text -match '-ExecutionPolicy Bypass') "$name must not be blocked by execution policy."
        }
    }
}

Describe 'The folder box, without WPF' {
    <#
        The window cannot be opened off Windows, but most of what the folder box
        does is ordinary logic sitting in named functions. Lifting those out of
        the script by AST and running them against a stub $ui exercises the part
        that decides what the user sees, which is the part worth checking.
    #>

    function Get-WindowFunction {
        <#
            Returns the named functions as one scriptblock. Dot-source the result
            in the test itself — dot-sourcing in here would define them in this
            function's scope, which ends when it returns.
        #>
        param([string[]] $Name)

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $text = foreach ($wanted in $Name) {
            $found = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wanted
                    }, $true))
            Assert-Equal 1 $found.Count "Expected one $wanted in the window script."
            $found[0].Extent.Text
        }
        return [scriptblock]::Create($text -join [Environment]::NewLine)
    }

    It 'says what is in the folder, and only remembers folders that worked' {
        . (Get-WindowFunction @('Get-StartingFolder', 'Update-FolderStatus', 'Set-WowFolder'))

        $ui = @{ FolderBox = [pscustomobject]@{ Text = '' }; FolderStatus = [pscustomobject]@{ Text = '' } }
        $script:Installs = @()
        $script:WowFolder = ''
        function Invoke-Rescan {
            $script:Installs = @(Get-WowInstall -Path $script:WowFolder -SkipDefaultLocations)
            Update-FolderStatus
        }

        $root = New-FakeWowRoot -Parent $script:TestDrive
        $env:PTRSETUP_SETTINGS = Join-Path $script:TestDrive 'settings.json'
        try {
            Set-WowFolder $root
            Assert-True ($ui.FolderStatus.Text -match 'client\(s\) found') "Got: $($ui.FolderStatus.Text)"
            Assert-Equal $root (Get-PtrSetupSetting).WowFolder

            # A typo must not throw away the folder that was working.
            Set-WowFolder (Join-Path $script:TestDrive 'nope')
            Assert-True ($ui.FolderStatus.Text -match 'does not exist') "Got: $($ui.FolderStatus.Text)"
            Assert-Equal $root (Get-PtrSetupSetting).WowFolder

            # A real folder with no game in it is a different problem, and says so.
            Set-WowFolder $script:TestDrive
            Assert-True ($ui.FolderStatus.Text -match 'No game clients') "Got: $($ui.FolderStatus.Text)"

            # Explorer's "Copy as path" wraps the path in quotes.
            Set-WowFolder ('"' + $root + '"')
            Assert-Equal $root $ui.FolderBox.Text
            Assert-True ($ui.FolderStatus.Text -match 'client\(s\) found')

            # Next launch opens where it was left.
            Assert-Equal $root (Get-StartingFolder)
        }
        finally { $env:PTRSETUP_SETTINGS = $null }
    }

    It 'always opens on a folder, saved or detected or the usual one' {
        . (Get-WindowFunction @('Get-StartingFolder'))

        $env:PTRSETUP_SETTINGS = Join-Path $script:TestDrive 'settings.json'
        $env:PTRSETUP_EXTRA_ROOTS = Join-Path $script:TestDrive 'no-game-here'
        try {
            # Nothing saved and the override points at nothing, so this is either
            # whatever is really installed on the machine running the test, or the
            # conventional folder. Asserting the second outright would only hold on
            # a machine without the game — which is not a property worth having a
            # test depend on. What matters is that the box is never empty.
            $starting = Get-StartingFolder
            Assert-True ([bool]$starting) 'The folder box must never open empty.'

            $detected = Find-WowFolder
            $expected = if ($detected) { $detected } else { Get-WowDefaultRoot }
            Assert-Equal $expected $starting
        }
        finally {
            $env:PTRSETUP_SETTINGS = $null
            $env:PTRSETUP_EXTRA_ROOTS = $null
        }
    }

    It 'prefers a saved folder to anything it would otherwise detect' {
        . (Get-WindowFunction @('Get-StartingFolder'))

        $root = New-FakeWowRoot -Parent $script:TestDrive
        $env:PTRSETUP_SETTINGS = Join-Path $script:TestDrive 'settings.json'
        try {
            $null = Save-PtrSetupSetting -WowFolder $root
            # Even on a machine with the game installed somewhere conventional,
            # the folder the user last settled on is the one that comes back.
            Assert-Equal $root (Get-StartingFolder)
        }
        finally { $env:PTRSETUP_SETTINGS = $null }
    }
}

Describe 'What a change forces the window to re-plan' {
    <#
        The window keeps plans between refreshes and throws away only the ones a
        change could have altered, because re-planning copy_addons means walking
        the whole AddOns folder. That is safe exactly as long as the map is not
        missing anything, so the map is read out of the window script and checked
        against what the module actually does.
    #>

    function Get-InvalidationMap {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $assignment = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$script:Invalidates'
                }, $true))
        Assert-Equal 1 $assignment.Count 'Expected one $script:Invalidates in the window script.'
        return [scriptblock]::Create($assignment[0].Right.Extent.Text).Invoke()[0]
    }

    function Get-PlanFingerprint {
        # Content matters as well as the file list: turning AllowOutOfDate off
        # rewrites Config.wtf without changing which file gets written.
        param($Context)

        $out = @{}
        foreach ($step in (Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' })) {
            $out[$step.Id] = (@(New-PtrSetupStepPlan -Step $step -Context $Context) |
                    ForEach-Object { '{0}|{1}|{2}' -f $_.Kind, $_.Destination, $_.Content }) -join "`n"
        }
        return $out
    }

    It 'names a real step and a real option throughout' {
        $map = Get-InvalidationMap
        $stepIds = @((Get-PtrSetupStep).Id)
        $options = @((New-PtrSetupContext).Options.Keys)

        foreach ($change in $map.Keys) {
            foreach ($stepId in $map[$change]) {
                Assert-True ($stepIds -contains $stepId) "$change invalidates '$stepId', which is not a step."
            }
            if ($change -in @('account', 'character')) { continue }
            Assert-True ($options -contains $change) "'$change' is not an option, so it would clear everything anyway."
        }
    }

    It 'never misses a step that the change really affects' {
        $mockBuilder = Join-Path $repoRoot 'tools/New-MockWowFolder.ps1'
        $null = & $mockBuilder -Path $script:TestDrive -Force -Quiet
        $installs = @(Get-WowInstall -Path (Join-Path $script:TestDrive 'World of Warcraft') -SkipDefaultLocations)
        $map = Get-InvalidationMap

        # Each case is the change the window reports, and how to make it happen.
        $cases = @(
            @{ Change = 'character'; Do = { param($c) $c.Character = @() } }
            @{ Change = 'ReplaceAddOns'; Do = { param($c) $c.Options['ReplaceAddOns'] = $false } }
            @{ Change = 'IncludeMacrosBindings'; Do = { param($c) $c.Options['IncludeMacrosBindings'] = $false } }
            @{ Change = 'IncludeChatCache'; Do = { param($c) $c.Options['IncludeChatCache'] = $true } }
            @{ Change = 'AllowOutOfDate'; Do = { param($c) $c.Options['AllowOutOfDate'] = $false } }
        )

        foreach ($case in $cases) {
            $context = Initialize-PtrSetupContext -Install $installs
            $before = Get-PlanFingerprint -Context $context
            & $case.Do $context
            $after = Get-PlanFingerprint -Context $context

            $reallyChanged = @($after.Keys | Where-Object { $before[$_] -ne $after[$_] })
            $wouldClear = @($map[$case.Change])
            foreach ($stepId in $reallyChanged) {
                Assert-True ($wouldClear -contains $stepId) `
                    ("Changing $($case.Change) alters $stepId, but the window would keep its cached plan " +
                        'and show a stale file count.')
            }
        }
    }

    It 'clears everything for a change it does not know about' {
        # Overwrite is deliberately absent: it reaches several steps, and being
        # wrong here shows the user a stale plan.
        $map = Get-InvalidationMap
        Assert-True (-not $map.ContainsKey('Overwrite')) `
            'Overwrite affects several steps; leaving it out of the map is what makes it clear them all.'
    }
}

Describe 'Keeping cached plans honest' {

    It 'throws the cache away on any wholesale refresh' {
        # Update-All is reached after a rescan, an install change, an Apply and a
        # Restore. The last two have just written to the PTR folder, so a plan
        # kept across one would report work that is already done.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $updateAll = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-All'
                }, $true))
        Assert-Equal 1 $updateAll.Count
        Assert-True ($updateAll[0].Body.Extent.Text -match 'Reset-Plan') `
            'Update-All must clear the plan cache, or Apply and Restore leave stale file counts on screen.'
    }

    It 'is emptied only by Reset-Plan, or where it is first declared' {
        # One door out, so the invalidation map is the whole story. The initial
        # declaration is the exception: it runs before Reset-Plan is defined.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $emptying = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$script:Plans' -and
                    $node.Right.Extent.Text -replace '\s', '' -eq '@{}'
                }, $true))
        Assert-True ($emptying.Count -ge 1) 'Expected to find the cache being emptied somewhere.'

        foreach ($assignment in $emptying) {
            $enclosing = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Extent.StartOffset -le $assignment.Extent.StartOffset -and
                        $node.Extent.EndOffset -ge $assignment.Extent.EndOffset
                    }, $true))
            $names = @($enclosing | ForEach-Object { $_.Name })
            Assert-True ($names.Count -eq 0 -or $names -contains 'Reset-Plan') `
                ("The cache is emptied inside $($names -join '/') at line $($assignment.Extent.StartLineNumber). " +
                    'Everything that discards plans should go through Reset-Plan.')
        }
    }
}

Describe 'The background planner' {
    <#
        The timer and the dispatcher cannot be exercised off Windows, but the
        part that does the work can: the scriptblock the window sends to the
        worker is lifted out of the source and run in a real runspace, so a name
        the module does not export, or a typo, fails here rather than on someone's
        machine as a window that never finishes loading.
    #>

    function Get-WorkerScript {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $start = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-NextPlan'
                }, $true))
        Assert-Equal 1 $start.Count 'Expected one Start-NextPlan.'

        $added = @($start[0].FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'AddScript'
                }, $true))
        Assert-Equal 1 $added.Count 'Expected exactly one scriptblock to be sent to the worker.'
        return $added[0].Arguments[0].ScriptBlock.GetScriptBlock()
    }

    It 'sends a script that plans the same as planning here' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $context = New-FakeContext -Root $root
        $stepIds = @((Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' }).Id)

        $expected = @{}
        foreach ($id in $stepIds) {
            $expected[$id] = (@(New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id $id) -Context $context) |
                    ForEach-Object { '{0}|{1}|{2}' -f $_.Kind, $_.Destination, $_.Content }) -join "`n"
        }

        $modulePath = Join-Path $repoRoot 'Modules/PtrUiSetup/PtrUiSetup.psd1'
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        try {
            # The window imports the module into the runspace once, then reuses it.
            $loader = [powershell]::Create()
            $loader.Runspace = $runspace
            $null = $loader.AddScript('param($ModulePath) Import-Module $ModulePath -Force').AddArgument($modulePath)
            $null = $loader.Invoke()
            Assert-Equal 0 @($loader.Streams.Error).Count "The worker could not load the module: $($loader.Streams.Error)"
            $loader.Dispose()

            $worker = Get-WorkerScript
            foreach ($id in $stepIds) {
                $shell = [powershell]::Create()
                $shell.Runspace = $runspace
                $null = $shell.AddScript($worker)
                $null = $shell.AddArgument((ConvertTo-PtrSetupSnapshot -Context $context))
                $null = $shell.AddArgument($id)

                # The window polls this handle from a timer; here it is awaited.
                $handle = $shell.BeginInvoke()
                $result = $shell.EndInvoke($handle)
                Assert-Equal 0 @($shell.Streams.Error).Count "The worker reported: $($shell.Streams.Error)"

                $text = (@($result[0]) | ForEach-Object { '{0}|{1}|{2}' -f $_.Kind, $_.Destination, $_.Content }) -join "`n"
                $shell.Dispose()
                Assert-Equal $expected[$id] $text "$id planned differently on the worker."
            }
        }
        finally { $runspace.Dispose() }
    }

    It 'still plans when a worker cannot be had' {
        # A machine that will not give out runspaces should get a slow window,
        # not a broken one.
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-True ($text -match '\$script:AsyncBroken = \$true') 'A failed worker must be remembered, not retried forever.'

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $start = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-NextPlan'
                }, $true))[0]
        Assert-True ($start.Body.Extent.Text -match 'New-PtrSetupStepPlan') `
            'Start-NextPlan needs a synchronous path for when there is no worker.'
    }

    It 'ignores an answer to a question the user has moved on from' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $receive = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Receive-PlanRequest'
                }, $true))
        Assert-Equal 1 $receive.Count
        Assert-True ($receive[0].Body.Extent.Text -match '\$job\.Token -ne \$script:PlanToken') `
            'Results must be checked against the current token, or a slow answer overwrites a newer one.'
    }
}

Describe 'The step cards' {

    It 'does not quote the guide at the user' {
        # The card says what the step does; where the instruction came from is
        # documentation, not something to read while using the tool.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $newCard = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-StepCard'
                }, $true))
        Assert-Equal 1 $newCard.Count
        Assert-True ($newCard[0].Body.Extent.Text -notmatch 'SourceNote') `
            'SourceNote is the citation back to the written guide and does not belong on a card.'

        # It still exists on the step itself, for -ListSteps and the docs.
        foreach ($step in (Get-PtrSetupStep)) {
            Assert-True ([bool]$step.SourceNote) "$($step.Id) lost its SourceNote; the docs rely on it."
        }
    }

    It 'lets a step be ticked before its file count is known' {
        # Ticking chooses whether to run a step. Making that wait on a folder
        # walk is what made the tick boxes look broken.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $newCard = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-StepCard'
                }, $true))[0]

        Assert-True ($newCard.Body.Extent.Text -notmatch '\$check\.IsEnabled = \$false') `
            'A card must not start with its tick box switched off.'
        Assert-True ($newCard.Body.Extent.Text -match '\$check\.IsChecked = \$script:Selected\.Contains') `
            'A card should show what is already selected as soon as it is drawn.'
    }

    It 'asks for the cheap steps first' {
        # copy_addons is much the slowest; leaving it last means everything else
        # is answered while it is still going.
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $match = [regex]::Match($text, "\`$order = @\(([^)]+)\)", 'Singleline')
        Assert-True $match.Success 'Expected an explicit planning order.'
        $order = @([regex]::Matches($match.Groups[1].Value, "'([a-z_]+)'") | ForEach-Object { $_.Groups[1].Value })

        Assert-Equal 'copy_addons' $order[-1] 'The addon folder should be planned last.'
        foreach ($stepId in @((Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' }).Id)) {
            Assert-True ($order -contains $stepId) "$stepId is missing from the planning order, so it would sort first by accident."
        }
    }
}
