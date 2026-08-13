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
    <#
        -SkipDefaultLocations throughout. Without it these pass or fail depending
        on whether the machine running them has World of Warcraft installed: a
        real install in a conventional folder is found before the fake one this
        test just built, which is correct behaviour and a useless test.
    #>

    It 'returns the World of Warcraft folder, not the client folder inside it' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $env:PTRSETUP_EXTRA_ROOTS = $root
        try {
            Assert-Equal ([System.IO.Path]::GetFullPath($root)) (Find-WowFolder -SkipDefaultLocations)
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    It 'accepts being pointed at a client folder and still reports its parent' {
        # People paste whichever folder their explorer happens to be showing.
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $env:PTRSETUP_EXTRA_ROOTS = Join-Path $root '_classic_'
        try {
            Assert-Equal ([System.IO.Path]::GetFullPath($root)) (Find-WowFolder -SkipDefaultLocations)
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    It 'returns nothing rather than guessing when there is no install' {
        $env:PTRSETUP_EXTRA_ROOTS = Join-Path $script:TestDrive 'not-a-game-folder'
        try {
            Assert-Equal $null (Find-WowFolder -SkipDefaultLocations)
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    function Use-FakeInstalledCopy {
        <#
            Runs a scriptblock with the module believing the game is installed at
            -Path, and puts the real registry lookup back afterwards.

            Without this the ordering tests below are vacuous anywhere the game
            is not actually installed — which is every machine CI runs on, and
            was every machine this code was written on. Injecting the "installed"
            copy is what makes them fail when the ordering is wrong.
        #>
        param(
            [Parameter(Mandatory)] [string] $Path,
            [Parameter(Mandatory)] [scriptblock] $Body
        )

        $module = Get-Module PtrUiSetup
        $original = & $module { ${function:Get-WowRegistryPath} }
        & $module ([scriptblock]::Create("function script:Get-WowRegistryPath { @('$Path') }"))
        try { & $Body }
        finally { & $module { param($f) Set-Item -Path function:script:Get-WowRegistryPath -Value $f } $original }
    }

    It 'lets an override win over a copy that is really installed' {
        $installed = New-FakeWowRoot -Parent (Join-Path $script:TestDrive 'installed')
        $override = New-FakeWowRoot -Parent (Join-Path $script:TestDrive 'override')

        Use-FakeInstalledCopy -Path $installed -Body {
            # Detection alone finds the installed copy...
            Assert-Equal ([System.IO.Path]::GetFullPath($installed)) (Find-WowFolder)

            # ...but an explicit override beats it, because Find-WowFolder takes
            # the first candidate holding a client and the override is offered
            # first. Offered last, the installed copy would shadow it.
            $env:PTRSETUP_EXTRA_ROOTS = $override
            try {
                Assert-Equal ([System.IO.Path]::GetFullPath($override)) (Find-WowFolder)
            }
            finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
        }
    }

    It 'ignores a really-installed copy when told to skip the defaults' {
        $installed = New-FakeWowRoot -Parent (Join-Path $script:TestDrive 'installed')

        Use-FakeInstalledCopy -Path $installed -Body {
            Assert-Equal ([System.IO.Path]::GetFullPath($installed)) (Find-WowFolder)
            # This is what keeps every other test in this file honest.
            Assert-Equal $null (Find-WowFolder -SkipDefaultLocations)
        }
    }

    It 'offers an explicit override before anything it detects' {
        # This is the ordering that matters, and it cannot be checked through
        # Find-WowFolder on a machine with nothing installed — there is nothing
        # for the override to be preferred over. Checking the candidate list
        # directly holds either way: an override the registry can shadow is an
        # override that does not work on exactly the machines that need it.
        # Built from TestDrive rather than written out: the separator between
        # entries is ';' on Windows but ':' on Linux, so a literal 'X:\...' would
        # be split down the middle by the very code under test.
        $override = Join-Path $script:TestDrive 'somewhere/World of Warcraft'
        $env:PTRSETUP_EXTRA_ROOTS = $override
        try {
            Assert-Equal $override @(Get-WowRootCandidate)[0] `
                'PTRSETUP_EXTRA_ROOTS must be tried first, or an installed copy shadows it.'
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    It 'stops at the first candidate that actually holds a client' {
        $root = New-FakeWowRoot -Parent $script:TestDrive
        $empty = Join-Path $script:TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $empty -Force
        $env:PTRSETUP_EXTRA_ROOTS = @($empty, $root) -join [System.IO.Path]::PathSeparator
        try {
            Assert-Equal ([System.IO.Path]::GetFullPath($root)) (Find-WowFolder -SkipDefaultLocations) `
                'A folder with no client in it should be passed over, not returned.'
        }
        finally { $env:PTRSETUP_EXTRA_ROOTS = $null }
    }

    It 'offers nothing at all when told to skip the defaults and given no override' {
        $env:PTRSETUP_EXTRA_ROOTS = $null
        Assert-Equal 0 @(Get-WowRootCandidate -SkipDefaultLocations).Count
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
