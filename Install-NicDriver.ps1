<#
.SYNOPSIS
    Post-install injection of a Broadcom NetXtreme-E BCM57414 or Intel Ethernet
    800 Series (E810) NIC driver on an Azure Local (build 2609) node where the
    inbox driver failed to bind.

.DESCRIPTION
    Option C workflow: run this ON the node after the OS is already installed but
    the NIC came up with no network driver. It stages the extracted driver
    package, installs every .inf with pnputil, and verifies the NIC is present.

    Run in an elevated PowerShell session (Administrator).

.PARAMETER DriverPath
    Folder containing the extracted Windows driver package for the target NIC:
      - Broadcom NetXtreme-E: holds bnxtnd*.inf (from Broadcom or the Dell
        AX-650/AX-660 catalog, same NIC ASIC).
      - Intel E810: holds icea*.inf (from the Intel Download Center "Intel
        Ethernet 800 Series" Windows Server driver / Complete Driver Pack).

.PARAMETER RescanOnly
    Skip installation and only trigger a hardware rescan + status report. Useful
    after a driver was already added to confirm the NIC bound.

.EXAMPLE
    .\Install-NicDriver.ps1 -DriverPath 'D:\bcm57414'

.EXAMPLE
    .\Install-NicDriver.ps1 -DriverPath 'D:\e810' -Verbose
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DriverPath,

    [switch]$RescanOnly
)

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated (Administrator) PowerShell session.'
    }
}

function Get-TargetAdapter {
    # Broadcom BCM57414: VEN_14E4/DEV_16D7. Intel E810: VEN_8086/DEV_1592|1593|159B.
    $pattern = 'VEN_14E4&DEV_16D7|VEN_8086&DEV_(1592|1593|159B)'
    Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match $pattern }
}

function Show-NicStatus {
    $adapters = Get-TargetAdapter
    if (-not $adapters) {
        Write-Warning 'No BCM57414 or Intel E810 NIC detected yet.'
        return
    }
    Write-Host "`nTarget NIC status:" -ForegroundColor Cyan
    $adapters |
        Select-Object Status, Class, FriendlyName, InstanceId |
        Format-Table -AutoSize
}

Assert-Administrator

if (-not $RescanOnly) {
    if (-not (Test-Path -LiteralPath $DriverPath)) {
        throw "DriverPath not found: $DriverPath"
    }

    $infFiles = Get-ChildItem -LiteralPath $DriverPath -Recurse -Filter '*.inf' -File
    if (-not $infFiles) {
        throw "No .inf files found under '$DriverPath'. Point -DriverPath at the extracted Broadcom NetXtreme-E driver folder."
    }

    Write-Host "Found $($infFiles.Count) .inf file(s) to install." -ForegroundColor Cyan

    foreach ($inf in $infFiles) {
        Write-Host "Installing driver: $($inf.FullName)" -ForegroundColor Green
        # /install binds the driver to matching present hardware; /add-driver stages it.
        pnputil.exe /add-driver "$($inf.FullName)" /install
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
            Write-Warning "pnputil returned exit code $LASTEXITCODE for $($inf.Name)."
        }
    }
}

Write-Host "`nTriggering hardware rescan..." -ForegroundColor Cyan
pnputil.exe /scan-devices | Out-Null

Show-NicStatus

Write-Host "`nCurrently staged NIC driver packages:" -ForegroundColor Cyan
pnputil.exe /enum-drivers |
    Select-String -Pattern 'bnxt', 'NetXtreme', 'Broadcom', 'icea', 'E810', 'Intel.*Ethernet' -Context 0, 3

Write-Host "`nDone. If Status shows 'OK', re-run the Azure Arc / cloud deployment step so the node registers with a working NIC." -ForegroundColor Yellow
