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
                'MacrosOption', 'ProfileKeysOption', 'LibraryPatchOption',
                'BackupCombo', 'RefreshBackupsButton', 'RestoreButton', 'ClearBackupsButton',
                'ResultsBox', 'SummaryText', 'ProgressBar', 'ApplyButton')) {
            Assert-True ($defined -contains $required) "The XAML is missing $required."
        }
    }

    It 'notices at startup when the layout on disk does not match the script' {
        # The static check above holds the repo together. This is the same check
        # run at launch against whatever pair of files the user actually has,
        # because the failure that reaches them is a half-updated working copy:
        # the script wants a control the XAML has not got, and the property set
        # on $null aborts whichever handler it lands in. Landing in the startup
        # scan leaves the folder box filled in and the client dropdowns empty.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $function = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Get-MissingControl'
                }, $true))
        Assert-Equal 1 $function.Count 'Expected one Get-MissingControl in the window script.'
        . ([scriptblock]::Create($function[0].Extent.Text))

        # A complete set of controls is clean.
        $complete = @{}
        foreach ($name in (Get-XamlName -Path $xamlPath)) { $complete[$name] = [pscustomobject]@{ Name = $name } }
        Assert-Equal 0 @(Get-MissingControl -Control $complete -ScriptPath $scriptPath).Count `
            'The real XAML should satisfy the real script.'

        # A stale layout is caught, whether the name is absent or resolved to null.
        $stale = @{}
        foreach ($name in $complete.Keys) { $stale[$name] = $complete[$name] }
        $stale.Remove('ProfileKeysOption')
        Assert-Equal @('ProfileKeysOption') @(Get-MissingControl -Control $stale -ScriptPath $scriptPath)

        $nulled = @{}
        foreach ($name in $complete.Keys) { $nulled[$name] = $complete[$name] }
        $nulled['StepsPanel'] = $null
        Assert-Equal @('StepsPanel') @(Get-MissingControl -Control $nulled -ScriptPath $scriptPath)
    }

    It 'draws each panel independently, so one failure cannot blank the rest' {
        # Update-All used to be a straight run of seven calls. The first one to
        # throw stopped the other six, so a broken step card emptied the client
        # dropdowns as well and the tool looked like it had not found the game.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $function = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Update-All'
                }, $true))
        Assert-Equal 1 $function.Count 'Expected one Update-All in the window script.'

        $body = $function[0].Extent.Text
        foreach ($panel in @('Update-FolderStatus', 'Update-InstallCombos', 'Update-AccountCombos',
                'Update-CharacterPanel', 'Update-Steps', 'Update-Summary', 'Update-Backups')) {
            Assert-True ($body -match [regex]::Escape($panel)) "Update-All no longer draws $panel."
        }

        # Checking that the word appears is not enough — it did, while the line
        # that actually broke the window sat above the loop, unguarded. So: every
        # command in here has to be lexically inside one of the guarded blocks.
        # Invoke-Guarded itself is the exception, being the thing doing the
        # guarding, and so is anything the loop is built from.
        $allowed = @('Invoke-Guarded', 'ForEach-Object', 'Where-Object')
        $offences = [System.Collections.Generic.List[string]]::new()
        foreach ($command in $function[0].FindAll({
                    param($node) $node -is [System.Management.Automation.Language.CommandAst]
                }, $true)) {

            $name = $command.GetCommandName()
            if (-not $name -or $allowed -contains $name) { continue }

            # Walk up: inside a scriptblock literal means inside a guarded part.
            $guarded = $false
            $parent = $command.Parent
            while ($parent -and $parent -ne $function[0]) {
                if ($parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $guarded = $true
                    break
                }
                $parent = $parent.Parent
            }
            if (-not $guarded) {
                $offences.Add(("line {0}: {1}" -f $command.Extent.StartLineNumber, $command.Extent.Text))
            }
        }

        Assert-Equal 0 $offences.Count ("Update-All runs something outside the guarded loop, so it can still take " +
            "the whole redraw down with it:`n  " + ($offences -join "`n  "))
    }

    It 'lays the character mapping out in the direction the copy goes' {
        # Live on the left, PTR on the right, matching the account dropdowns in
        # the same section. Getting these the wrong way round is invisible to
        # every other test and obvious to anyone looking at the window.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $function = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Update-CharacterPanel'
                }, $true))
        Assert-Equal 1 $function.Count 'Expected one Update-CharacterPanel in the window script.'
        $body = $function[0].Extent.Text

        Assert-True ($body -match "\`$left = New-TextBlockControl -Text 'LIVE CHARACTER'") `
            'The left column should be the live character.'
        Assert-True ($body -match "\`$right = New-TextBlockControl -Text 'COPIES ONTO'") `
            'The right column should be where it copies to.'
        # Matched against the assignment, not the bare words: -match is
        # case-insensitive, so the comment above the labels explaining why they
        # changed was enough to fail this.
        Assert-True ($body -notmatch "New-TextBlockControl -Text 'GETS SETTINGS FROM'") `
            'The old label describes the wrong end of the arrow now the columns have swapped.'

        # The PTR name block goes in column 1; the live combo takes column 0 by
        # not being moved at all, which is exactly the kind of thing that gets
        # undone by accident.
        Assert-True ($body -match '::SetColumn\(\$stack, 1\)') `
            'The PTR character block should sit in the right-hand column.'
        Assert-True ($body -notmatch '::SetColumn\(\$combo') `
            'The live combo should be left in column 0, not moved to the right.'

        # The header label and the row content take the same gutter from one
        # variable. Written out twice they drift, and a header sitting a few
        # pixels off its column is the kind of thing nobody reports and everyone
        # notices.
        Assert-True ($body -match '\$right\.Margin = \$gutter') 'The header label should take the shared gutter.'
        Assert-True ($body -match '\$stack\.Margin = \$gutter') 'The row content should take the same gutter.'
        Assert-Equal 1 ([regex]::Matches($body, '\$gutter = New-Object').Count) `
            'The gutter should be worked out once, not once per column.'
    }

    It 'keeps section 4 to options that visibly do something' {
        # Every checkbox here changes what a run writes. Two did not: unticking
        # Overwrite turned most of the tool into a no-op and read as a fault,
        # and the chat cache is one file nobody sets a PTR up for. A window full
        # of switches that appear to do nothing is worse than a smaller one.
        $defined = @(Get-XamlName -Path $xamlPath | Where-Object { $_ -like '*Option' })
        Assert-Equal 4 $defined.Count ("Section 4 has grown to $($defined.Count) checkboxes: " + ($defined -join ', '))
        foreach ($gone in @('OverwriteOption', 'ChatOption', 'OutOfDateOption', 'MacroNameOption')) {
            Assert-True ($defined -notcontains $gone) "$gone came back — it was removed for saying nothing new."
        }
    }

    It 'connects every option checkbox to an option that exists' {
        # Three files have to agree for a checkbox to do anything: the XAML names
        # it, $optionMap says which option it sets, and the context has to have
        # that option. Miss the middle one and the box is inert — it ticks and
        # nothing happens, which is what it looked like the last time this broke.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $assignment = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$optionMap'
                }, $true))
        Assert-Equal 1 $assignment.Count 'Expected one $optionMap in the window script.'
        $map = [scriptblock]::Create($assignment[0].Right.Extent.Text).Invoke()[0]

        $defined = @(Get-XamlName -Path $xamlPath | Where-Object { $_ -like '*Option' })
        $options = @((New-PtrSetupContext).Options.Keys)
        $script = Get-Content -LiteralPath $scriptPath -Raw

        foreach ($control in $defined) {
            Assert-True ($map.ContainsKey($control)) "$control is a checkbox in the XAML that no option is wired to."
        }
        foreach ($control in $map.Keys) {
            Assert-True ($defined -contains $control) "`$optionMap names $control, which the XAML does not define."
            Assert-True ($options -contains $map[$control]) "$control sets '$($map[$control])', which is not a context option."
            # And the box has to be filled in from the context, or it shows the
            # XAML's default rather than the setting in force.
            Assert-True ($script -match [regex]::Escape("`$ui.$control.IsChecked = ")) `
                "$control is never set from the context, so it will not show the option's real state."
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

    It 'puts a version in the crash log, and never throws getting it' {
        # The log is what places a report against a build, so the version has to
        # be in it — and it is read inside the trap that writes that log, where
        # throwing would lose the report it is in the middle of writing.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $function = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Get-ToolVersion'
                }, $true))
        Assert-Equal 1 $function.Count 'Expected one Get-ToolVersion.'
        . ([scriptblock]::Create($function[0].Extent.Text))

        # The real manifest, read the way the window reads it.
        $manifest = Join-Path $repoRoot 'Modules/PtrUiSetup/PtrUiSetup.psd1'
        $expected = [string](Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion
        Assert-True ([bool]$expected) 'The manifest should carry a ModuleVersion.'
        Assert-Equal $expected (Get-ToolVersion -Root $repoRoot)

        # A folder with no manifest in it says so, rather than just "unknown".
        # That is the half-extracted zip — somebody ran the launcher out of a
        # folder that never got the rest of the files — and it is worth telling
        # apart from a manifest that is there and will not read.
        $empty = Join-Path $script:TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $empty -Force
        Assert-Equal 'unknown (manifest missing)' (Get-ToolVersion -Root $empty)

        # And nothing here may throw, whatever it is pointed at.
        foreach ($root in @((Join-Path $script:TestDrive 'nope'), '', $null)) {
            $answer = Get-ToolVersion -Root $root
            Assert-True ([bool]$answer) "Get-ToolVersion returned nothing for '$root'."
            Assert-True ($answer -like 'unknown*') "Expected 'unknown' for '$root', got '$answer'."
        }

        # And the trap actually records it.
        $trap = @($ast.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.TrapStatementAst]
                }, $true))
        Assert-Equal 1 $trap.Count 'Expected one trap around startup.'
        Assert-True ($trap[0].Extent.Text -match 'Get-ToolVersion') `
            'The crash log needs the version in it, or a report cannot be placed against a build.'
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
        Assert-Equal 11 $ids.Count
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
        Assert-True ($launchers.Count -ge 2) "Expected the launchers, found $($launchers.Count)."

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
        # Worked out from what each launcher runs rather than from a list of
        # names, so adding or dropping one cannot leave this checking a file
        # that is no longer there — or quietly not checking a new one.
        $opensWindow = 0
        foreach ($launcher in (Get-ChildItem -LiteralPath $repoRoot -Filter '*.cmd' -File)) {
            $text = Get-Content -LiteralPath $launcher.FullName -Raw
            Assert-True ($text -match '-ExecutionPolicy Bypass') `
                "$($launcher.Name) must not be blocked by execution policy."
            if ($text -notmatch 'PtrUiSetup\.ps1') { continue }
            $opensWindow++
            Assert-True ($text -match '-STA') "$($launcher.Name) must pass -STA or WPF will refuse to start."
        }
        Assert-True ($opensWindow -ge 1) 'No launcher opens the window at all.'
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

                $text = (@($result) | ForEach-Object { '{0}|{1}|{2}' -f $_.Kind, $_.Destination, $_.Content }) -join "`n"
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

Describe 'The planning queue' {
    <#
        Driven by hand here: the dispatcher timer cannot run off Windows, but
        every decision it makes can. This is the loop that got stuck on "working
        out what needs copying" with Apply disabled and no way forward.
    #>

    function Use-Planner {
        <#
            The planner functions from the window, with WPF replaced by objects
            that record what was set. Returns the stub $ui so a test can read it.
        #>
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $wanted = @('Get-PlanWorker', 'Stop-PlanRequest', 'Clear-AbandonedRequest', 'Start-PlanRequest',
            'Start-PlanTimer', 'Start-NextPlan', 'Update-PlanProgress', 'Receive-PlanRequest',
            'Complete-Planning', 'Write-StepCardState', 'Update-Summary', 'Invoke-Guarded', 'Write-Result')
        $text = foreach ($name in $wanted) {
            $found = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                    }, $true))
            Assert-Equal 1 $found.Count "Expected one $name in the window script."
            $found[0].Extent.Text
        }
        return [scriptblock]::Create($text -join [Environment]::NewLine)
    }

    It 'drains the queue and lights up Apply' {
        . (Use-Planner)

        $control = { [pscustomobject]@{ Text = ''; Value = 0; IsIndeterminate = $false; IsEnabled = $false } }
        $ui = @{ ResultsBox = [pscustomobject]@{ Lines = '' }; ProgressBar = (& $control)
            SummaryText = (& $control); PreviewButton = (& $control); ApplyButton = (& $control)
        }
        Add-Member -InputObject $ui.ResultsBox -MemberType ScriptMethod -Name AppendText -Value { param($t) $this.Lines += $t } -Force
        Add-Member -InputObject $ui.ResultsBox -MemberType ScriptMethod -Name ScrollToEnd -Value { } -Force
        function Set-StepCardState { param($Card, $Step, $Status, $Actions) }

        $script:ModulePath = Join-Path $repoRoot 'Modules/PtrUiSetup/PtrUiSetup.psd1'
        $script:Plans = @{}
        $script:Cards = @{}
        $script:Abandoned = [System.Collections.Generic.List[psobject]]::new()
        $script:Worker = $null; $script:PlanJob = $null; $script:PlanToken = 0
        $script:PlanQueue = $null; $script:PlanTotal = 0; $script:PlanDone = 0
        $script:PlanWaits = 0
        $script:AsyncBroken = $false
        $script:Selected = [System.Collections.Generic.HashSet[string]]::new()
        $script:PlanTimer = [pscustomobject]@{ Started = $false }
        Add-Member -InputObject $script:PlanTimer -MemberType ScriptMethod -Name Start -Value { $this.Started = $true } -Force
        Add-Member -InputObject $script:PlanTimer -MemberType ScriptMethod -Name Stop -Value { $this.Started = $false } -Force

        $root = New-FakeWowRoot -Parent $script:TestDrive
        $script:Context = New-FakeContext -Root $root
        $autoIds = @((Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' }).Id)
        foreach ($step in (Get-PtrSetupStep)) { $script:Cards[$step.Id] = @{} }
        foreach ($id in $autoIds) { $null = $script:Selected.Add($id) }

        Start-PlanRequest -StepId $autoIds

        # Stand in for the dispatcher pumping the timer.
        $spins = 0
        while ($script:PlanTimer.Started -and $spins -lt 600) {
            Start-Sleep -Milliseconds 20
            Receive-PlanRequest
            $spins++
        }

        Assert-True ($spins -lt 600) 'The queue never drained.'
        foreach ($id in $autoIds) {
            Assert-True ($script:Plans.ContainsKey($id)) "$id was left pending, so the summary would wait on it forever."
        }
        Assert-True ($ui.SummaryText.Text -notmatch 'Working out') "Left on: $($ui.SummaryText.Text)"
        Assert-True $ui.ApplyButton.IsEnabled 'Apply should be usable once every selected step has a plan.'
        Assert-True ($ui.ResultsBox.Lines -notmatch '\[fail\]') "The planner reported: $($ui.ResultsBox.Lines)"
    }

    It 'waits for the worker instead of colliding with a request that is still stopping' {
        <#
            Stop-PlanRequest calls BeginStop and returns; the pipeline can still
            be winding down after it. Sending the next step to the same runspace
            at that moment is what produced "[fail] Could not work out
            <step>: ... the pipeline was not run because a pipeline is already
            running" — a message about pipelines against a step the user had
            done nothing to.

            A real runspace, genuinely held busy, so this is the runspace's own
            idea of busy rather than a stand-in for it.
        #>
        . (Use-Planner)

        $control = { [pscustomobject]@{ Text = ''; Value = 0; IsIndeterminate = $false; IsEnabled = $false } }
        $ui = @{ ResultsBox = [pscustomobject]@{ Lines = '' }; ProgressBar = (& $control)
            SummaryText = (& $control); PreviewButton = (& $control); ApplyButton = (& $control)
        }
        Add-Member -InputObject $ui.ResultsBox -MemberType ScriptMethod -Name AppendText -Value { param($t) $this.Lines += $t } -Force
        Add-Member -InputObject $ui.ResultsBox -MemberType ScriptMethod -Name ScrollToEnd -Value { } -Force
        function Set-StepCardState { param($Card, $Step, $Status, $Actions) }

        $script:ModulePath = Join-Path $repoRoot 'Modules/PtrUiSetup/PtrUiSetup.psd1'
        $script:Plans = @{}
        $script:Cards = @{}
        $script:Abandoned = [System.Collections.Generic.List[psobject]]::new()
        $script:PlanJob = $null; $script:PlanToken = 0
        $script:PlanTotal = 1; $script:PlanDone = 0; $script:PlanWaits = 0
        $script:AsyncBroken = $false
        $script:Selected = [System.Collections.Generic.HashSet[string]]::new()
        $script:PlanTimer = [pscustomobject]@{ Started = $false }
        Add-Member -InputObject $script:PlanTimer -MemberType ScriptMethod -Name Start -Value { $this.Started = $true } -Force
        Add-Member -InputObject $script:PlanTimer -MemberType ScriptMethod -Name Stop -Value { $this.Started = $false } -Force

        $root = New-FakeWowRoot -Parent $script:TestDrive
        $script:Context = New-FakeContext -Root $root
        $stepId = @((Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' }).Id)[0]
        foreach ($step in (Get-PtrSetupStep)) { $script:Cards[$step.Id] = @{} }

        # The worker the window would already be holding, loaded the same way.
        $script:Worker = [runspacefactory]::CreateRunspace()
        $script:Worker.ThreadOptions = 'ReuseThread'
        $script:Worker.Open()
        $loader = [powershell]::Create()
        $loader.Runspace = $script:Worker
        $null = $loader.AddScript('param($ModulePath) Import-Module $ModulePath -Force').AddArgument($script:ModulePath)
        $null = $loader.Invoke()
        Assert-Equal 0 @($loader.Streams.Error).Count "The worker could not load the module: $($loader.Streams.Error)"
        $loader.Dispose()

        $gate = [hashtable]::Synchronized(@{ Started = $false; Stop = $false })
        $busy = [powershell]::Create()
        $busy.Runspace = $script:Worker
        $null = $busy.AddScript({
                param($Gate)
                $Gate['Started'] = $true
                while (-not $Gate['Stop']) { Start-Sleep -Milliseconds 10 }
            }).AddArgument($gate)
        $busyHandle = $busy.BeginInvoke()

        try {
            $waited = 0
            while (-not $gate['Started'] -and $waited -lt 500) { Start-Sleep -Milliseconds 10; $waited++ }
            Assert-True $gate['Started'] 'The worker never got busy, so this proves nothing.'

            $script:PlanQueue = [System.Collections.Generic.Queue[string]]::new()
            $script:PlanQueue.Enqueue($stepId)

            Start-NextPlan

            Assert-True ($null -eq $script:PlanJob) 'A plan must not be sent to a runspace that is still busy.'
            Assert-Equal 1 $script:PlanQueue.Count 'The step has to stay on the queue to be sent later.'
            Assert-True $script:PlanTimer.Started 'Without the tick, a deferred step would never start.'

            # A tick with nothing in flight has to drive the queue on, not decide
            # planning is finished and stop.
            $before = $script:PlanWaits
            Receive-PlanRequest
            Assert-True ($script:PlanWaits -gt $before) 'The tick must retry a step that is waiting for the worker.'
            Assert-Equal 1 $script:PlanQueue.Count 'It is still busy, so the step should still be waiting.'
        }
        finally {
            $gate['Stop'] = $true
            try { $null = $busy.EndInvoke($busyHandle) } catch { <# stopping is enough #> }
            $busy.Dispose()
        }

        try {
            $waited = 0
            while ($script:Worker.RunspaceAvailability -ne 'Available' -and $waited -lt 500) {
                Start-Sleep -Milliseconds 10; $waited++
            }
            Assert-Equal 'Available' ([string]$script:Worker.RunspaceAvailability) 'The worker never came free.'

            # Free now, so the next tick sends it.
            Receive-PlanRequest
            Assert-True ($null -ne $script:PlanJob) 'Once the worker is free the waiting step should go out.'
            Assert-Equal 0 $script:PlanQueue.Count

            $spins = 0
            while ($script:PlanTimer.Started -and $spins -lt 600) {
                Start-Sleep -Milliseconds 20
                Receive-PlanRequest
                $spins++
            }
            Assert-True ($spins -lt 600) 'The queue never drained.'
            Assert-True ($script:Plans.ContainsKey($stepId)) "$stepId was left pending."
            Assert-True ($ui.ResultsBox.Lines -notmatch 'pipeline') "The planner reported: $($ui.ResultsBox.Lines)"
        }
        finally { $script:Worker.Dispose(); $script:Worker = $null }
    }
}

Describe 'Watching the folders' {
    <#
        Launching the PTR, copying a character and quitting the game all used to
        need a press of Rescan. The window polls a cheap fingerprint instead, so
        the button is a fallback rather than the way the tool is used.
    #>

    It 'starts watching once the first scan is done' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-True ($text -match 'Start-Watching') 'The window should start watching.'
        Assert-True ($text -match 'Get-WowFolderFingerprint') 'It should be watching by fingerprint, not by rescanning.'
    }

    It 'holds off while a run or a plan is under way' {
        # Refreshing on top of a copy, or restarting planning every few seconds,
        # would be worse than not watching at all.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $onChange = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-OnChange'
                }, $true))
        Assert-Equal 1 $onChange.Count
        $body = $onChange[0].Body.Extent.Text
        Assert-True ($body -match '\$script:Running') 'It must not refresh during an Apply.'
        Assert-True ($body -match '\$script:PlanJob') 'It must not refresh on top of planning already going.'
        Assert-True ($body -match '\$now -eq \$script:Fingerprint') 'It must only act when something actually changed.'
    }

    It 'does not redo a mapping the user arranged themselves' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $update = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Update-CharacterPanelIfChanged'
                }, $true))
        Assert-Equal 1 $update.Count
        Assert-True ($update[0].Body.Extent.Text -match '\$script:MappingTouched') `
            'A character copied later should not undo choices already made.'

        $sync = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sync-CharacterMap'
                }, $true))
        Assert-True ($sync[0].Body.Extent.Text -match '\$script:MappingTouched = \$true') `
            'Editing the mapping is what marks it as the user''s.'
    }

    It 'tells the user it is watching, and keeps Rescan for when it is not enough' {
        $defined = Get-XamlName -Path $xamlPath
        Assert-True ($defined -contains 'WatchStatus') 'The window should say that it is watching.'
        Assert-True ($defined -contains 'RescanButton') 'Rescan stays, as the way to re-read everything.'
    }
}

Describe 'Applying on the worker' {
    <#
        Applying used to run on the UI thread. Copying pumps the window between
        files, but validating the batch, copying every replaced file into the
        backup and writing the manifest do not — long enough on a real install
        for Windows to grey the window out. It runs on the background runspace
        now, and this drives the actual scriptblock the window sends.
    #>

    function Get-RunScript {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $run = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Run'
                }, $true))
        Assert-Equal 1 $run.Count
        $added = @($run[0].FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'AddScript'
                }, $true))
        Assert-Equal 1 $added.Count 'Expected exactly one scriptblock to be sent to the worker.'
        return $added[0].Arguments[0].ScriptBlock.GetScriptBlock()
    }

    It 'copies the files and reports its progress' {
        $mockBuilder = Join-Path $repoRoot 'tools/New-MockWowFolder.ps1'
        $null = & $mockBuilder -Path $script:TestDrive -Force -Quiet
        $installs = @(Get-WowInstall -Path (Join-Path $script:TestDrive 'World of Warcraft') -SkipDefaultLocations)
        $context = Initialize-PtrSetupContext -Install $installs
        $autoIds = @((Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' }).Id)

        $progress = [hashtable]::Synchronized(@{ Title = ''; Index = 0; Total = 0; Done = 0; Files = 0 })
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        try {
            $loader = [powershell]::Create()
            $loader.Runspace = $runspace
            $null = $loader.AddScript('param($ModulePath) Import-Module $ModulePath -Force').AddArgument(
                (Join-Path $repoRoot 'Modules/PtrUiSetup/PtrUiSetup.psd1'))
            $null = $loader.Invoke()
            Assert-Equal 0 @($loader.Streams.Error).Count "The worker could not load the module: $($loader.Streams.Error)"
            $loader.Dispose()

            $shell = [powershell]::Create()
            $shell.Runspace = $runspace
            $null = $shell.AddScript((Get-RunScript))
            $null = $shell.AddArgument((ConvertTo-PtrSetupSnapshot -Context $context))
            $null = $shell.AddArgument($autoIds)
            $null = $shell.AddArgument($progress)

            $results = @($shell.EndInvoke($shell.BeginInvoke()))
            Assert-Equal 0 @($shell.Streams.Error).Count "The worker reported: $($shell.Streams.Error)"
            $shell.Dispose()

            Assert-Equal $autoIds.Count $results.Count 'Every step should come back with a result.'
            foreach ($result in $results) {
                Assert-True $result.Ok "$($result.Title) failed on the worker: $($result.Message)"
                Assert-True ([bool]$result.Title) 'A result needs a title to show.'
            }

            # The progress table is what the window's bar is driven from.
            Assert-Equal $autoIds.Count $progress['Total']
            Assert-True ($progress['Index'] -ge $autoIds.Count - 1) 'It should have got to the last step.'
            Assert-True ([bool]$progress['Title']) 'The bar needs the step name to show alongside it.'

            # And the copy really happened, on the worker thread.
            $ptrAddons = @(Get-ChildItem -LiteralPath $context.Target.AddOns -Directory).Name | Sort-Object
            Assert-Equal @('Bartender4', 'Details', 'Plater', 'Questie', 'WeakAuras') $ptrAddons
            $config = Read-ConfigWtf -Path $context.Target.ConfigWtf
            Assert-Equal 'us.logon-ptr.worldofwarcraft.com' $config['realmList']
            Assert-Equal '0' $config['checkAddonVersion']
        }
        finally { $runspace.Dispose() }
    }

    It 'keeps a fallback for when there is no worker' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-True ($text -match 'Invoke-RunHere') 'A machine that will not give a runspace should still be able to apply.'
        Assert-True ($text -match 'function Complete-Run') 'Both paths must put the window back together the same way.'
    }
}

Describe 'One runspace each, so a plan and a run cannot collide' {
    <#
        A runspace runs one pipeline at a time. With a single worker shared
        between the planner and Apply, a plan still in flight when Apply started
        made the run fail with "the pipeline was not run because a pipeline is
        already running" — reported against whichever step happened to be first,
        which told the user nothing.

        Both halves are checked: that the two accessors really do hand back
        different runspaces, driven for real here, and that the run path asks
        the right one for it.
    #>

    function New-WorkerHarness {
        <#
            The three functions lifted out of the window and given somewhere to
            live: they touch runspaces and $script: state and nothing of WPF, so
            they run anywhere PowerShell does.
        #>
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $source = foreach ($name in @('New-LoadedRunspace', 'Get-PlanWorker', 'Get-RunWorker')) {
            $found = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                    }, $true))
            Assert-Equal 1 $found.Count "Expected exactly one $name."
            $found[0].Extent.Text
        }

        $body = [scriptblock]::Create(@"
param(`$ModulePath)
Set-StrictMode -Version Latest
`$script:ModulePath = `$ModulePath
`$script:AsyncBroken = `$false
`$script:Worker = `$null
`$script:RunWorker = `$null
function Write-Result { param([Parameter(Position = 0)] [string] `$Text) }
$($source -join "`n`n")
"@)
        return (New-Module -ScriptBlock $body -ArgumentList (Join-Path $repoRoot 'Modules/PtrUiSetup/PtrUiSetup.psd1'))
    }

    It 'hands the planner and the run different runspaces' {
        $harness = New-WorkerHarness
        $plan = & $harness { Get-PlanWorker }
        $run = & $harness { Get-RunWorker }
        try {
            Assert-True ($null -ne $plan) 'The planner should get a runspace.'
            Assert-True ($null -ne $run) 'The run should get a runspace.'
            Assert-True ($plan.InstanceId -ne $run.InstanceId) `
                'Sharing one runspace is what made a run fail with "a pipeline is already running".'

            # Asked again, each keeps the one it already has rather than opening
            # a fresh one per request.
            Assert-Equal $plan.InstanceId (& $harness { Get-PlanWorker }).InstanceId
            Assert-Equal $run.InstanceId (& $harness { Get-RunWorker }).InstanceId

            # And the thing the user actually hit: a plan still going while
            # Apply starts. The gate holds the plan open rather than sleeping a
            # fixed time, so the run really does begin mid-plan.
            $gate = [hashtable]::Synchronized(@{ Started = $false; Stop = $false })
            $planShell = [powershell]::Create()
            $planShell.Runspace = $plan
            $null = $planShell.AddScript({
                    param($Gate)
                    $Gate['Started'] = $true
                    while (-not $Gate['Stop']) { Start-Sleep -Milliseconds 10 }
                }).AddArgument($gate)
            $planHandle = $planShell.BeginInvoke()

            try {
                $waited = 0
                while (-not $gate['Started'] -and $waited -lt 500) { Start-Sleep -Milliseconds 10; $waited++ }
                Assert-True $gate['Started'] 'The plan never got going, so this proves nothing.'

                $runShell = [powershell]::Create()
                $runShell.Runspace = $run
                $null = $runShell.AddScript('42')
                $answer = @($runShell.EndInvoke($runShell.BeginInvoke()))
                $runShell.Dispose()
                Assert-Equal 42 $answer[0] 'A run must go through with a plan still in flight.'
            }
            finally {
                $gate['Stop'] = $true
                try { $null = $planShell.EndInvoke($planHandle) } catch { <# stopping is enough #> }
                $planShell.Dispose()
            }
        }
        finally {
            foreach ($runspace in @($plan, $run)) {
                if ($runspace) { try { $runspace.Dispose() } catch { <# already gone #> } }
            }
        }
    }

    It 'asks for its own runspace on each path' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $accessors = @('Get-PlanWorker', 'Get-RunWorker')

        $asked = @{}
        foreach ($name in @('Start-NextPlan', 'Invoke-Run')) {
            $found = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                    }, $true))
            Assert-Equal 1 $found.Count "Expected exactly one $name."

            $called = @($found[0].FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true) | ForEach-Object { $_.GetCommandName() } |
                    Where-Object { $accessors -contains $_ } | Sort-Object -Unique)
            Assert-Equal 1 $called.Count "$name should ask for exactly one worker, not $($called.Count)."
            $asked[$name] = $called[0]
        }

        Assert-True ($asked['Start-NextPlan'] -cne $asked['Invoke-Run']) `
            'The planner and the run must not fetch the same runspace, or their pipelines collide.'
    }
}
