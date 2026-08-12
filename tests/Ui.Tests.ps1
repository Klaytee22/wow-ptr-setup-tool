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
                'SourceInstallCombo', 'TargetInstallCombo', 'RescanButton', 'BrowseButton', 'InstallWarning',
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

    It 'keeps the step ids in the module and the launcher in step' {
        # -ListSteps is the console path through the same registry the window renders.
        $ids = @((Get-PtrSetupStep).Id)
        Assert-True ($ids -contains 'copy_addons')
        Assert-Equal 8 $ids.Count
        Assert-Equal @($ids | Sort-Object -Unique).Count $ids.Count 'Step ids must be unique.'
    }
}
