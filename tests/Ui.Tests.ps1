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
    [xml] $document = Get-Content -LiteralPath $Path -Raw
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
        [xml] $document = Get-Content -LiteralPath $xamlPath -Raw
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
        [xml] $document = Get-Content -LiteralPath $xamlPath -Raw
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

    It 'falls back to a real folder to show when nothing is installed' {
        . (Get-WindowFunction @('Get-StartingFolder'))

        $env:PTRSETUP_SETTINGS = Join-Path $script:TestDrive 'settings.json'
        $env:PTRSETUP_EXTRA_ROOTS = Join-Path $script:TestDrive 'no-game-here'
        try {
            # No saved folder, nothing detected: the box still opens on something
            # the user can recognise and correct rather than an empty field.
            Assert-Equal (Get-WowDefaultRoot) (Get-StartingFolder)
        }
        finally {
            $env:PTRSETUP_SETTINGS = $null
            $env:PTRSETUP_EXTRA_ROOTS = $null
        }
    }
}
