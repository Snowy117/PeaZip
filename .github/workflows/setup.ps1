#!/usr/bin/env pwsh
################################################################################

param(
    [string]$TargetCPU = '',
    [string]$TargetOS = ''
)

$ErrorActionPreference = 'stop'
Set-PSDebug -Strict
New-Variable -Option Constant -Name VAR -Value @{
    Uri = 'https://download.lazarus-ide.org/Lazarus%20Windows%2064%20bits/Lazarus%204.0/lazarus-4.0-fpc-3.2.2-win64.exe'
    OutFile = (New-TemporaryFile).FullName + '.exe'
}
Invoke-WebRequest @VAR
& $VAR.OutFile.Replace('Temp', 'Temp\.') /SP- /VERYSILENT /NORESTART `
    /SUPPRESSMSGBOXES | Out-Null
$Env:PATH+=';C:\Lazarus'
(Get-Command 'lazbuild').Source | Out-Host
$Env:PATH+=';C:\Lazarus\fpc\3.2.2\bin\x86_64-win64'
(Get-Command 'instantfpc').Source | Out-Host
$Env:INSTANTFPCOPTIONS='-FuC:\Lazarus\components\lazutils'

$MakeArgs = @('.github/workflows/make.pas', 'build')

if ($TargetCPU -ne '') {
    # The aarch64-win64 target is unavailable in the FPC 3.2.2 bundled with
    # Lazarus, so add the native FPC 3.3.1 compiler built for aarch64-win64
    # by the FPC team (daily snapshot). On a windows-11-arm runner it runs
    # natively, while lazbuild drives it through the x64 emulation layer.
    $FpcDir = 'C:\fpc-aarch64'
    $Snapshot = 'https://downloads.freepascal.org/fpc/snapshot/trunk/aarch64-win64/fpc-3.3.1.aarch64-win64.built.on.x86_64-linux.tar.gz'
    $Archive = Join-Path $Env:TEMP 'fpc-3.3.1-aarch64-win64.tar.gz'
    Invoke-WebRequest -Uri $Snapshot -OutFile $Archive
    New-Item -ItemType Directory -Force $FpcDir | Out-Null
    tar -xzf $Archive -C $FpcDir
    $CrossBin = Join-Path $FpcDir 'bin\aarch64-win64'
    # The snapshot ships without a configuration file: write one so the
    # compiler locates its own RTL and package units
    $UnitsRoot = Join-Path $FpcDir 'units\aarch64-win64'
    $Cfg = @("-Fu$(Join-Path $UnitsRoot 'rtl')")
    Get-ChildItem $UnitsRoot -Directory | ForEach-Object {
        $Cfg += "-Fu$($_.FullName)"
    }
    Set-Content -Path (Join-Path $CrossBin 'fpc.cfg') -Value $Cfg
    $MakeArgs += "--cpu=$TargetCPU", "--os=$TargetOS", "--compiler=$(Join-Path $CrossBin 'ppca64.exe')"
}

& instantfpc @MakeArgs | Out-Host
Exit $LastExitCode
