$live = @'
SET gxWindow "1"
SET gxResolution "2560x1440"
SET realmList "us.logon.worldofwarcraft.com"
# a comment line the parser ignores
SET Sound_MasterVolume "0.4"
'@

$ptr = @'
SET realmList "us.logon-ptr.worldofwarcraft.com"
SET gxWindow "0"
SET ptrOnlySetting "7"
'@

Describe 'ConvertFrom-ConfigWtf' {

    It 'reads SET lines and ignores everything else' {
        $parsed = ConvertFrom-ConfigWtf -Text $live
        Assert-Equal '2560x1440' $parsed['gxResolution']
        Assert-Equal 4 $parsed.Count
    }

    It 'returns an empty map for empty input' {
        Assert-Equal 0 (ConvertFrom-ConfigWtf -Text '').Count
    }

    It 'round-trips through ConvertTo-ConfigWtf' {
        $parsed = ConvertFrom-ConfigWtf -Text $live
        $again = ConvertFrom-ConfigWtf -Text (ConvertTo-ConfigWtf -Settings $parsed)
        Assert-Equal @($parsed.Keys) @($again.Keys)
        Assert-Equal @($parsed.Values) @($again.Values)
    }
}

Describe 'Merge-ConfigWtf' {

    It 'takes the live value for ordinary settings' {
        $merged = Merge-ConfigWtf -Source (ConvertFrom-ConfigWtf $live) -Target (ConvertFrom-ConfigWtf $ptr)
        Assert-Equal '1' $merged['gxWindow']
        Assert-Equal '2560x1440' $merged['gxResolution']
    }

    It 'keeps the PTR realm list' {
        $merged = Merge-ConfigWtf -Source (ConvertFrom-ConfigWtf $live) -Target (ConvertFrom-ConfigWtf $ptr)
        Assert-Equal 'us.logon-ptr.worldofwarcraft.com' $merged['realmList']
    }

    It 'preserves keys only the PTR has' {
        $merged = Merge-ConfigWtf -Source (ConvertFrom-ConfigWtf $live) -Target (ConvertFrom-ConfigWtf $ptr)
        Assert-Equal '7' $merged['ptrOnlySetting']
    }

    It 'lets an override win over both sides' {
        $merged = Merge-ConfigWtf -Source (ConvertFrom-ConfigWtf $live) -Target (ConvertFrom-ConfigWtf $ptr) `
            -Override ([ordered]@{ checkAddonVersion = '0'; gxWindow = '9' })
        Assert-Equal '0' $merged['checkAddonVersion']
        Assert-Equal '9' $merged['gxWindow']
    }

    It 'protects every documented client-specific key' {
        $target = [ordered]@{}
        foreach ($key in (Get-ProtectedConfigKey)) { $target[$key] = 'ptr-value' }
        $source = [ordered]@{}
        foreach ($key in (Get-ProtectedConfigKey)) { $source[$key] = 'live-value' }

        $merged = Merge-ConfigWtf -Source $source -Target $target
        foreach ($key in (Get-ProtectedConfigKey)) { Assert-Equal 'ptr-value' $merged[$key] }
    }
}

Describe 'Compare-ConfigWtf' {

    It 'labels added and changed keys, and stays quiet about protected ones' {
        $before = ConvertFrom-ConfigWtf $ptr
        $after = Merge-ConfigWtf -Source (ConvertFrom-ConfigWtf $live) -Target $before
        $changes = @(Compare-ConfigWtf -Before $before -After $after)

        $byKey = @{}
        foreach ($change in $changes) { $byKey[$change.Key] = $change.Kind }
        Assert-Equal 'changed' $byKey['gxWindow']
        Assert-Equal 'added' $byKey['gxResolution']
        Assert-False $byKey.ContainsKey('realmList')
    }

    It 'reports nothing when the two sides match' {
        $settings = ConvertFrom-ConfigWtf $live
        Assert-Equal 0 @(Compare-ConfigWtf -Before $settings -After $settings).Count
    }
}

Describe 'Read-ConfigWtf' {

    It 'returns an empty map when the file is missing' {
        Assert-Equal 0 (Read-ConfigWtf -Path (Join-Path $script:TestDrive 'nope.wtf')).Count
    }

    It 'reads a file from disk' {
        $path = New-TestFile -Path (Join-Path $script:TestDrive 'Config.wtf') -Content $live
        Assert-Equal '0.4' (Read-ConfigWtf -Path $path)['Sound_MasterVolume']
    }
}
