<#
    Cross-check against the other tool that automates this job:
    https://github.com/Azevedoc/WoW-PTR-Config-Copier (CopyWoWConfigs.ps1).

    It automates the same Reddit thread docs/GUIDE.md is transcribed from, so it
    is a useful second opinion on what "copy my UI to the PTR" has to move. Every
    copy operation in its script is listed below, and the test asserts our step
    list plans a write for each one against a realistic install.

    This is a coverage floor, not a spec: where the two tools deliberately differ
    (Config.wtf is merged here, not pasted — GUIDE.md deviation 2) the difference
    is asserted rather than papered over.
#>

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$mockBuilder = Join-Path $repoRoot 'tools/New-MockWowFolder.ps1'

function Get-PlannedDestination {
    <#
        Every path the automated steps would write, as paths relative to the PTR
        client, with forward slashes so the expectations below read the same on
        either platform.
    #>
    param([Parameter(Mandatory)] [psobject] $Context)

    $planned = foreach ($step in (Get-PtrSetupStep | Where-Object { $_.Mode -eq 'auto' })) {
        foreach ($action in @(New-PtrSetupStepPlan -Step $step -Context $Context)) {
            if ($action.Kind -eq 'skip') { continue }
            (Get-PathRelative -Base $Context.Target.Path -Path $action.Destination) -replace '\\', '/'
        }
    }
    return @($planned | Sort-Object -Unique)
}

Describe 'Coverage against WoW-PTR-Config-Copier' {

    It 'plans a write for every file that tool copies' {
        $null = & $mockBuilder -Path $script:TestDrive -Force -Quiet
        $installs = @(Get-WowInstall -Path (Join-Path $script:TestDrive 'World of Warcraft') -SkipDefaultLocations)
        $context = Initialize-PtrSetupContext -Install $installs
        $planned = Get-PlannedDestination -Context $context

        $account = '112233445#1'
        $character = "WTF/Account/$account/Classic PTR Realm 1/Sunderfury"

        # Each entry is one copy operation in CopyWoWConfigs.ps1, in its order.
        $expected = [ordered]@{
            'AddOns (robocopy Interface\AddOns)'          = 'Interface/AddOns/WeakAuras/WeakAuras.lua'
            'Account-wide SavedVariables (robocopy)'      = "WTF/Account/$account/SavedVariables/WeakAuras.lua"
            'Character SavedVariables (robocopy)'         = "$character/SavedVariables/WeakAuras.lua"
            'Client game settings (Config.wtf)'           = 'WTF/Config.wtf'
            'Character game settings (config-cache.wtf)'  = "$character/config-cache.wtf"
            'Account-wide keybinds (bindings-cache.wtf)'  = "WTF/Account/$account/bindings-cache.wtf"
            'Character keybinds (bindings-cache.wtf)'     = "$character/bindings-cache.wtf"
            'Account-wide macros (macros-cache.txt/wtf)'  = "WTF/Account/$account/macros-cache.txt"
            'Character macros (macros-cache.txt/wtf)'     = "$character/macros-cache.txt"
        }

        foreach ($operation in $expected.Keys) {
            Assert-True ($planned -contains $expected[$operation]) `
                "CopyWoWConfigs.ps1 copies '$operation' but nothing here plans $($expected[$operation])."
        }
    }

    It 'also carries the per-character files that tool leaves behind' {
        # AddOns.txt is the enabled/disabled list and layout-local.txt is the
        # frame layout: without them the addons arrive but come up switched off
        # and in default positions, which is most of what the copy was for.
        $null = & $mockBuilder -Path $script:TestDrive -Force -Quiet
        $installs = @(Get-WowInstall -Path (Join-Path $script:TestDrive 'World of Warcraft') -SkipDefaultLocations)
        $context = Initialize-PtrSetupContext -Install $installs
        $planned = Get-PlannedDestination -Context $context

        $character = 'WTF/Account/112233445#1/Classic PTR Realm 1/Sunderfury'
        foreach ($extra in @("$character/AddOns.txt", "$character/layout-local.txt", 'WTF/Account/112233445#1/config-cache.wtf')) {
            Assert-True ($planned -contains $extra) "Expected to plan $extra."
        }
    }

    It 'refuses the one thing that tool does that would break the PTR client' {
        # CopyWoWConfigs.ps1 copies Config.wtf wholesale, which carries
        # realmList and portal over from live. GUIDE.md deviation 2: those keys
        # keep the PTR's own values here, so the PTR client stays on PTR realms.
        $null = & $mockBuilder -Path $script:TestDrive -Force -Quiet
        $installs = @(Get-WowInstall -Path (Join-Path $script:TestDrive 'World of Warcraft') -SkipDefaultLocations)
        $context = Initialize-PtrSetupContext -Install $installs
        $null = Invoke-PtrSetup -Context $context -StepId 'copy_config_wtf'

        $after = Read-ConfigWtf -Path $context.Target.ConfigWtf
        Assert-Equal 'us.logon-ptr.worldofwarcraft.com' $after['realmList']
        Assert-Equal 'us-ptr' $after['portal']
        # ...while the settings worth carrying did come across.
        Assert-Equal '2560x1440' $after['gxResolution']
    }

    It 'mirrors the addon folder the way that tool does with robocopy /MIR' {
        # Its "Yes" overwrite option is robocopy /MIR, which deletes anything in
        # the PTR folder the live client does not have. That is our ReplaceAddOns.
        $null = & $mockBuilder -Path $script:TestDrive -Force -Quiet
        $installs = @(Get-WowInstall -Path (Join-Path $script:TestDrive 'World of Warcraft') -SkipDefaultLocations)
        $context = Initialize-PtrSetupContext -Install $installs

        $mirrored = @(New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id 'copy_addons') -Context $context |
                Where-Object { $_.Kind -eq 'delete' })
        Assert-True ($mirrored.Count -gt 0) 'ReplaceAddOns should plan deletes for PTR-only addons.'
        Assert-True ([bool](@($mirrored.Destination) -like '*OldPtrAddon*')) `
            'The stale PTR-only addon should be the thing planned for removal.'

        # And with it off, nothing is removed — its "No" option.
        $context.Options['ReplaceAddOns'] = $false
        $kept = @(New-PtrSetupStepPlan -Step (Get-PtrSetupStep -Id 'copy_addons') -Context $context |
                Where-Object { $_.Kind -eq 'delete' })
        Assert-Equal 0 $kept.Count 'With ReplaceAddOns off nothing should be deleted.'
    }
}
