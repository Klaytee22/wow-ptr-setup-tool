<#
.SYNOPSIS
    A tiny Describe/It test harness with no external dependencies.

.DESCRIPTION
    Pester would be the obvious choice, but requiring it means every contributor
    (and CI) needs PowerShell Gallery access before they can run the suite. The
    suite is worth more than the framework, so this file supplies the handful of
    things the tests actually use: Describe, It, and four assertions.

    Dot-source it from Invoke-Tests.ps1; do not run it directly.
#>

$script:TestState = [pscustomobject]@{
    Passed   = 0
    Failed   = 0
    Failures = [System.Collections.Generic.List[string]]::new()
    Context  = ''
}

function Reset-TestState {
    $script:TestState.Passed = 0
    $script:TestState.Failed = 0
    $script:TestState.Failures.Clear()
    $script:TestState.Context = ''
}

function Get-TestState { return $script:TestState }

function Describe {
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Name,
        [Parameter(Mandatory, Position = 1)] [scriptblock] $Body
    )

    $script:TestState.Context = $Name
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor Cyan
    & $Body
    $script:TestState.Context = ''
}

function It {
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Name,
        [Parameter(Mandatory, Position = 1)] [scriptblock] $Body
    )

    # Each test gets its own scratch folder, cleaned up afterwards, so tests can
    # build fake install trees without tripping over each other.
    $script:TestDrive = Join-Path ([System.IO.Path]::GetTempPath()) ("ptrsetup-test-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $null = New-Item -ItemType Directory -Path $script:TestDrive -Force

    try {
        & $Body
        $script:TestState.Passed++
        Write-Host "    [pass] $Name" -ForegroundColor DarkGreen
    }
    catch {
        $script:TestState.Failed++
        $where = if ($_.InvocationInfo) { " ($($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber))" } else { '' }
        $script:TestState.Failures.Add("$($script:TestState.Context) / $Name`n      $($_.Exception.Message)$where")
        Write-Host "    [FAIL] $Name" -ForegroundColor Red
        Write-Host "           $($_.Exception.Message)" -ForegroundColor DarkRed
    }
    finally {
        Remove-Item -LiteralPath $script:TestDrive -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory, Position = 0)] $Condition,
        [Parameter(Position = 1)] [string] $Message = 'Expected the condition to be true.'
    )
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param(
        [Parameter(Mandatory, Position = 0)] $Condition,
        [Parameter(Position = 1)] [string] $Message = 'Expected the condition to be false.'
    )
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [Parameter(Position = 0)] $Expected,
        [Parameter(Position = 1)] $Actual,
        [Parameter(Position = 2)] [string] $Message
    )

    $same = if ($null -eq $Expected -and $null -eq $Actual) { $true }
    elseif ($Expected -is [array] -or $Actual -is [array]) {
        (@($Expected) -join '|') -ceq (@($Actual) -join '|')
    }
    else { $Expected -ceq $Actual }

    if (-not $same) {
        $detail = "Expected: <$(@($Expected) -join ', ')>`n      Actual:   <$(@($Actual) -join ', ')>"
        throw ($(if ($Message) { "$Message`n      $detail" } else { $detail }))
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory, Position = 0)] [scriptblock] $Body,
        [string] $Match,
        [string] $Message = 'Expected the script block to throw.'
    )

    try {
        & $Body
    }
    catch {
        if ($Match -and $_.Exception.Message -notmatch $Match) {
            throw "Threw, but the message did not match '$Match': $($_.Exception.Message)"
        }
        return
    }
    throw $Message
}
