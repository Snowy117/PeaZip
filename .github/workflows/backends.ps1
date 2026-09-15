#!/usr/bin/env pwsh
################################################################################
# Populate PeaZip's res/bin on native arm64 Windows:
# official arm64 builds where available (7-Zip, brotli), sources compiled
# natively otherwise (zstd, zpaq, lpaq, bcm); the legacy FreeArc tools have
# no buildable sources and run through the x64 emulation layer instead.

param(
    [Parameter(Mandatory = $true)] [string]$OutDir
)

$ErrorActionPreference = 'stop'

$Work = Join-Path $Env:TEMP 'peazip-backends'
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Work | Out-Null

function Add-Native([string]$Name, [scriptblock]$Block) {
    try {
        & $Block
        Write-Host "native arm64: $Name"
        return $true
    } catch {
        Write-Warning "$Name native build failed, using WIN64 fallback: $_"
        return $false
    }
}

function Set-Backend([string]$Dir, [string]$Name, [scriptblock]$Block) {
    New-Item -ItemType Directory -Force (Join-Path $OutDir $Dir) | Out-Null
    if (Add-Native $Name $Block) { return }
    Copy-Item (Join-Path $UpBin "$Dir\*") (Join-Path $OutDir $Dir) -Recurse -Force
}

# upstream WIN64 portable package: x64 fallback source and FreeArc tools
$Portable = Join-Path $Work 'peazip_portable-WIN64.zip'
Invoke-WebRequest -Uri 'https://github.com/peazip/PeaZip/releases/download/11.2.0/peazip_portable-11.2.0.WIN64.zip' -OutFile $Portable
Expand-Archive $Portable (Join-Path $Work 'upstream-zip') -Force
$UpBin = (Get-ChildItem (Join-Path $Work 'upstream-zip') -Recurse -Directory -Filter 'bin' |
    Where-Object { $_.Parent.Name -eq 'res' } | Select-Object -First 1).FullName
if (-not $UpBin) { throw 'res\bin not found in upstream package' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

Copy-Item (Join-Path $UpBin 'arc\*') (Join-Path $OutDir 'arc') -Recurse -Force

Set-Backend '7z' '7-zip' {
    $Setup = Join-Path $Work '7z-arm64.exe'
    Invoke-WebRequest -Uri 'https://github.com/ip7z/7zip/releases/download/26.03/7z2603-arm64.exe' -OutFile $Setup
    & $Setup /S | Out-Null
    $SevenZip = 'C:\Program Files\7-Zip'
    if (-not (Test-Path (Join-Path $SevenZip '7z.exe'))) { throw '7-Zip install dir not found' }
    Remove-Item (Join-Path $OutDir '7z') -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory (Join-Path $OutDir '7z') | Out-Null
    Copy-Item (Join-Path $SevenZip '7z.exe'), (Join-Path $SevenZip '7z.dll') (Join-Path $OutDir '7z')
    foreach ($s in '7z.sfx', '7zCon.sfx') {
        $f = Join-Path $SevenZip $s
        if (Test-Path $f) { Copy-Item $f (Join-Path $OutDir '7z') }
    }
    Copy-Item (Join-Path $UpBin '7z\7zCon.linux.sfx') (Join-Path $OutDir '7z')
}

Set-Backend 'brotli' 'brotli' {
    $Zip = Join-Path $Work 'brotli-arm64.zip'
    Invoke-WebRequest -Uri 'https://github.com/google/brotli/releases/download/v1.2.0/brotli-arm64-windows-static.zip' -OutFile $Zip
    Expand-Archive $Zip (Join-Path $Work 'brotli') -Force
    $Exe = Get-ChildItem (Join-Path $Work 'brotli') -Recurse -Filter brotli.exe |
        Select-Object -First 1
    if (-not $Exe) { throw 'brotli.exe not found in archive' }
    Copy-Item $Exe.FullName (Join-Path $OutDir 'brotli')
}

Set-Backend 'zstd' 'zstd' {
    $Src = Join-Path $Work 'zstd'
    git clone --quiet --depth 1 --branch v1.5.7 https://github.com/facebook/zstd $Src
    $Sources = @(
        (Get-ChildItem "$Src\lib\common\*.c").FullName
        (Get-ChildItem "$Src\lib\compress\*.c").FullName
        (Get-ChildItem "$Src\lib\decompress\*.c").FullName
        (Get-ChildItem "$Src\lib\dictBuilder\*.c").FullName
        (Get-ChildItem "$Src\programs\*.c").FullName
    ) | ForEach-Object { $_ }
    clang -O2 -DZSTD_MULTITHREAD -DZSTD_LEGACY_SUPPORT=0 `
        "-I$Src\lib" "-I$Src\lib\common" "-I$Src\programs" `
        $Sources -o (Join-Path $OutDir 'zstd\zstd.exe')
}

Set-Backend 'zpaq' 'zpaq' {
    $Zip = Join-Path $Work 'zpaq715.zip'
    Invoke-WebRequest -Uri 'http://mattmahoney.net/dc/zpaq715.zip' -OutFile $Zip
    Expand-Archive $Zip (Join-Path $Work 'zpaq') -Force
    $Cpp = Get-ChildItem (Join-Path $Work 'zpaq') -Recurse -Filter zpaq.cpp |
        Select-Object -First 1
    if (-not $Cpp) { throw 'zpaq.cpp not found in archive' }
    clang++ -O3 -DNDEBUG -DNOJIT $Cpp.FullName "$($Cpp.Directory)\libzpaq.cpp" `
        -o (Join-Path $OutDir 'zpaq\zpaq.exe')
}

Set-Backend 'lpaq' 'lpaq' {
    $Zip = Join-Path $Work 'lpaq8.zip'
    Invoke-WebRequest -Uri 'http://mattmahoney.net/dc/lpaq8.zip' -OutFile $Zip
    Expand-Archive $Zip (Join-Path $Work 'lpaq') -Force
    $Cpp = Get-ChildItem (Join-Path $Work 'lpaq') -Recurse -Filter lpaq8.cpp |
        Select-Object -First 1
    if (-not $Cpp) { throw 'lpaq8.cpp not found in archive' }
    clang++ -O3 -DNDEBUG $Cpp.FullName -o (Join-Path $OutDir 'lpaq\lpaq8.exe')
}

Set-Backend 'quad' 'bcm' {
    $Src = Join-Path $Work 'bcm'
    git clone --quiet --depth 1 https://github.com/geekmaster/bcm $Src
    $Cpp = Get-ChildItem $Src -Recurse -Filter bcm.cpp | Select-Object -First 1
    if (-not $Cpp) { throw 'bcm.cpp not found in repository' }
    clang++ -O3 -DNDEBUG -x c++ $Cpp.FullName "$($Cpp.Directory)\divsufsort.c" `
        -o (Join-Path $OutDir 'quad\bcm.exe')
}

Write-Host 'backend binaries in use:'
Get-ChildItem $OutDir -Recurse -File | ForEach-Object { Write-Host "  $($_.FullName.Replace($OutDir, ''))" }
