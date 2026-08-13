<#
.SYNOPSIS
    Everything that has to pass before a change is pushed.

.DESCRIPTION
    One command, so there is no list to remember and no step to skip. It runs the
    checks in the order that fails fastest, and stops at the first one that does.

        1. every file parses
        2. every file is UTF-8 with a byte-order mark, and the launchers are ASCII
        3. the test suite
        4. PSScriptAnalyzer, if it is installed

    Checks 1 and 2 are also tests, but they run first here because a file that
    does not parse makes the suite's own failure hard to read.

    CI runs this on Windows PowerShell 5.1 and on PowerShell 7, because the two
    disagree about enough to matter — see docs/ARCHITECTURE.md.

.PARAMETER SkipAnalyzer
    Do not run PSScriptAnalyzer even if it is available.

.EXAMPLE
    ./tools/Invoke-Gate.ps1
#>

[CmdletBinding()]
param([switch] $SkipAnalyzer)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failed = [System.Collections.Generic.List[string]]::new()

function Write-Step {
    param([string] $Name)
    Write-Host ''
    Write-Host "== $Name" -ForegroundColor Cyan
}

function Get-SourceFile {
    param([string[]] $Extension)
    $files = foreach ($extension in $Extension) {
        Get-ChildItem -LiteralPath $repoRoot -Filter "*.$extension" -File -Recurse |
            Where-Object { $_.FullName -notlike "*$([System.IO.Path]::DirectorySeparatorChar).git$([System.IO.Path]::DirectorySeparatorChar)*" }
    }
    return @($files)
}

# --- 1. everything parses --------------------------------------------------
Write-Step 'Parsing'
$parsed = 0
foreach ($file in (Get-SourceFile -Extension @('ps1', 'psm1', 'psd1'))) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if (@($errors).Count) {
        $failed.Add("$($file.Name) does not parse: $(@($errors)[0])")
    }
    $parsed++
}
Write-Host "   $parsed file(s)"

# --- 2. encoding -----------------------------------------------------------
Write-Step 'Encoding'
foreach ($file in (Get-SourceFile -Extension @('ps1', 'psm1', 'psd1', 'xaml'))) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasMark = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasMark) {
        $failed.Add("$($file.Name) has no UTF-8 byte-order mark; Windows PowerShell 5.1 will misread it.")
    }
}
foreach ($file in (Get-SourceFile -Extension @('cmd'))) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes | Where-Object { $_ -gt 127 }) {
        $failed.Add("$($file.Name) is not plain ASCII; cmd.exe renders it unpredictably.")
    }
}
Write-Host '   sources marked, launchers ASCII'

if ($failed.Count) {
    Write-Host ''
    Write-Host 'GATE FAILED' -ForegroundColor Red
    foreach ($problem in $failed) { Write-Host "  - $problem" -ForegroundColor Red }
    exit 1
}

# --- 3. the suite ----------------------------------------------------------
Write-Step 'Tests'
& (Join-Path $repoRoot 'tests/Invoke-Tests.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'GATE FAILED — the test suite did not pass.' -ForegroundColor Red
    exit 1
}

# --- 4. the analyser, when it is to be had ---------------------------------
Write-Step 'PSScriptAnalyzer'
if ($SkipAnalyzer) {
    Write-Host '   skipped'
}
elseif (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    # Not installed is not a failure: the Gallery is unreachable from plenty of
    # places, and the suite is the part that must always run.
    Write-Host '   not installed, skipped'
}
else {
    Import-Module PSScriptAnalyzer
    $found = @(Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Severity Error)
    if ($found.Count) {
        $found | Format-Table -AutoSize RuleName, ScriptName, Line, Message
        Write-Host ''
        Write-Host "GATE FAILED — PSScriptAnalyzer reported $($found.Count) error(s)." -ForegroundColor Red
        exit 1
    }
    Write-Host '   no errors'
}

Write-Host ''
Write-Host 'GATE PASSED' -ForegroundColor Green
exit 0
