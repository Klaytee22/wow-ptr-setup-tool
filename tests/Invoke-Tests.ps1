<#
.SYNOPSIS
    Runs the whole suite. No external modules required.

.EXAMPLE
    pwsh -File tests/Invoke-Tests.ps1
#>

[CmdletBinding()]
param([string] $Filter = '*')

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $here 'TestRunner.ps1')

Import-Module (Join-Path (Split-Path -Parent $here) 'Modules/PtrUiSetup/PtrUiSetup.psd1') -Force
. (Join-Path $here 'TestHelpers.ps1')

Reset-TestState
$files = @(Get-ChildItem -LiteralPath $here -Filter '*.Tests.ps1' | Sort-Object Name)
foreach ($file in $files) {
    if ($file.BaseName -notlike $Filter) { continue }
    Write-Host ''
    Write-Host $file.Name -ForegroundColor White
    . $file.FullName
}

$state = Get-TestState
Write-Host ''
Write-Host ('-' * 60)
if ($state.Failed -gt 0) {
    Write-Host "FAILED — $($state.Passed) passed, $($state.Failed) failed" -ForegroundColor Red
    foreach ($failure in $state.Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "OK — $($state.Passed) passed" -ForegroundColor Green
exit 0
