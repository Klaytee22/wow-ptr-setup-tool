<#
.SYNOPSIS
    Plan-then-apply file copying, with a backup of everything overwritten.

.DESCRIPTION
    Every step plans a list of file actions first and only writes when the user
    presses Apply, so the window can always show exactly what is about to
    change. Anything overwritten is copied into a timestamped backup folder that
    Restore-PtrSetupBackup can put back.
#>

$script:BackupDirName = '_ptrsetup_backups'
$script:BackupManifestName = 'manifest.json'

# Never worth copying to the PTR, and noisy in the preview.
$script:DefaultExcludes = @('Thumbs.db', '.DS_Store', 'desktop.ini')

function New-FileAction {
    <#
    .SYNOPSIS
        One planned filesystem change, previewable before anything is written.

    .DESCRIPTION
        Most actions copy Source to Destination. A step that generates a file
        instead (the Config.wtf merge) leaves Source empty and supplies Content,
        which Invoke-FileActionPlan writes verbatim.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('create', 'overwrite', 'skip')] [string] $Kind,
        [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [long] $Size = 0,
        [string] $Note = '',
        [string] $Content
    )

    [pscustomobject]@{
        PSTypeName  = 'PtrUiSetup.FileAction'
        Kind        = $Kind
        Source      = $Source
        Destination = $Destination
        Size        = $Size
        Note        = $Note
        Content     = $Content
    }
}

function Test-PathWithin {
    <#
    .SYNOPSIS
        True when Path is inside Parent (after normalising both).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Parent
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $normalisedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd($separator) + $separator
    $normalisedPath = [System.IO.Path]::GetFullPath($Path)
    return $normalisedPath.StartsWith($normalisedParent, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PathRelative {
    <#
    .SYNOPSIS
        Path expressed relative to Base.

    .DESCRIPTION
        [System.IO.Path]::GetRelativePath is .NET Core only, so it is missing on
        Windows PowerShell 5.1 — the edition the launcher uses. This does the
        same job with string maths that works on both.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $Path
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd($separator, [System.IO.Path]::AltDirectorySeparatorChar) + $separator
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Path is not inside $Base"
    }
    return $full.Substring($baseFull.Length)
}

function Write-TextFileNoBom {
    <#
    .SYNOPSIS
        Write UTF-8 with no byte-order mark.

    .DESCRIPTION
        Set-Content -Encoding UTF8 emits a BOM on Windows PowerShell and none on
        PowerShell 7. Config.wtf is parsed by the game, so it gets the same
        bytes either way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function Get-RelativeFile {
    <#
    .SYNOPSIS
        All files under Root, as paths relative to it, sorted for stable previews.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string[]] $Exclude = $script:DefaultExcludes
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $files = Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue
    $relative = foreach ($file in $files) {
        $rel = Get-PathRelative -Base $rootFull -Path $file.FullName
        $parts = $rel -split '[\\/]'
        if ($parts | Where-Object { $Exclude -contains $_ }) { continue }
        [pscustomobject]@{ Relative = $rel; FullName = $file.FullName; Length = $file.Length }
    }
    return @($relative | Sort-Object Relative)
}

function New-TreeCopyPlan {
    <#
    .SYNOPSIS
        Plan a recursive copy of Source onto Destination without touching disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [bool] $Overwrite = $true,
        [string[]] $Exclude = $script:DefaultExcludes
    )

    $actions = [System.Collections.Generic.List[psobject]]::new()
    foreach ($file in (Get-RelativeFile -Root $Source -Exclude $Exclude)) {
        $target = Join-Path $Destination $file.Relative
        if (-not (Test-Path -LiteralPath $target)) {
            $actions.Add((New-FileAction -Kind 'create' -Source $file.FullName -Destination $target -Size $file.Length))
        }
        elseif ($Overwrite) {
            $actions.Add((New-FileAction -Kind 'overwrite' -Source $file.FullName -Destination $target -Size $file.Length))
        }
        else {
            $actions.Add((New-FileAction -Kind 'skip' -Source $file.FullName -Destination $target -Size $file.Length -Note 'already exists'))
        }
    }
    return @($actions)
}

function New-SingleFileCopyPlan {
    <#
    .SYNOPSIS
        Plan a single-file copy, or nothing at all if the source is missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [bool] $Overwrite = $true
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return @() }
    $size = (Get-Item -LiteralPath $Source).Length

    if (-not (Test-Path -LiteralPath $Destination)) {
        return @(New-FileAction -Kind 'create' -Source $Source -Destination $Destination -Size $size)
    }
    if ($Overwrite) {
        return @(New-FileAction -Kind 'overwrite' -Source $Source -Destination $Destination -Size $size)
    }
    return @(New-FileAction -Kind 'skip' -Source $Source -Destination $Destination -Size $size -Note 'already exists')
}

function Get-BackupRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $InstallPath)
    return Join-Path $InstallPath $script:BackupDirName
}

function Invoke-FileActionPlan {
    <#
    .SYNOPSIS
        Execute planned actions, backing up every file about to be overwritten.

    .DESCRIPTION
        Returns the actions actually performed, plus the backup folder if one was
        needed. Throws if any destination falls outside InstallPath — a guard
        against a mis-selected target turning into a copy over live files.

    .PARAMETER PreviewOnly
        Plan and validate, but write nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [psobject[]] $Action,
        [Parameter(Mandatory)] [string] $InstallPath,
        [Parameter(Mandatory)] [string] $Label,
        [switch] $PreviewOnly,
        [scriptblock] $OnProgress
    )

    $todo = @($Action | Where-Object { $_.Kind -in @('create', 'overwrite') })

    foreach ($item in $todo) {
        if (-not (Test-PathWithin -Path $item.Destination -Parent $InstallPath)) {
            throw "Refusing to write outside the selected client folder: $($item.Destination)"
        }
    }

    if ($PreviewOnly -or -not $todo) {
        $performed = if ($PreviewOnly) { @() } else { $todo }
        return [pscustomobject]@{ Performed = $performed; BackupPath = $null }
    }

    # Back up everything about to be replaced, with a manifest for the restore.
    $backupPath = $null
    $overwrites = @($todo | Where-Object { $_.Kind -eq 'overwrite' })
    if ($overwrites) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $safeLabel = ($Label -replace '[^\w\-]', '-')
        $backupPath = Join-Path (Get-BackupRoot -InstallPath $InstallPath) "$stamp-$safeLabel"
        $entries = [System.Collections.Generic.List[psobject]]::new()

        foreach ($item in $overwrites) {
            $relative = Get-PathRelative -Base $InstallPath -Path $item.Destination
            $target = Join-Path $backupPath $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $target -Parent) -Force
            Copy-Item -LiteralPath $item.Destination -Destination $target -Force
            $entries.Add([pscustomobject]@{ Relative = $relative; RestoredTo = $item.Destination })
        }

        $manifest = [pscustomobject]@{
            Label   = $Label
            Install = $InstallPath
            Created = (Get-Date).ToString('s')
            Files   = @($entries)
        }
        Write-TextFileNoBom -Path (Join-Path $backupPath $script:BackupManifestName) `
            -Content ($manifest | ConvertTo-Json -Depth 5)
    }

    $index = 0
    foreach ($item in $todo) {
        $index++
        $parent = Split-Path -Path $item.Destination -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }

        if ($item.Source) {
            Copy-Item -LiteralPath $item.Source -Destination $item.Destination -Force
        }
        elseif (-not [string]::IsNullOrEmpty($item.Content)) {
            Write-TextFileNoBom -Path $item.Destination -Content $item.Content
        }
        else {
            throw "Action for $($item.Destination) has neither a source nor content."
        }

        if ($OnProgress) { & $OnProgress $index $todo.Count }
    }

    return [pscustomobject]@{ Performed = $todo; BackupPath = $backupPath }
}

function Get-PtrSetupBackup {
    <#
    .SYNOPSIS
        Backup folders for an install, newest first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $InstallPath)

    $root = Get-BackupRoot -InstallPath $InstallPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $backups = foreach ($folder in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $manifestPath = Join-Path $folder.FullName $script:BackupManifestName
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
        catch {
            continue
        }
        # ConvertFrom-Json turns the stored timestamp into a DateTime, which
        # would otherwise render in whatever format the machine's locale likes.
        $created = try { ([datetime]$manifest.Created).ToString('yyyy-MM-dd HH:mm') } catch { [string]$manifest.Created }
        [pscustomobject]@{
            Id        = $folder.Name
            Path      = $folder.FullName
            Label     = $manifest.Label
            Created   = $created
            FileCount = @($manifest.Files).Count
            Display   = ('{0} — {1} — {2} file(s)' -f $manifest.Label, $created, @($manifest.Files).Count)
        }
    }
    return @($backups)
}

function Restore-PtrSetupBackup {
    <#
    .SYNOPSIS
        Put a backup's files back where they came from. Returns the file count.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InstallPath,
        [Parameter(Mandatory)] [string] $BackupId
    )

    $folder = Join-Path (Get-BackupRoot -InstallPath $InstallPath) $BackupId
    $manifestPath = Join-Path $folder $script:BackupManifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "No backup manifest at $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $restored = 0
    foreach ($entry in @($manifest.Files)) {
        $source = Join-Path $folder $entry.Relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $destination = Join-Path $InstallPath $entry.Relative
        $parent = Split-Path -Path $destination -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $restored++
    }
    return $restored
}

function Format-ByteSize {
    <#
    .SYNOPSIS
        Byte count as a short human-readable string.
    #>
    [CmdletBinding()]
    param([long] $Bytes)

    if ($Bytes -le 0) { return '0 B' }
    $units = @('B', 'KB', 'MB', 'GB')
    $value = [double]$Bytes
    $unit = 0
    while ($value -ge 1024 -and $unit -lt $units.Count - 1) {
        $value /= 1024
        $unit++
    }
    if ($unit -eq 0) { return '{0:N0} B' -f $value }
    return '{0:N1} {1}' -f $value, $units[$unit]
}
