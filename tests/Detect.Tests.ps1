Describe 'Get-WowInstall' {

    It 'finds both clients under a World of Warcraft folder' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $installs = @(Get-WowInstall -Path $root -SkipDefaultLocations)
        Assert-Equal @('_classic_', '_classic_ptr_') @($installs.DirName | Sort-Object)
    }

    It 'accepts a path pointing straight at a single client folder' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $installs = @(Get-WowInstall -Path (Join-Path $root '_classic_ptr_') -SkipDefaultLocations)
        # Pointing at one client still surfaces its sibling, since the parent is scanned.
        Assert-Equal @('_classic_', '_classic_ptr_') @($installs.DirName | Sort-Object)
    }

    It 'ignores folders that are not client folders' {
        $root = Join-Path $script:TestDrive 'World of Warcraft'
        $null = New-FakeInstall -Root $root -Flavor '_classic_'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'Utils') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $root '_not_a_flavor_') -Force
        Assert-Equal @('_classic_') @((Get-WowInstall -Path $root -SkipDefaultLocations).DirName)
    }

    It 'reports whether a client has ever been launched' {
        $root = Join-Path $script:TestDrive 'World of Warcraft'
        $null = New-FakeInstall -Root $root -Flavor '_classic_'
        $null = New-Item -ItemType Directory -Path (Join-Path $root '_classic_ptr_/Interface') -Force

        $installs = @(Get-WowInstall -Path $root -SkipDefaultLocations)
        $live = $installs | Where-Object { $_.DirName -eq '_classic_' }
        $ptr = $installs | Where-Object { $_.DirName -eq '_classic_ptr_' }
        Assert-True $live.HasBeenLaunched
        Assert-False $ptr.HasBeenLaunched
    }

    It 'returns nothing for a folder that does not exist' {
        Assert-Equal 0 @(Get-WowInstall -Path (Join-Path $script:TestDrive 'nowhere') -SkipDefaultLocations).Count
    }
}

Describe 'Select-WowInstallPair' {

    It 'pairs a live client with the PTR client on the same line' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $pair = Select-WowInstallPair -Install @(Get-WowInstall -Path $root -SkipDefaultLocations)
        Assert-Equal '_classic_' $pair.Source.DirName
        Assert-Equal '_classic_ptr_' $pair.Target.DirName
    }

    It 'prefers a matching game line over a matching folder' {
        $retailRoot = Join-Path $script:TestDrive 'A/World of Warcraft'
        $classicRoot = Join-Path $script:TestDrive 'B/World of Warcraft'
        $null = New-FakeInstall -Root $retailRoot -Flavor '_retail_'
        $null = New-FakeInstall -Root $classicRoot -Flavor '_classic_'
        $null = New-FakeInstall -Root $classicRoot -Flavor '_classic_ptr_'

        $installs = @(Get-WowInstall -Path @($retailRoot, $classicRoot) -SkipDefaultLocations)
        $pair = Select-WowInstallPair -Install $installs
        Assert-Equal 'classic' $pair.Source.Line
        Assert-Equal 'classic' $pair.Target.Line
    }

    It 'returns no target when no PTR client is installed' {
        $root = Join-Path $script:TestDrive 'World of Warcraft'
        $null = New-FakeInstall -Root $root -Flavor '_classic_'
        $pair = Select-WowInstallPair -Install @(Get-WowInstall -Path $root -SkipDefaultLocations)
        Assert-True ($null -ne $pair.Source)
        Assert-True ($null -eq $pair.Target)
    }
}

Describe 'Accounts, realms and characters' {

    It 'lists account folders' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $live = @(Get-WowInstall -Path $root -SkipDefaultLocations | Where-Object { -not $_.IsPtr })[0]
        Assert-Equal @('12345678#1') @(Get-WowAccount -Install $live)
    }

    It 'does not mistake SavedVariables for a realm' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $live = @(Get-WowInstall -Path $root -SkipDefaultLocations | Where-Object { -not $_.IsPtr })[0]
        Assert-Equal @('Whitemane') @(Get-WowRealm -Install $live -Account '12345678#1')
    }

    It 'lists characters across realms with an addressable id' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $live = @(Get-WowInstall -Path $root -SkipDefaultLocations | Where-Object { -not $_.IsPtr })[0]
        $characters = @(Get-WowCharacter -Install $live -Account '12345678#1')
        Assert-Equal 1 $characters.Count
        Assert-Equal 'Bankalt' $characters[0].Name
        Assert-Equal '12345678#1/Whitemane/Bankalt' $characters[0].Id
    }

    It 'builds a character path inside the right install' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $installs = @(Get-WowInstall -Path $root -SkipDefaultLocations)
        $live = $installs | Where-Object { -not $_.IsPtr }
        $ptr = $installs | Where-Object { $_.IsPtr }
        $character = (Get-WowCharacter -Install $live -Account '12345678#1')[0]

        $path = Get-WowCharacterPath -Install $ptr -Character $character
        Assert-True (Test-PathWithin -Path $path -Parent $ptr.Path)
    }
}

Describe 'Finding the game folder' {

    It 'returns the World of Warcraft folder, not the client folder inside it' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $env:PTRSETUP_EXTRA_ROOTS = $root
        try {
            Assert-Equal ([System.IO.Path]::GetFullPath($root)) (Find-WowFolder)
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    It 'accepts being pointed at a client folder and still reports its parent' {
        # People paste whichever folder their explorer happens to be showing.
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $env:PTRSETUP_EXTRA_ROOTS = Join-Path $root '_classic_'
        try {
            Assert-Equal ([System.IO.Path]::GetFullPath($root)) (Find-WowFolder)
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    It 'returns nothing rather than guessing when there is no install' {
        $env:PTRSETUP_EXTRA_ROOTS = Join-Path $script:TestDrive 'not-a-game-folder'
        try {
            Assert-Equal $null (Find-WowFolder)
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    It 'offers each candidate folder once' {
        $env:PTRSETUP_EXTRA_ROOTS = @('/tmp/one', '/tmp/two', '/tmp/one') -join [System.IO.Path]::PathSeparator
        try {
            $candidates = @(Get-WowRootCandidate)
            Assert-Equal @($candidates | Select-Object -Unique).Count $candidates.Count 'Candidates should be deduped.'
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    It 'looks only at local fixed disks' {
        # Every PowerShell drive would include mapped network drives, where a
        # Test-Path against a disconnected share blocks until it times out.
        foreach ($drive in (Get-FixedDriveRoot)) {
            Assert-True (Test-Path -LiteralPath $drive) "Reported a drive that is not there: $drive"
        }
    }

    It 'always has a default folder to show, even with nothing installed' {
        $default = Get-WowDefaultRoot
        Assert-True ([bool]$default) 'There must always be something to put in the folder box.'
        Assert-True ($default -match 'World of Warcraft') "Expected a WoW path, got $default"
    }
}
