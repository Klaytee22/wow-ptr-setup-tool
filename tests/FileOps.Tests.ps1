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

        Start-Sleep -Milliseconds 20
        $null = New-TestFile -Path $copy -Content 'profile data'   # same size, later stamp
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
