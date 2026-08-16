Describe 'New-TreeCopyPlan' {

    It 'marks new files as create' {
        $source = Join-Path $script:TestDrive 'src'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'one'
        $null = New-TestFile -Path (Join-Path $source 'nested/b.lua') -Content 'two'

        $plan = @(New-TreeCopyPlan -Source $source -Destination (Join-Path $script:TestDrive 'dest'))
        Assert-Equal 2 $plan.Count
        Assert-Equal @('create', 'create') @($plan.Kind)
    }

    It 'marks existing files as overwrite, or skip when overwriting is off' {
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $script:TestDrive 'dest'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'new'
        $null = New-TestFile -Path (Join-Path $dest 'a.lua') -Content 'old'

        Assert-Equal 'overwrite' @(New-TreeCopyPlan -Source $source -Destination $dest)[0].Kind
        $skipped = @(New-TreeCopyPlan -Source $source -Destination $dest -Overwrite $false)[0]
        Assert-Equal 'skip' $skipped.Kind
        Assert-Equal 'already exists' $skipped.Note
    }

    It 'leaves junk out of the plan from a subfolder too' {
        # The exclusion check splits the relative path, and a top-level file has
        # nothing to split — so a broken split still excludes Thumbs.db at the
        # root while quietly letting every nested one through.
        $source = Join-Path $script:TestDrive 'src'
        $null = New-TestFile -Path (Join-Path $source 'deep/nested/Thumbs.db') -Content 'junk'
        $null = New-TestFile -Path (Join-Path $source 'deep/nested/keep.lua') -Content 'code'

        $planned = @((New-TreeCopyPlan -Source $source -Destination (Join-Path $script:TestDrive 'dest')).Destination)
        Assert-Equal 1 $planned.Count "Expected only the .lua, got: $($planned -join ', ')"
        Assert-True ($planned[0] -like '*keep.lua')
    }

    It 'leaves junk files out of the plan' {
        $source = Join-Path $script:TestDrive 'src'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'one'
        $null = New-TestFile -Path (Join-Path $source 'Thumbs.db') -Content 'junk'
        $null = New-TestFile -Path (Join-Path $source 'sub/.DS_Store') -Content 'junk'

        $plan = @(New-TreeCopyPlan -Source $source -Destination (Join-Path $script:TestDrive 'dest'))
        Assert-Equal 1 $plan.Count
        Assert-True $plan[0].Destination.EndsWith('a.lua')
    }

    It 'plans nothing for a source folder that does not exist' {
        $plan = @(New-TreeCopyPlan -Source (Join-Path $script:TestDrive 'nope') -Destination (Join-Path $script:TestDrive 'dest'))
        Assert-Equal 0 $plan.Count
    }
}

Describe 'New-SingleFileCopyPlan' {

    It 'plans nothing when the source file is missing' {
        $plan = @(New-SingleFileCopyPlan -Source (Join-Path $script:TestDrive 'nope.txt') -Destination (Join-Path $script:TestDrive 'out.txt'))
        Assert-Equal 0 $plan.Count
    }

    It 'plans a create for a new destination' {
        $source = New-TestFile -Path (Join-Path $script:TestDrive 'a.txt') -Content 'hello'
        $plan = @(New-SingleFileCopyPlan -Source $source -Destination (Join-Path $script:TestDrive 'out/a.txt'))
        Assert-Equal 'create' $plan[0].Kind
        Assert-Equal 5 $plan[0].Size
    }
}

Describe 'Invoke-FileActionPlan' {

    It 'copies files and backs up what it overwrites' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $source = Join-Path $script:TestDrive 'src'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'new content'
        $null = New-TestFile -Path (Join-Path $install 'Interface/a.lua') -Content 'old content'

        $plan = New-TreeCopyPlan -Source $source -Destination (Join-Path $install 'Interface')
        $result = Invoke-FileActionPlan -Action $plan -InstallPath $install -Label 'copy_addons'

        Assert-Equal 1 @($result.Performed).Count
        Assert-Equal 'new content' (Get-Content -LiteralPath (Join-Path $install 'Interface/a.lua') -Raw)
        Assert-True ($null -ne $result.BackupPath)
        Assert-Equal 'old content' (Get-Content -LiteralPath (Join-Path $result.BackupPath 'Interface/a.lua') -Raw)
    }

    It 'writes nothing in preview mode' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $null = New-Item -ItemType Directory -Path $install -Force
        $source = Join-Path $script:TestDrive 'src'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'new'

        $plan = New-TreeCopyPlan -Source $source -Destination (Join-Path $install 'Interface')
        $result = Invoke-FileActionPlan -Action $plan -InstallPath $install -Label 'x' -PreviewOnly

        Assert-Equal 0 @($result.Performed).Count
        Assert-False (Test-Path -LiteralPath (Join-Path $install 'Interface'))
    }

    It 'refuses to write outside the selected client folder' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $null = New-Item -ItemType Directory -Path $install -Force
        $source = New-TestFile -Path (Join-Path $script:TestDrive 'src.lua') -Content 'x'
        $escape = New-FileAction -Kind 'create' -Source $source -Destination (Join-Path $script:TestDrive 'elsewhere.lua') -Size 1

        Assert-Throws { Invoke-FileActionPlan -Action @($escape) -InstallPath $install -Label 'bad' } -Match 'outside'
        Assert-False (Test-Path -LiteralPath (Join-Path $script:TestDrive 'elsewhere.lua'))
    }

    It 'writes generated content for actions with no source file' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $null = New-Item -ItemType Directory -Path $install -Force
        $action = New-FileAction -Kind 'create' -Destination (Join-Path $install 'WTF/Config.wtf') -Content "SET a `"1`"`n"

        $null = Invoke-FileActionPlan -Action @($action) -InstallPath $install -Label 'config'
        Assert-Equal "SET a `"1`"`n" (Get-Content -LiteralPath (Join-Path $install 'WTF/Config.wtf') -Raw)
    }

    It 'reports progress as it copies' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $null = New-Item -ItemType Directory -Path $install -Force
        $source = Join-Path $script:TestDrive 'src'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'a'
        $null = New-TestFile -Path (Join-Path $source 'b.lua') -Content 'b'

        $seen = [System.Collections.Generic.List[string]]::new()
        $plan = New-TreeCopyPlan -Source $source -Destination (Join-Path $install 'Interface')
        $null = Invoke-FileActionPlan -Action $plan -InstallPath $install -Label 'x' -OnProgress {
            param($Done, $Total) $seen.Add("$Done/$Total")
        }
        Assert-Equal @('1/2', '2/2') @($seen)
    }
}

Describe 'Backups' {

    It 'restores the original files' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $source = Join-Path $script:TestDrive 'src'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'new'
        $null = New-TestFile -Path (Join-Path $install 'WTF/a.lua') -Content 'original'

        $plan = New-TreeCopyPlan -Source $source -Destination (Join-Path $install 'WTF')
        $null = Invoke-FileActionPlan -Action $plan -InstallPath $install -Label 'step'

        $backups = @(Get-PtrSetupBackup -InstallPath $install)
        Assert-Equal 1 $backups.Count
        Assert-Equal 1 $backups[0].FileCount
        Assert-Equal 'step' $backups[0].Label

        Assert-Equal 1 (Restore-PtrSetupBackup -InstallPath $install -BackupId $backups[0].Id).Restored
        Assert-Equal 'original' (Get-Content -LiteralPath (Join-Path $install 'WTF/a.lua') -Raw)
    }

    It 'lists nothing when no backup has been taken' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $null = New-Item -ItemType Directory -Path $install -Force
        Assert-Equal 0 @(Get-PtrSetupBackup -InstallPath $install).Count
    }

    It 'throws for an unknown backup id' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $null = New-Item -ItemType Directory -Path $install -Force
        Assert-Throws { Restore-PtrSetupBackup -InstallPath $install -BackupId 'nope' } -Match 'manifest'
    }
}

Describe 'Helpers' {

    It 'Test-PathWithin distinguishes inside from outside' {
        Assert-True (Test-PathWithin -Path (Join-Path $script:TestDrive 'a/b') -Parent $script:TestDrive)
        Assert-False (Test-PathWithin -Path (Split-Path -Parent $script:TestDrive) -Parent $script:TestDrive)
    }

    It 'Format-ByteSize reads like a file manager' {
        Assert-Equal '0 B' (Format-ByteSize 0)
        Assert-Equal '512 B' (Format-ByteSize 512)
        Assert-Equal '2.0 KB' (Format-ByteSize 2048)
    }

    It 'Get-RelativeFile returns sorted relative paths' {
        $null = New-TestFile -Path (Join-Path $script:TestDrive 'b.lua') -Content 'b'
        $null = New-TestFile -Path (Join-Path $script:TestDrive 'a/c.lua') -Content 'c'
        $files = @(Get-RelativeFile -Root $script:TestDrive)
        Assert-Equal 2 $files.Count
        Assert-True ($files[0].Relative -like 'a*')
    }
}

Describe 'Cross-edition helpers' {

    It 'Get-PathRelative strips the base folder' {
        $base = Join-Path $script:TestDrive '_classic_ptr_'
        $target = Join-Path $base 'WTF/Account/1/SavedVariables/x.lua'
        $expected = @('WTF', 'Account', '1', 'SavedVariables', 'x.lua') -join [System.IO.Path]::DirectorySeparatorChar
        Assert-Equal $expected (Get-PathRelative -Base $base -Path $target)
    }

    It 'Get-PathRelative refuses a path outside the base' {
        Assert-Throws { Get-PathRelative -Base (Join-Path $script:TestDrive 'a') -Path (Join-Path $script:TestDrive 'b/c.lua') } -Match 'not inside'
    }

    It 'Write-TextFileNoBom writes no byte-order mark' {
        $path = Join-Path $script:TestDrive 'Config.wtf'
        Write-TextFileNoBom -Path $path -Content "SET a `"1`"`n"
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-Equal 83 $bytes[0]   # 'S', not 0xEF from a UTF-8 BOM
    }

    It 'a copied Config.wtf keeps its exact bytes' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $null = New-Item -ItemType Directory -Path $install -Force
        $text = "SET gxWindow `"1`"`nSET realmList `"x`"`n"
        $action = New-FileAction -Kind 'create' -Destination (Join-Path $install 'WTF/Config.wtf') -Content $text
        $null = Invoke-FileActionPlan -Action @($action) -InstallPath $install -Label 'config'
        Assert-Equal $text ([System.IO.File]::ReadAllText((Join-Path $install 'WTF/Config.wtf')))
    }
}

Describe 'Pruning' {

    It 'plans a delete for files the source does not have' {
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $script:TestDrive 'dest'
        $null = New-TestFile -Path (Join-Path $source 'keep.lua') -Content 'keep'
        $null = New-TestFile -Path (Join-Path $dest 'keep.lua') -Content 'old'
        $null = New-TestFile -Path (Join-Path $dest 'stale.lua') -Content 'stale'

        $plan = @(New-TreeCopyPlan -Source $source -Destination $dest -Prune)
        $deletes = @($plan | Where-Object { $_.Kind -eq 'delete' })
        Assert-Equal 1 $deletes.Count
        Assert-True $deletes[0].Destination.EndsWith('stale.lua')
        Assert-Equal 'not in the live client' $deletes[0].Note
    }

    It 'plans no deletes without -Prune' {
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $script:TestDrive 'dest'
        $null = New-TestFile -Path (Join-Path $source 'keep.lua') -Content 'keep'
        $null = New-TestFile -Path (Join-Path $dest 'stale.lua') -Content 'stale'
        Assert-Equal 0 @(@(New-TreeCopyPlan -Source $source -Destination $dest) | Where-Object { $_.Kind -eq 'delete' }).Count
    }

    It 'backs up deleted files, and restore brings them back' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $install 'Interface/AddOns'
        $null = New-TestFile -Path (Join-Path $source 'Mine/Mine.lua') -Content 'mine'
        $null = New-TestFile -Path (Join-Path $dest 'Stale/Stale.lua') -Content 'stale'

        $plan = New-TreeCopyPlan -Source $source -Destination $dest -Prune
        $result = Invoke-FileActionPlan -Action $plan -InstallPath $install -Label 'copy_addons'

        Assert-False (Test-Path -LiteralPath (Join-Path $dest 'Stale/Stale.lua'))
        Assert-True (Test-Path -LiteralPath (Join-Path $dest 'Mine/Mine.lua'))

        $null = Restore-PtrSetupBackup -InstallPath $install -BackupId (Get-PtrSetupBackup -InstallPath $install)[0].Id
        Assert-Equal 'stale' (Get-Content -LiteralPath (Join-Path $dest 'Stale/Stale.lua') -Raw)
    }

    It 'removes folders left empty by a delete' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $install 'Interface/AddOns'
        $null = New-TestFile -Path (Join-Path $source 'Mine/Mine.lua') -Content 'mine'
        $null = New-TestFile -Path (Join-Path $dest 'Stale/Stale.lua') -Content 'stale'

        $null = Invoke-FileActionPlan -Action (New-TreeCopyPlan -Source $source -Destination $dest -Prune) `
            -InstallPath $install -Label 'copy_addons'

        # An empty addon folder is listed in game as a broken addon.
        Assert-False (Test-Path -LiteralPath (Join-Path $dest 'Stale'))
        Assert-True (Test-Path -LiteralPath $dest)
    }

    It 'never deletes outside the selected client folder' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $null = New-Item -ItemType Directory -Path $install -Force
        $outside = New-TestFile -Path (Join-Path $script:TestDrive 'live.lua') -Content 'live'
        $action = New-FileAction -Kind 'delete' -Destination $outside -Size 4

        Assert-Throws { Invoke-FileActionPlan -Action @($action) -InstallPath $install -Label 'bad' } -Match 'outside'
        Assert-True (Test-Path -LiteralPath $outside)
    }

    It 'writes nothing on a preview that contains deletes' {
        $install = Join-Path $script:TestDrive '_classic_ptr_'
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $install 'Interface/AddOns'
        $null = New-TestFile -Path (Join-Path $source 'Mine/Mine.lua') -Content 'mine'
        $null = New-TestFile -Path (Join-Path $dest 'Stale/Stale.lua') -Content 'stale'

        $null = Invoke-FileActionPlan -Action (New-TreeCopyPlan -Source $source -Destination $dest -Prune) `
            -InstallPath $install -Label 'x' -PreviewOnly
        Assert-True (Test-Path -LiteralPath (Join-Path $dest 'Stale/Stale.lua'))
    }
}

Describe 'Test-FileUnchanged' {

    It 'calls a copied file unchanged, and an edited one changed' {
        $source = Join-Path $script:TestDrive 'a.lua'
        $copy = Join-Path $script:TestDrive 'b.lua'
        $null = New-TestFile -Path $source -Content 'profile data'
        Copy-Item -LiteralPath $source -Destination $copy

        # Copy-Item preserves the source timestamp, which is what makes a second
        # run able to tell "already copied" from "needs copying".
        Assert-True (Test-FileUnchanged -Source (Get-Item $source) -Destination (Get-Item $copy))

        # Same size, later stamp — New-TestFile gives every file one of its own,
        # so this does not depend on how fast the machine is.
        $null = New-TestFile -Path $copy -Content 'profile data'
        Assert-True (-not (Test-FileUnchanged -Source (Get-Item $source) -Destination (Get-Item $copy))) `
            'A same-size file written later is a different file.'
    }

    It 'plans a skip for a file already copied, whatever the overwrite setting' {
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $script:TestDrive 'dest'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'same'
        $null = New-Item -ItemType Directory -Path $dest -Force
        Copy-Item -LiteralPath (Join-Path $source 'a.lua') -Destination (Join-Path $dest 'a.lua')

        $planned = @(New-TreeCopyPlan -Source $source -Destination $dest)[0]
        Assert-Equal 'skip' $planned.Kind
        Assert-Equal 'already copied' $planned.Note

        Assert-Equal 'skip' @(New-SingleFileCopyPlan -Source (Join-Path $source 'a.lua') -Destination (Join-Path $dest 'a.lua'))[0].Kind
    }

    It 'still plans an overwrite when the live file has actually changed' {
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $script:TestDrive 'dest'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'new content here'
        $null = New-TestFile -Path (Join-Path $dest 'a.lua') -Content 'old'

        Assert-Equal 'overwrite' @(New-TreeCopyPlan -Source $source -Destination $dest)[0].Kind
    }
}

Describe 'Hand-built actions' {
    <#
        New-TreeCopyPlan builds its action objects inline instead of calling
        New-FileAction, because binding parameters to an advanced function once
        per file was about half the cost of planning a real AddOns folder. That
        is only safe while the two produce the same thing.
    #>

    It 'matches New-FileAction property for property' {
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $script:TestDrive 'dest'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content 'code'

        $built = @(New-TreeCopyPlan -Source $source -Destination $dest)[0]
        $reference = New-FileAction -Kind 'create' -Source $built.Source -Destination $built.Destination -Size $built.Size

        Assert-Equal @($reference.PSObject.Properties.Name | Sort-Object) @($built.PSObject.Properties.Name | Sort-Object)
        Assert-Equal @($reference.PSObject.TypeNames)[0] @($built.PSObject.TypeNames)[0]
        foreach ($name in @($reference.PSObject.Properties.Name)) {
            Assert-Equal $reference.$name $built.$name "The inline action differs from New-FileAction on $name."
        }
    }

    It 'matches for a delete as well' {
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $script:TestDrive 'dest'
        $null = New-TestFile -Path (Join-Path $source 'keep.lua') -Content 'code'
        $null = New-TestFile -Path (Join-Path $dest 'stale.lua') -Content 'old'

        $built = @(New-TreeCopyPlan -Source $source -Destination $dest -Prune | Where-Object { $_.Kind -eq 'delete' })[0]
        $reference = New-FileAction -Kind 'delete' -Destination $built.Destination -Size $built.Size -Note 'not in the live client'

        Assert-Equal @($reference.PSObject.Properties.Name | Sort-Object) @($built.PSObject.Properties.Name | Sort-Object)
        foreach ($name in @($reference.PSObject.Properties.Name)) {
            Assert-Equal $reference.$name $built.$name "The inline delete differs from New-FileAction on $name."
        }
    }
}

Describe 'What the byte totals mean' {

    It 'adds up to exactly the bytes that will be written' {
        # The number beside a step should match what the source folder weighs in
        # a file manager. Both use 1024-based units, so they are comparable.
        $source = Join-Path $script:TestDrive 'src'
        $dest = Join-Path $script:TestDrive 'dest'
        $null = New-TestFile -Path (Join-Path $source 'a.lua') -Content ('x' * 100)
        $null = New-TestFile -Path (Join-Path $source 'sub/b.lua') -Content ('y' * 250)
        # Something on the destination that is not in the source, so pruning has
        # a file to remove.
        $null = New-TestFile -Path (Join-Path $dest 'stale.lua') -Content ('z' * 9999)

        $onDisk = [long]((Get-ChildItem -LiteralPath $source -Recurse -File | Measure-Object -Property Length -Sum).Sum)
        $plan = @(New-TreeCopyPlan -Source $source -Destination $dest -Prune)

        $written = @($plan | Where-Object { $_.Kind -in @('create', 'overwrite') })
        $writtenBytes = [long](($written | Measure-Object -Property Size -Sum).Sum)
        Assert-Equal $onDisk $writtenBytes 'The bytes planned should equal the bytes on disk.'

        # The file being removed must not inflate that: it is not being copied.
        $everything = [long](($plan | Where-Object { $_.Kind -ne 'skip' } | Measure-Object -Property Size -Sum).Sum)
        Assert-True ($everything -gt $writtenBytes) 'The fixture should include a delete with a size on it.'
    }

    It 'reads bytes the way a file manager does' {
        Assert-Equal '0 B' (Format-ByteSize 0)
        Assert-Equal '999 B' (Format-ByteSize 999)
        Assert-Equal '1.0 KB' (Format-ByteSize 1024)
        Assert-Equal '1.5 KB' (Format-ByteSize 1536)
        Assert-Equal '1.0 MB' (Format-ByteSize 1048576)
        Assert-Equal '1.0 GB' (Format-ByteSize 1073741824)
    }
}

Describe 'Deleting backups' {

    function New-BackedUpInstall {
        param([string] $Root)
        $install = Join-Path $Root 'ptr'
        $null = New-TestFile -Path (Join-Path $install 'WTF/Config.wtf') -Content "SET a `"1`"`n"
        foreach ($run in 1..3) {
            $null = Invoke-FileActionPlan -InstallPath $install -Label "step$run" -Action @(
                New-FileAction -Kind 'overwrite' -Destination (Join-Path $install 'WTF/Config.wtf') -Content "SET a `"$run`"`n")
        }
        return $install
    }

    It 'removes every backup and says how much it freed' {
        $install = New-BackedUpInstall -Root $script:TestDrive
        Assert-Equal 3 @(Get-PtrSetupBackup -InstallPath $install).Count

        $result = Remove-PtrSetupBackup -InstallPath $install
        Assert-Equal 3 $result.Removed
        Assert-True ($result.Freed -gt 0) 'Nothing was reported as freed.'
        Assert-Equal 0 @(Get-PtrSetupBackup -InstallPath $install).Count
    }

    It 'removes just the one it is given' {
        $install = New-BackedUpInstall -Root $script:TestDrive
        $backups = @(Get-PtrSetupBackup -InstallPath $install)
        $null = Remove-PtrSetupBackup -InstallPath $install -BackupId $backups[0].Id

        $left = @(Get-PtrSetupBackup -InstallPath $install)
        Assert-Equal 2 $left.Count
        Assert-Equal 0 @($left | Where-Object { $_.Id -eq $backups[0].Id }).Count
    }

    It 'leaves the client itself completely alone' {
        # Deleting backups is not an undo and must not behave like one.
        $install = New-BackedUpInstall -Root $script:TestDrive
        $before = Get-Content -LiteralPath (Join-Path $install 'WTF/Config.wtf') -Raw
        $null = Remove-PtrSetupBackup -InstallPath $install
        Assert-Equal $before (Get-Content -LiteralPath (Join-Path $install 'WTF/Config.wtf') -Raw)
    }

    It 'tidies the backup folder away once it is empty' {
        $install = New-BackedUpInstall -Root $script:TestDrive
        $null = Remove-PtrSetupBackup -InstallPath $install
        Assert-False (Test-Path -LiteralPath (Join-Path $install '_ptrsetup_backups'))
    }

    It 'copes with an install that has never been backed up' {
        $install = Join-Path $script:TestDrive 'fresh'
        $null = New-Item -ItemType Directory -Path $install -Force
        $result = Remove-PtrSetupBackup -InstallPath $install
        Assert-Equal 0 $result.Removed
    }
}

Describe 'Writing without a backup' {

    It 'writes the same files either way' {
        # The backed-up path and the skip-backup path share one writing loop, so
        # what lands on disk cannot depend on which was taken.
        foreach ($skip in @($false, $true)) {
            $install = Join-Path $script:TestDrive "install-$skip"
            $null = New-TestFile -Path (Join-Path $install 'WTF/Config.wtf') -Content "old`n"
            $null = New-TestFile -Path (Join-Path $install 'WTF/gone.txt') -Content "bye`n"

            $null = Invoke-FileActionPlan -InstallPath $install -Label 'x' -SkipBackup:$skip -Action @(
                New-FileAction -Kind 'overwrite' -Destination (Join-Path $install 'WTF/Config.wtf') -Content "new`n"
                New-FileAction -Kind 'create' -Destination (Join-Path $install 'WTF/added.txt') -Content "hello`n"
                New-FileAction -Kind 'delete' -Destination (Join-Path $install 'WTF/gone.txt'))

            Assert-Equal "new`n" (Get-Content -LiteralPath (Join-Path $install 'WTF/Config.wtf') -Raw)
            Assert-Equal "hello`n" (Get-Content -LiteralPath (Join-Path $install 'WTF/added.txt') -Raw)
            Assert-False (Test-Path -LiteralPath (Join-Path $install 'WTF/gone.txt'))
        }
    }

    It 'leaves no backup folder behind when told to skip it' {
        $install = Join-Path $script:TestDrive 'skip'
        $null = New-TestFile -Path (Join-Path $install 'WTF/Config.wtf') -Content "old`n"
        $result = Invoke-FileActionPlan -InstallPath $install -Label 'x' -SkipBackup -Action @(
            New-FileAction -Kind 'overwrite' -Destination (Join-Path $install 'WTF/Config.wtf') -Content "new`n")

        Assert-Equal $null $result.BackupPath
        Assert-Equal 0 @(Get-PtrSetupBackup -InstallPath $install).Count
        Assert-False (Test-Path -LiteralPath (Join-Path $install '_ptrsetup_backups'))
    }

    It 'still takes one when not told to skip it' {
        $install = Join-Path $script:TestDrive 'keep'
        $null = New-TestFile -Path (Join-Path $install 'WTF/Config.wtf') -Content "old`n"
        $result = Invoke-FileActionPlan -InstallPath $install -Label 'x' -Action @(
            New-FileAction -Kind 'overwrite' -Destination (Join-Path $install 'WTF/Config.wtf') -Content "new`n")
        Assert-True ($null -ne $result.BackupPath)
    }

    It 'writes nothing on a preview whichever way it is asked' {
        $install = Join-Path $script:TestDrive 'preview'
        $null = New-TestFile -Path (Join-Path $install 'WTF/Config.wtf') -Content "old`n"
        $null = Invoke-FileActionPlan -InstallPath $install -Label 'x' -PreviewOnly -SkipBackup -Action @(
            New-FileAction -Kind 'overwrite' -Destination (Join-Path $install 'WTF/Config.wtf') -Content "new`n")
        Assert-Equal "old`n" (Get-Content -LiteralPath (Join-Path $install 'WTF/Config.wtf') -Raw)
    }
}

Describe 'Backups in the order they were made' {

    It 'names them so they sort into the order they happened' {
        # Restoring a run means putting its backups back newest first, and the
        # name is the only thing that says which is newest. At one-second
        # resolution an Apply that ran several steps produced names that sorted
        # arbitrarily, so undoing it could leave the middle state behind.
        $install = Join-Path $script:TestDrive 'ptr'
        $null = New-TestFile -Path (Join-Path $install 'WTF/Config.wtf') -Content "0`n"

        $ids = foreach ($run in 1..6) {
            $result = Invoke-FileActionPlan -InstallPath $install -Label 'copy_config_wtf' -Action @(
                New-FileAction -Kind 'overwrite' -Destination (Join-Path $install 'WTF/Config.wtf') -Content "$run`n")
            Split-Path -Leaf $result.BackupPath
        }

        Assert-Equal @($ids) @(@($ids) | Sort-Object) 'Backup names do not sort into the order they were taken.'
        Assert-Equal 6 @($ids | Select-Object -Unique).Count 'Two backups in the same run shared a name.'
    }

    It 'restores a whole run newest first' {
        $install = Join-Path $script:TestDrive 'run'
        $null = New-TestFile -Path (Join-Path $install 'WTF/Config.wtf') -Content "original`n"

        foreach ($run in 1..4) {
            $null = Invoke-FileActionPlan -InstallPath $install -Label "step$run" -Action @(
                New-FileAction -Kind 'overwrite' -Destination (Join-Path $install 'WTF/Config.wtf') -Content "$run`n")
        }

        foreach ($backup in (Get-PtrSetupBackup -InstallPath $install)) {
            $null = Restore-PtrSetupBackup -InstallPath $install -BackupId $backup.Id
        }
        Assert-Equal "original`n" (Get-Content -LiteralPath (Join-Path $install 'WTF/Config.wtf') -Raw) `
            'Undoing the whole run did not get back to where it started.'
    }
}
