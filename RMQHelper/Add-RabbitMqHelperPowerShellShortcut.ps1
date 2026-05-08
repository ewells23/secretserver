# ==============================================================================
# RabbitMQ Helper - Add "PowerShell" Start Menu Shortcut to Existing Install
# ==============================================================================
#
# Purpose:
#   Post-install patcher that adds a second Start Menu shortcut to an existing
#   RabbitMQ Helper installation. The new shortcut opens a PowerShell window
#   directly with the Helper module pre-loaded and a banner listing the
#   available cmdlets - bypassing the GUI for admins who only need cmdlets.
#
# What it does:
#   1. Locates the existing RabbitMQ Helper install directory (registry first,
#      then common Program Files paths, or honours -InstallPath).
#   2. Writes Show-HelperWelcome.ps1 into the install directory. The welcome
#      script imports Delinea.RabbitMqHelper.PSCommands and prints a banner
#      enumerating the real cmdlets via Get-Command.
#   3. Locates the existing GUI Start Menu folder (so the new shortcut sits
#      next to the existing "RabbitMQ Helper" entry) and creates a new .lnk
#      named "RabbitMQ Helper PowerShell" pointing at powershell.exe with
#      arguments to run the welcome script.
#
# Usage:
#   # Default - auto-discover everything, all-users Start Menu (needs admin):
#   .\Add-RabbitMqHelperPowerShellShortcut.ps1
#
#   # Override install or Start Menu location:
#   .\Add-RabbitMqHelperPowerShellShortcut.ps1 `
#       -InstallPath 'C:\Program Files\Thycotic Software Ltd\RabbitMq Helper' `
#       -StartMenuPath 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Delinea'
#
#   # Per-user shortcut (no admin required):
#   .\Add-RabbitMqHelperPowerShellShortcut.ps1 -CurrentUser
#
#   # Preview only (no changes written):
#   .\Add-RabbitMqHelperPowerShellShortcut.ps1 -WhatIf
#
#   # Replace an existing shortcut + welcome script:
#   .\Add-RabbitMqHelperPowerShellShortcut.ps1 -Force
#
# Removal:
#   .\Add-RabbitMqHelperPowerShellShortcut.ps1 -Uninstall
#
# Version:
#   1.0.2  - 2026-05-08  - fix Find-HelperInstallPath returning a single character
#                          when only one candidate matches (single-element pipeline
#                          was collapsing to a string scalar; @() wrapper forces
#                          array semantics so [0] indexes the element, not the char).
#   1.0.1  - 2026-05-08  - welcome script auto-discovers *PSCommands.{psd1,dll}
#                          (tolerates Delinea.RabbitMq.Helper.PSCommands.dll name);
#                          added "Delinea Software Ltd" to install-path fallbacks.
#   1.0.0  - 2026-05-08  - initial cut.
# ==============================================================================

#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Uninstall')]
    [string] $InstallPath,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Uninstall')]
    [string] $StartMenuPath,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Uninstall')]
    [string] $ShortcutName = 'RabbitMQ Helper PowerShell',

    [Parameter(ParameterSetName = 'Install')]
    [switch] $CurrentUser,

    [Parameter(ParameterSetName = 'Install')]
    [switch] $Force,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$WelcomeScriptName     = 'Show-HelperWelcome.ps1'

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]::new($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-HelperInstallPath {
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entry = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and
            $_.DisplayName -match 'RabbitMq.*Helper' -and
            $_.InstallLocation
        } |
        Select-Object -First 1

    if ($entry -and (Test-Path $entry.InstallLocation)) {
        Write-Verbose "Found install via registry: $($entry.DisplayName) -> $($entry.InstallLocation)"
        return $entry.InstallLocation.TrimEnd('\')
    }

    # @(...) wrapper forces array semantics even when Where-Object yields one match -
    # otherwise $candidates[0] would index into the single-string scalar and return 'C'.
    $candidates = @(
        @(
            (Join-Path $env:ProgramFiles        'Delinea Software Ltd\RabbitMq Helper'),
            (Join-Path $env:ProgramFiles        'Thycotic Software Ltd\RabbitMq Helper'),
            (Join-Path $env:ProgramFiles        'Delinea\RabbitMq Helper'),
            (Join-Path ${env:ProgramFiles(x86)} 'Delinea Software Ltd\RabbitMq Helper'),
            (Join-Path ${env:ProgramFiles(x86)} 'Thycotic Software Ltd\RabbitMq Helper'),
            (Join-Path ${env:ProgramFiles(x86)} 'Delinea\RabbitMq Helper')
        ) | Where-Object { $_ -and (Test-Path $_) }
    )

    if ($candidates.Count -gt 0) {
        $found = $candidates[0]
        Write-Verbose "Found install via fallback path: $found"
        return $found
    }

    return $null
}

function Find-HelperStartMenuFolder {
    param([switch] $CurrentUser)

    $roots = if ($CurrentUser) {
        @([Environment]::GetFolderPath('Programs'))
    } else {
        @([Environment]::GetFolderPath('CommonPrograms'))
    }

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }

        $existing = Get-ChildItem -Path $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^RabbitMq.*Helper$' -or $_.BaseName -match '^RabbitMQ Helper$' } |
            Select-Object -First 1

        if ($existing) {
            Write-Verbose "Found existing Helper shortcut: $($existing.FullName)"
            return $existing.Directory.FullName
        }
    }

    foreach ($root in $roots) {
        foreach ($vendor in @('Delinea', 'Thycotic Software Ltd', 'Thycotic')) {
            $folder = Join-Path $root $vendor
            if (Test-Path $folder) {
                Write-Verbose "Found vendor Start Menu folder: $folder"
                return $folder
            }
        }
    }

    return $null
}

function Get-WelcomeScriptContent {
    @'
# Auto-generated by Add-RabbitMqHelperPowerShellShortcut.ps1.
# Imports the Helper PSCommands module and prints a discovery banner.
$ErrorActionPreference = 'Stop'

$installDir = $PSScriptRoot

# Auto-discover the PSCommands module - tolerates name drift across versions
# (e.g. Delinea.RabbitMq.Helper.PSCommands.dll vs Delinea.RabbitMqHelper.PSCommands.dll).
$moduleFile = Get-ChildItem -LiteralPath $installDir -Filter '*PSCommands.psd1' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
if (-not $moduleFile) {
    $moduleFile = Get-ChildItem -LiteralPath $installDir -Filter '*PSCommands.dll' -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
}

if (-not $moduleFile) {
    Write-Warning "RabbitMQ Helper PSCommands module not found in $installDir."
    Write-Warning "Looked for *PSCommands.psd1 / *PSCommands.dll. Reinstall the Helper to recover."
    return
}

Import-Module $moduleFile.FullName -ErrorAction Stop
$moduleName = [IO.Path]::GetFileNameWithoutExtension($moduleFile.Name)

Set-Location $installDir

$line = '=' * 72
Write-Host ''
Write-Host $line                                            -ForegroundColor Cyan
Write-Host '  RabbitMQ Helper - PowerShell Console'         -ForegroundColor Cyan
Write-Host $line                                            -ForegroundColor Cyan
Write-Host ''
Write-Host "  Module loaded : $moduleName"
Write-Host "  Install dir   : $installDir"
Write-Host ''

$cmds = Get-Command -Module $moduleName -ErrorAction SilentlyContinue |
    Sort-Object Verb, Noun

if ($cmds) {
    Write-Host '  Available cmdlets:' -ForegroundColor Cyan
    foreach ($c in $cmds) {
        Write-Host ('    {0}' -f $c.Name)
    }
    Write-Host ''
    Write-Host "  Tip: 'Get-Help <cmdlet> -Full' for detailed usage." -ForegroundColor DarkGray
    Write-Host "       'Get-Command -Module $moduleName' to re-list." -ForegroundColor DarkGray
} else {
    Write-Warning "Module imported but exported no cmdlets - check the install."
}

Write-Host ''
Write-Host $line -ForegroundColor Cyan
Write-Host ''
'@
}

function Resolve-PowerShellExe {
    $candidate = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $candidate) { return $candidate }

    $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw 'Could not locate powershell.exe.'
}

function Resolve-IconLocation {
    param([string] $InstallPath)

    $candidates = @(
        'Delinea.RabbitMq.Helper.UI.exe',
        'Thycotic.RabbitMq.Helper.UI.exe',
        'Delinea.RabbitMq.Helper.exe',
        'Thycotic.RabbitMq.Helper.exe'
    )

    foreach ($name in $candidates) {
        $full = Join-Path $InstallPath $name
        if (Test-Path $full) { return ('{0},0' -f $full) }
    }

    return ('{0},0' -f (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))
}

function New-HelperShortcut {
    param(
        [Parameter(Mandatory)] [string] $ShortcutPath,
        [Parameter(Mandatory)] [string] $InstallPath,
        [Parameter(Mandatory)] [string] $WelcomeScriptPath
    )

    $pwshExe   = Resolve-PowerShellExe
    $icon      = Resolve-IconLocation -InstallPath $InstallPath
    $argString = '-NoExit -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $WelcomeScriptPath

    $wsh = New-Object -ComObject WScript.Shell
    try {
        $lnk = $wsh.CreateShortcut($ShortcutPath)
        $lnk.TargetPath       = $pwshExe
        $lnk.Arguments        = $argString
        $lnk.WorkingDirectory = $InstallPath
        $lnk.IconLocation     = $icon
        $lnk.Description      = 'Open a PowerShell session with the RabbitMQ Helper module pre-loaded.'
        $lnk.WindowStyle      = 1
        $lnk.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
    }
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

# Discover install path.
if (-not $InstallPath) {
    $InstallPath = Find-HelperInstallPath
    if (-not $InstallPath) {
        throw "Could not locate a RabbitMQ Helper installation. Pass -InstallPath explicitly."
    }
}
if (-not (Test-Path $InstallPath)) {
    throw "InstallPath does not exist: $InstallPath"
}
$InstallPath = (Resolve-Path $InstallPath).Path.TrimEnd('\')
Write-Verbose "Install path: $InstallPath"

# Discover Start Menu folder.
if (-not $StartMenuPath) {
    $StartMenuPath = Find-HelperStartMenuFolder -CurrentUser:$CurrentUser
    if (-not $StartMenuPath) {
        $root = if ($CurrentUser) {
            [Environment]::GetFolderPath('Programs')
        } else {
            [Environment]::GetFolderPath('CommonPrograms')
        }
        $StartMenuPath = Join-Path $root 'Delinea'
        Write-Verbose "No existing Helper folder found - will use $StartMenuPath."
    }
}
Write-Verbose "Start Menu folder: $StartMenuPath"

# Elevation check (only required for All Users / Program Files writes).
$writesAllUsers = -not $CurrentUser
$writesProgramFiles = $InstallPath -like ([Environment]::GetFolderPath('ProgramFiles') + '*') `
    -or $InstallPath -like (${env:ProgramFiles(x86)} + '*')

if (($writesAllUsers -or $writesProgramFiles) -and -not (Test-IsElevated)) {
    throw "Administrator rights are required to write to $InstallPath or the All Users Start Menu. Re-run from an elevated PowerShell, or use -CurrentUser with a per-user install."
}

$welcomeScriptPath = Join-Path $InstallPath $WelcomeScriptName
$shortcutPath      = Join-Path $StartMenuPath ($ShortcutName + '.lnk')

# ----- Uninstall path ---------------------------------------------------------
if ($Uninstall) {
    if (Test-Path $shortcutPath) {
        if ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove shortcut')) {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Host "Removed shortcut: $shortcutPath"
        }
    } else {
        Write-Host "Shortcut not present: $shortcutPath"
    }

    if (Test-Path $welcomeScriptPath) {
        if ($PSCmdlet.ShouldProcess($welcomeScriptPath, 'Remove welcome script')) {
            Remove-Item -LiteralPath $welcomeScriptPath -Force
            Write-Host "Removed welcome script: $welcomeScriptPath"
        }
    } else {
        Write-Host "Welcome script not present: $welcomeScriptPath"
    }

    return
}

# ----- Install path -----------------------------------------------------------

# Refuse to overwrite without -Force.
if ((Test-Path $shortcutPath) -and -not $Force) {
    throw "Shortcut already exists at $shortcutPath. Re-run with -Force to replace, or -Uninstall to remove."
}
if ((Test-Path $welcomeScriptPath) -and -not $Force) {
    Write-Verbose "Welcome script already exists - will overwrite: $welcomeScriptPath"
}

# Ensure Start Menu folder exists.
if (-not (Test-Path $StartMenuPath)) {
    if ($PSCmdlet.ShouldProcess($StartMenuPath, 'Create Start Menu folder')) {
        New-Item -ItemType Directory -Path $StartMenuPath -Force | Out-Null
    }
}

# Write welcome script.
if ($PSCmdlet.ShouldProcess($welcomeScriptPath, 'Write welcome script')) {
    $content = Get-WelcomeScriptContent
    [IO.File]::WriteAllText($welcomeScriptPath, $content, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote welcome script: $welcomeScriptPath"
}

# Create shortcut.
if ($PSCmdlet.ShouldProcess($shortcutPath, 'Create Start Menu shortcut')) {
    New-HelperShortcut `
        -ShortcutPath      $shortcutPath `
        -InstallPath       $InstallPath `
        -WelcomeScriptPath $welcomeScriptPath
    Write-Host "Created shortcut : $shortcutPath"
    Write-Host "  Target  : $(Resolve-PowerShellExe)"
    Write-Host "  Args    : -NoExit -NoProfile -ExecutionPolicy Bypass -File `"$welcomeScriptPath`""
    Write-Host "  WorkDir : $InstallPath"
}

Write-Host ''
Write-Host 'Done. Open the Start Menu and verify the new entry under the Delinea group.'
