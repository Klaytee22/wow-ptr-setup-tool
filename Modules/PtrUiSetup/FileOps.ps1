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
        which Invoke-FileActionPlan writes verbatim. A 'delete' action has only a
        Destination — the file is backed up, then removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('create', 'overwrite', 'skip', 'delete')] [string] $Kind,
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

    .PARAMETER Prune
        Also plan deletes for files under Destination that Source does not have,
        making the destination a mirror rather than a merge. This is what "delete
        any addons there, then paste yours" means in file terms.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [bool] $Overwrite = $true,
        [switch] $Prune,
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

    if ($Prune) {
        $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in (Get-RelativeFile -Root $Source -Exclude $Exclude)) { $null = $wanted.Add($file.Relative) }
        foreach ($file in (Get-RelativeFile -Root $Destination -Exclude $Exclude)) {
            if ($wanted.Contains($file.Relative)) { continue }
            $actions.Add((New-FileAction -Kind 'delete' -Destination $file.FullName -Size $file.Length -Note 'not in the live client'))
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

    $todo = @($Action | Where-Object { $_.Kind -in @('create', 'overwrite', 'delete') })

    foreach ($item in $todo) {
        if (-not (Test-PathWithin -Path $item.Destination -Parent $InstallPath)) {
            throw "Refusing to write outside the selected client folder: $($item.Destination)"
        }
    }

    if ($PreviewOnly -or -not $todo) {
        $performed = if ($PreviewOnly) { @() } else { $todo }
        return [pscustomobject]@{ Performed = $performed; BackupPath = $null }
    }

    # Back up everything about to be replaced or removed, and note everything
    # about to be created, so Restore can undo the run completely rather than
    # leaving newly-copied files behind.
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $safeLabel = ($Label -replace '[^\w\-]', '-')
    $backupPath = Join-Path (Get-BackupRoot -InstallPath $InstallPath) "$stamp-$safeLabel"
    $replaced = @($todo | Where-Object { $_.Kind -in @('overwrite', 'delete') })
    $entries = [System.Collections.Generic.List[psobject]]::new()

    foreach ($item in $replaced) {
        $relative = Get-PathRelative -Base $InstallPath -Path $item.Destination
        $target = Join-Path $backupPath $relative
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $target -Parent) -Force
        Copy-Item -LiteralPath $item.Destination -Destination $target -Force
        $entries.Add([pscustomobject]@{ Relative = $relative; RestoredTo = $item.Destination })
    }

    $added = foreach ($item in @($todo | Where-Object { $_.Kind -eq 'create' })) {
        Get-PathRelative -Base $InstallPath -Path $item.Destination
    }

    $manifest = [pscustomobject]@{
        Label   = $Label
        Install = $InstallPath
        Created = (Get-Date).ToString('s')
        Files   = @($entries)
        Added   = @($added)
    }
    $null = New-Item -ItemType Directory -Path $backupPath -Force
    Write-TextFileNoBom -Path (Join-Path $backupPath $script:BackupManifestName) `
        -Content ($manifest | ConvertTo-Json -Depth 5)

    $index = 0
    $emptied = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $todo) {
        $index++

        if ($item.Kind -eq 'delete') {
            Remove-Item -LiteralPath $item.Destination -Force -ErrorAction SilentlyContinue
            $emptied.Add((Split-Path -Path $item.Destination -Parent))
            if ($OnProgress) { & $OnProgress $index $todo.Count }
            continue
        }

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

    Remove-EmptyFolder -Path $emptied -Stop $InstallPath

    return [pscustomobject]@{ Performed = $todo; BackupPath = $backupPath }
}

function Remove-EmptyFolder {
    <#
    .SYNOPSIS
        Tidy up folders left empty by deletes, walking up but never past -Stop.

    .DESCRIPTION
        Deleting every file in Interface\AddOns\SomeAddon leaves the folder
        behind, and WoW lists empty addon folders as broken addons.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [string[]] $Path,
        [Parameter(Mandatory)] [string] $Stop
    )

    foreach ($folder in @($Path | Select-Object -Unique)) {
        $current = $folder
        while ($current -and (Test-PathWithin -Path $current -Parent $Stop)) {
            if (-not (Test-Path -LiteralPath $current -PathType Container)) { break }
            if (@(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue).Count -gt 0) { break }
            Remove-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            $current = Split-Path -Path $current -Parent
        }
    }
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
        $replacedCount = @($manifest.Files).Count
        $addedCount = if ($manifest.PSObject.Properties.Name -contains 'Added') { @($manifest.Added).Count } else { 0 }
        [pscustomobject]@{
            Id         = $folder.Name
            Path       = $folder.FullName
            Label      = $manifest.Label
            Created    = $created
            FileCount  = $replacedCount
            AddedCount = $addedCount
            Display    = ('{0} — {1} — {2} replaced, {3} added' -f $manifest.Label, $created, $replacedCount, $addedCount)
        }
    }
    return @($backups)
}

function Restore-PtrSetupBackup {
    <#
    .SYNOPSIS
        Undo a run: put replaced files back, and remove the files it added.

    .DESCRIPTION
        Restoring only the overwritten files would leave every newly-copied file
        behind, which is not what "undo" means to someone who has just watched a
        step go wrong. The manifest records both halves.

    .PARAMETER KeepAdded
        Put replaced files back but leave added files in place.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InstallPath,
        [Parameter(Mandatory)] [string] $BackupId,
        [switch] $KeepAdded
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

    $removed = 0
    $emptied = [System.Collections.Generic.List[string]]::new()
    if (-not $KeepAdded -and $manifest.PSObject.Properties.Name -contains 'Added') {
        foreach ($relative in @($manifest.Added)) {
            $destination = Join-Path $InstallPath $relative
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            $emptied.Add((Split-Path -Path $destination -Parent))
            $removed++
        }
        Remove-EmptyFolder -Path $emptied -Stop $InstallPath
    }

    return [pscustomobject]@{ Restored = $restored; Removed = $removed }
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
