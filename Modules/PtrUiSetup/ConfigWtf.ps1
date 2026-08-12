<#
.SYNOPSIS
    Read and merge Config.wtf.

.DESCRIPTION
    Config.wtf is a flat list of SET key "value" lines holding client-wide
    settings (resolution, window mode, addon-version checking, ...). Copying the
    live file wholesale is the usual advice, but a few keys are client-specific
    — the realm list in particular points a client at a set of servers, and
    carrying the live value across can send the PTR client at live realms. So
    the merge keeps those keys from the target instead of overwriting them.
#>

# Keys that must keep the PTR client's own value.
$script:ProtectedConfigKeys = @(
    'realmList'
    'realmName'
    'portal'
    'agentUID'
    'accountName'
    'lastCharacterIndex'
)

function Get-ProtectedConfigKey {
    [CmdletBinding()]
    param()
    return $script:ProtectedConfigKeys
}

function ConvertFrom-ConfigWtf {
    <#
    .SYNOPSIS
        Parse Config.wtf text into an ordered key -> value map.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowEmptyString()] [string] $Text)

    $settings = [ordered]@{}
    if (-not $Text) { return $settings }

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*SET\s+([\w\.]+)\s+"(.*)"\s*$') {
            $settings[$Matches[1]] = $Matches[2]
        }
    }
    return $settings
}

function Read-ConfigWtf {
    <#
    .SYNOPSIS
        Parse a Config.wtf file, returning an empty map if it does not exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [ordered]@{} }
    return ConvertFrom-ConfigWtf -Text (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
}

function ConvertTo-ConfigWtf {
    <#
    .SYNOPSIS
        Render a settings map back to Config.wtf syntax, one SET per line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Settings)

    $lines = foreach ($key in $Settings.Keys) { 'SET {0} "{1}"' -f $key, $Settings[$key] }
    if (-not $lines) { return "`n" }
    return ($lines -join "`n") + "`n"
}

function Merge-ConfigWtf {
    <#
    .SYNOPSIS
        Overlay the live client's settings onto the PTR client's settings.

    .DESCRIPTION
        Target values win for protected keys; -Override wins over everything.
        Keys the target has and the source lacks are preserved.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Source,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Target,
        [string[]] $Protected = $script:ProtectedConfigKeys,
        [System.Collections.IDictionary] $Override
    )

    $merged = [ordered]@{}
    foreach ($key in $Target.Keys) { $merged[$key] = $Target[$key] }
    foreach ($key in $Source.Keys) {
        if ($Protected -contains $key) { continue }
        $merged[$key] = $Source[$key]
    }
    foreach ($key in $Protected) {
        if ($Target.Contains($key)) { $merged[$key] = $Target[$key] }
    }
    if ($Override) {
        foreach ($key in $Override.Keys) { $merged[$key] = $Override[$key] }
    }
    return $merged
}

function Compare-ConfigWtf {
    <#
    .SYNOPSIS
        Human-readable list of the changes a merge would make, for the preview.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Before,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $After
    )

    $keys = @(@($Before.Keys) + @($After.Keys) | Select-Object -Unique | Sort-Object)
    $changes = [System.Collections.Generic.List[psobject]]::new()
    foreach ($key in $keys) {
        $old = if ($Before.Contains($key)) { $Before[$key] } else { $null }
        $new = if ($After.Contains($key)) { $After[$key] } else { $null }
        if ($old -eq $new) { continue }

        $kind = if ($null -eq $old) { 'added' } elseif ($null -eq $new) { 'removed' } else { 'changed' }
        $changes.Add([pscustomobject]@{
                Key    = $key
                Before = [string]$old
                After  = [string]$new
                Kind   = $kind
            })
    }
    return @($changes)
}
