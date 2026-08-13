<#
.SYNOPSIS
    Turning a scan of the machine into a filled-in context.

.DESCRIPTION
    The window opens with something useful already selected: the most plausible
    live/PTR pair, matching account folders, and characters paired by name. The
    user changes any of it; these helpers just supply the first guess and keep
    the selection consistent when a client changes underneath it.
#>

function Set-PtrSetupAccountGuess {
    <#
    .SYNOPSIS
        Fill in either account folder if it is not already chosen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [psobject] $Context)

    if ($Context.Source -and -not $Context.SourceAccount) {
        $accounts = @(Get-WowAccount -Install $Context.Source)
        $Context.SourceAccount = if ($accounts) { $accounts[0] } else { $null }
    }
    if ($Context.Target -and -not $Context.TargetAccount) {
        $accounts = @(Get-WowAccount -Install $Context.Target)
        if ($Context.SourceAccount -and $accounts -contains $Context.SourceAccount) {
            $Context.TargetAccount = $Context.SourceAccount
        }
        else {
            $Context.TargetAccount = if ($accounts) { $accounts[0] } else { $null }
        }
    }
    return $Context
}

function Set-PtrSetupCharacterGuess {
    <#
    .SYNOPSIS
        Pair live and PTR characters by name — realms rarely match, names do.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Context,
        [switch] $Force
    )

    if ($Context.Character.Count -gt 0 -and -not $Force) { return $Context }
    if (-not $Context.Source -or -not $Context.Target -or -not $Context.SourceAccount -or -not $Context.TargetAccount) {
        return $Context
    }

    $sourceCharacters = @(Get-WowCharacter -Install $Context.Source -Account $Context.SourceAccount)
    $targetCharacters = @(Get-WowCharacter -Install $Context.Target -Account $Context.TargetAccount)

    $byName = @{}
    foreach ($character in $sourceCharacters) {
        $key = $character.Name.ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) { $byName[$key] = $character }
    }

    $pairs = [System.Collections.Generic.List[psobject]]::new()
    foreach ($target in $targetCharacters) {
        $key = $target.Name.ToLowerInvariant()
        if ($byName.ContainsKey($key)) {
            $pairs.Add([pscustomobject]@{ Source = $byName[$key]; Target = $target })
        }
    }
    $Context.Character = @($pairs)
    return $Context
}

function Initialize-PtrSetupContext {
    <#
    .SYNOPSIS
        Scan for installs and return a context with a first guess filled in.

    .PARAMETER Path
        Extra folders to scan on top of the standard install locations.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Path,
        [psobject[]] $Install
    )

    if (-not $Install) { $Install = @(Get-WowInstall -Path $Path) }
    $pair = Select-WowInstallPair -Install $Install

    $context = New-PtrSetupContext -Source $pair.Source -Target $pair.Target
    $context = Set-PtrSetupAccountGuess -Context $context
    $context = Set-PtrSetupCharacterGuess -Context $context
    return $context
}

function Set-PtrSetupInstall {
    <#
    .SYNOPSIS
        Change one side of the selection, clearing anything downstream of it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Context,
        [Parameter(Mandatory)] [ValidateSet('Source', 'Target')] [string] $Side,
        [psobject] $Install
    )

    $current = $Context.$Side
    if ($current -and $Install -and $current.Id -eq $Install.Id) { return $Context }

    $Context.$Side = $Install
    if ($Side -eq 'Source') { $Context.SourceAccount = $null } else { $Context.TargetAccount = $null }
    $Context.Character = @()

    $Context = Set-PtrSetupAccountGuess -Context $Context
    return Set-PtrSetupCharacterGuess -Context $Context
}

function Set-PtrSetupAccount {
    <#
    .SYNOPSIS
        Change one side's account folder, re-guessing the character mapping.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Context,
        [Parameter(Mandatory)] [ValidateSet('Source', 'Target')] [string] $Side,
        [string] $Account
    )

    if ($Side -eq 'Source') { $Context.SourceAccount = $Account } else { $Context.TargetAccount = $Account }
    $Context.Character = @()
    return Set-PtrSetupCharacterGuess -Context $Context
}
