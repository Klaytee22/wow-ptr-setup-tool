<#
.SYNOPSIS
    Finds WoW installs on this machine and enumerates what lives inside them.

.DESCRIPTION
    Detection is deliberately forgiving: it scans the handful of places
    Battle.net installs to, and the GUI always lets the user browse to a folder
    the scan missed.
#>

# Every client folder that can sit inside a "World of Warcraft" install.
# Line pairs a live client with its PTR counterpart, so the app can suggest a
# source/target pair without the user thinking about folder names.
$script:WowFlavors = @(
    [pscustomobject]@{ DirName = '_retail_';           Label = 'Retail';          Line = 'retail';  IsPtr = $false }
    [pscustomobject]@{ DirName = '_ptr_';              Label = 'Retail PTR';      Line = 'retail';  IsPtr = $true  }
    [pscustomobject]@{ DirName = '_xptr_';             Label = 'Retail PTR 2';    Line = 'retail';  IsPtr = $true  }
    [pscustomobject]@{ DirName = '_beta_';             Label = 'Retail Beta';     Line = 'retail';  IsPtr = $true  }
    [pscustomobject]@{ DirName = '_classic_';          Label = 'Classic';         Line = 'classic'; IsPtr = $false }
    [pscustomobject]@{ DirName = '_classic_ptr_';      Label = 'Classic PTR';     Line = 'classic'; IsPtr = $true  }
    [pscustomobject]@{ DirName = '_classic_beta_';     Label = 'Classic Beta';    Line = 'classic'; IsPtr = $true  }
    [pscustomobject]@{ DirName = '_classic_era_';      Label = 'Classic Era';     Line = 'era';     IsPtr = $false }
    [pscustomobject]@{ DirName = '_classic_era_ptr_';  Label = 'Classic Era PTR'; Line = 'era';     IsPtr = $true  }
    [pscustomobject]@{ DirName = '_classic_era_beta_'; Label = 'Classic Era Beta';Line = 'era';     IsPtr = $true  }
)

function Get-WowFlavor {
    <#
    .SYNOPSIS
        All known client folder names, or the one matching -DirName.
    #>
    [CmdletBinding()]
    param([string] $DirName)

    if ($PSBoundParameters.ContainsKey('DirName')) {
        return $script:WowFlavors | Where-Object { $_.DirName -eq $DirName } | Select-Object -First 1
    }
    return $script:WowFlavors
}

function New-WowInstall {
    <#
    .SYNOPSIS
        Wraps a client folder with the paths every other function needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [psobject] $Flavor
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    [pscustomobject]@{
        PSTypeName      = 'PtrUiSetup.Install'
        Id              = $full
        Path            = $full
        Root            = Split-Path -Path $full -Parent
        DirName         = $Flavor.DirName
        Label           = $Flavor.Label
        Line            = $Flavor.Line
        IsPtr           = $Flavor.IsPtr
        Wtf             = Join-Path $full 'WTF'
        AccountRoot     = Join-Path $full 'WTF/Account'
        ConfigWtf       = Join-Path $full 'WTF/Config.wtf'
        AddOns          = Join-Path $full 'Interface/AddOns'
        # A client only grows its WTF tree once it has been run at least once.
        HasBeenLaunched = Test-Path -LiteralPath (Join-Path $full 'WTF') -PathType Container
        Display         = ('{0} — {1}' -f $Flavor.Label, $full)
    }
}

function Test-WindowsHost {
    <#
    .SYNOPSIS
        True when running on Windows, on both PowerShell editions.

    .DESCRIPTION
        $IsWindows only exists on PowerShell 6+; on Windows PowerShell 5.1 it is
        undefined, which Set-StrictMode turns into a hard error. PSEdition
        'Desktop' is only ever Windows, so it settles the question first.
    #>
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Test-MacHost {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $false }
    return [bool](Get-Variable -Name 'IsMacOS' -ValueOnly -ErrorAction SilentlyContinue)
}

# Where Battle.net puts a "World of Warcraft" folder, relative to a drive root.
$script:WowRelativeRoots = @(
    'Program Files (x86)/World of Warcraft'
    'Program Files/World of Warcraft'
    'World of Warcraft'
    'Games/World of Warcraft'
    'Battle.net/World of Warcraft'
)

# Blizzard records the install path when the game is installed. Reading it is
# instant and exact, which beats looking in likely folders.
$script:WowRegistryKeys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft'
    'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft'
)

function Get-WowDefaultRoot {
    <#
    .SYNOPSIS
        The conventional install folder, for when nothing better is known.

    .DESCRIPTION
        What the window's folder box starts with on a machine where detection
        comes up empty — a sensible thing to show and edit beats an empty box.
    #>
    [CmdletBinding()]
    param()

    if (Test-MacHost) { return '/Applications/World of Warcraft' }
    if (-not (Test-WindowsHost)) { return (Join-Path $HOME 'World of Warcraft') }

    # Read the folder rather than hard-coding C:, which is wrong on a machine
    # that boots from another drive.
    $programFiles = ${env:ProgramFiles(x86)}
    if (-not $programFiles) { $programFiles = $env:ProgramFiles }
    if (-not $programFiles) { return 'C:\Program Files (x86)\World of Warcraft' }
    return (Join-Path $programFiles 'World of Warcraft')
}

function Get-FixedDriveRoot {
    <#
    .SYNOPSIS
        Local fixed disks, as drive roots.

    .DESCRIPTION
        Deliberately not every PowerShell drive: a mapped network drive that is
        no longer reachable makes each Test-Path against it block until it times
        out, which is most of the way to a detection pass that appears to hang.
        Games live on local disks.
    #>
    [CmdletBinding()]
    param()

    $roots = foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
            if (-not $drive.IsReady) { continue }
            $drive.RootDirectory.FullName
        }
        catch { continue }
    }
    return @($roots)
}

function Get-WowRegistryPath {
    <#
    .SYNOPSIS
        Install paths Blizzard recorded in the registry, if any.

    .DESCRIPTION
        InstallPath usually names a client folder (…\World of Warcraft\_retail_)
        rather than the parent, which is fine — Get-WowInstall accepts either.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-WindowsHost)) { return @() }

    $found = foreach ($key in $script:WowRegistryKeys) {
        try {
            $value = (Get-ItemProperty -Path $key -Name 'InstallPath' -ErrorAction Stop).InstallPath
            if ($value) { $value.TrimEnd('\', '/') }
        }
        catch { continue }
    }

    # The uninstall entry is the fallback: present even when the key above is not.
    try {
        $uninstall = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction Stop |
            Where-Object { $_.PSChildName -like 'World of Warcraft*' }
        $found = @($found) + @(foreach ($entry in $uninstall) {
                $value = (Get-ItemProperty -Path $entry.PSPath -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
                if ($value) { $value.TrimEnd('\', '/') }
            })
    }
    catch { <# no uninstall key is not an error #> }

    return @(@($found) | Where-Object { $_ } | Select-Object -Unique)
}

function Get-WowRootCandidate {
    <#
    .SYNOPSIS
        Folders worth looking in for a WoW install, best guess first.

    .DESCRIPTION
        Ordered by how much each source is worth trusting, and kept cheap: the
        registry is exact and costs one read, then a handful of conventional
        folders on local disks. Nothing here walks a directory tree — a
        filesystem-wide search for a folder this large is not worth the seconds
        it takes when the window has a Browse button.
    #>
    [CmdletBinding()]
    param()

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($path in (Get-WowRegistryPath)) { $roots.Add($path) }

    if (Test-WindowsHost) {
        foreach ($drive in (Get-FixedDriveRoot)) {
            foreach ($relative in $script:WowRelativeRoots) { $roots.Add((Join-Path $drive $relative)) }
        }
    }
    elseif (Test-MacHost) {
        $roots.Add('/Applications/World of Warcraft')
        $roots.Add((Join-Path $HOME 'Applications/World of Warcraft'))
    }

    # Set PTRSETUP_EXTRA_ROOTS to point the app at extra folders (used to drive
    # the GUI against a fake install tree during development).
    $extra = $env:PTRSETUP_EXTRA_ROOTS
    if ($extra) {
        foreach ($part in $extra.Split([System.IO.Path]::PathSeparator)) {
            if ($part.Trim()) { $roots.Add($part.Trim()) }
        }
    }

    return @(@($roots) | Select-Object -Unique)
}

function Find-WowFolder {
    <#
    .SYNOPSIS
        The first folder on this machine that actually holds a WoW client, or
        $null if none of the likely places has one.

    .DESCRIPTION
        Walks Get-WowRootCandidate cheapest-first and stops at the first hit, so
        the usual case — the game where Blizzard put it — costs one registry read
        and one directory listing. Returns the "World of Warcraft" folder rather
        than the client folder inside it, since that is the one a person
        recognises and the one worth showing them.
    #>
    [CmdletBinding()]
    param()

    foreach ($candidate in (Get-WowRootCandidate)) {
        $found = @(Get-WowInstall -Path $candidate -SkipDefaultLocations)
        if ($found.Count) { return $found[0].Root }
    }
    return $null
}

function Get-WowInstall {
    <#
    .SYNOPSIS
        Every recognised client folder found in the standard locations plus -Path.

    .DESCRIPTION
        A supplied path may point either at the "World of Warcraft" folder or at
        a single client folder inside it — both are accepted, because people
        paste whichever one their file explorer happens to be showing.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Path,
        [switch] $SkipDefaultLocations
    )

    $roots = [System.Collections.Generic.List[string]]::new()
    if (-not $SkipDefaultLocations) {
        foreach ($candidate in Get-WowRootCandidate) { $roots.Add($candidate) }
    }
    foreach ($candidate in $Path) { if ($candidate) { $roots.Add($candidate) } }

    $found = [ordered]@{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        # The path may itself be a client folder; scan its parent as well.
        $leafFlavor = Get-WowFlavor -DirName (Split-Path -Path $root -Leaf)
        if ($leafFlavor) {
            $install = New-WowInstall -Path $root -Flavor $leafFlavor
            if (-not $found.Contains($install.Id)) { $found[$install.Id] = $install }
            $root = Split-Path -Path $root -Parent
        }

        foreach ($child in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $flavor = Get-WowFlavor -DirName $child.Name
            if (-not $flavor) { continue }
            $install = New-WowInstall -Path $child.FullName -Flavor $flavor
            if (-not $found.Contains($install.Id)) { $found[$install.Id] = $install }
        }
    }

    return @($found.Values | Sort-Object Root, DirName)
}

function Select-WowInstallPair {
    <#
    .SYNOPSIS
        Best guess at (live source, PTR target) from a list of installs.

    .DESCRIPTION
        Prefers a live/PTR pair on the same line under the same root, since that
        is what "copy my UI to the PTR" means for all but the oddest setups.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [psobject[]] $Install)

    $live = @($Install | Where-Object { -not $_.IsPtr -and $_.HasBeenLaunched })
    $ptr = @($Install | Where-Object { $_.IsPtr })

    if (-not $ptr) {
        return [pscustomobject]@{ Source = ($live | Select-Object -First 1); Target = $null }
    }

    foreach ($target in $ptr) {
        foreach ($source in $live) {
            if ($source.Line -eq $target.Line -and $source.Root -eq $target.Root) {
                return [pscustomobject]@{ Source = $source; Target = $target }
            }
        }
    }
    foreach ($target in $ptr) {
        foreach ($source in $live) {
            if ($source.Line -eq $target.Line) {
                return [pscustomobject]@{ Source = $source; Target = $target }
            }
        }
    }
    return [pscustomobject]@{ Source = ($live | Select-Object -First 1); Target = $ptr[0] }
}

function Get-RunningWowProcess {
    <#
    .SYNOPSIS
        Any running World of Warcraft client, live or PTR.

    .DESCRIPTION
        The guide is emphatic about this: WoW rewrites its WTF files when it
        exits, so anything copied while the client is open is silently undone.
        Every client executable starts with "Wow" — Wow.exe, WowClassic.exe,
        WowT.exe, WowClassicT.exe — so one pattern covers them all.
    #>
    [CmdletBinding()]
    param()

    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Wow*' })
}

function Get-WowAccount {
    <#
    .SYNOPSIS
        Account folder names under WTF/Account (usually the WoW account ID).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [psobject] $Install)

    if (-not (Test-Path -LiteralPath $Install.AccountRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Install.AccountRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'SavedVariables' } |
        Sort-Object Name |
        Select-Object -ExpandProperty Name)
}

function Get-WowRealm {
    <#
    .SYNOPSIS
        Realm folder names under one account.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Install,
        [Parameter(Mandatory)] [string] $Account
    )

    $base = Join-Path $Install.AccountRoot $Account
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'SavedVariables' } |
        Sort-Object Name |
        Select-Object -ExpandProperty Name)
}

function Get-WowCharacter {
    <#
    .SYNOPSIS
        Every character folder under an account, across all its realms.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Install,
        [Parameter(Mandatory)] [string] $Account
    )

    $characters = [System.Collections.Generic.List[psobject]]::new()
    foreach ($realm in (Get-WowRealm -Install $Install -Account $Account)) {
        $realmDir = Join-Path (Join-Path $Install.AccountRoot $Account) $realm
        foreach ($child in (Get-ChildItem -LiteralPath $realmDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $characters.Add([pscustomobject]@{
                    PSTypeName = 'PtrUiSetup.Character'
                    Id         = ('{0}/{1}/{2}' -f $Account, $realm, $child.Name)
                    Account    = $Account
                    Realm      = $realm
                    Name       = $child.Name
                    Path       = $child.FullName
                    Display    = ('{0} — {1}' -f $child.Name, $realm)
                })
        }
    }
    return @($characters)
}

function Get-WowCharacterPath {
    <#
    .SYNOPSIS
        Where a character's folder lives (or would live) inside an install.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Install,
        [Parameter(Mandatory)] [psobject] $Character
    )

    return Join-Path (Join-Path (Join-Path $Install.AccountRoot $Character.Account) $Character.Realm) $Character.Name
}
