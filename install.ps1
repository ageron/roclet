# Install the latest Roclet server, or pass -Version 0.2.0.
param([string]$Version = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$base = 'https://github.com/ageron/roclet/releases'
if ($env:OS -ne 'Windows_NT' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'This installer supports Windows x64. Use install.sh on macOS or Linux.'
}
if (!$Version) {
    $release = Invoke-RestMethod 'https://api.github.com/repos/ageron/roclet/releases/latest'
    if ($release.tag_name -notmatch '^server-v(\d+\.\d+\.\d+)$') { throw 'No latest server release found. Pass -Version explicitly.' }
    $Version = $Matches[1]
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Expected a version such as 0.2.0.' }
$root = Join-Path $env:LOCALAPPDATA 'Roclet'
$bin = Join-Path $root 'bin'
$launcher = Join-Path $bin 'roclet.cmd'
if ((Test-Path $launcher) -and !(Select-String -Path $launcher -SimpleMatch 'rem Roclet installer launcher' -Quiet)) {
    throw "$launcher already exists and is not managed by this installer. Move it first."
}
$destination = Join-Path $root "versions\$Version-windows-x64"
if (Test-Path $destination) {
    if ((Test-Path "$destination\roclet.exe") -and (Test-Path $launcher) -and (Select-String -Path $launcher -SimpleMatch "versions\$Version-windows-x64\roclet.exe" -Quiet)) {
        Write-Host "Roclet $Version is already installed. Run: roclet serve"
        return
    }
    throw "$destination already exists; move it before reinstalling this version."
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $url = "$base/download/server-v$Version"
    $checksumFile = Join-Path $tmp 'SHA256SUMS'
    Invoke-WebRequest -UseBasicParsing "$url/SHA256SUMS" -OutFile $checksumFile
    $checksums = Get-Content -Raw $checksumFile
    $archive = "roclet-$Version-windows-x64.zip"
    $match = [regex]::Match($checksums, "(?m)^([a-fA-F0-9]{64})\s+$([regex]::Escape($archive))\r?`$")
    if (!$match.Success) {
        $archive = 'roclet-windows-x64.zip'
        $match = [regex]::Match($checksums, "(?m)^([a-fA-F0-9]{64})\s+$([regex]::Escape($archive))\r?`$")
    }
    if (!$match.Success) { throw 'Archive missing from release checksums.' }
    $zip = Join-Path $tmp $archive
    Invoke-WebRequest -UseBasicParsing "$url/$archive" -OutFile $zip
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $match.Groups[1].Value) { throw 'Checksum mismatch; installation cancelled.' }
    Expand-Archive -Path $zip -DestinationPath $tmp
    $extracted = Join-Path $tmp 'roclet'
    if (!(Test-Path "$extracted\roclet.exe") -or !(Test-Path "$extracted\index.html")) { throw 'Incomplete server archive.' }
    New-Item -ItemType Directory -Force -Path $bin, (Split-Path $destination) | Out-Null
    Move-Item $extracted $destination
    "@echo off`r`nrem Roclet installer launcher`r`n`"%LOCALAPPDATA%\Roclet\versions\$Version-windows-x64\roclet.exe`" %*`r`n" | Set-Content -Encoding ASCII $launcher
    $path = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($path -split ';') -notcontains $bin) { [Environment]::SetEnvironmentVariable('Path', "$bin;$path", 'User') }
    $env:Path = "$bin;$env:Path"
    Write-Host "Installed Roclet $Version. Run: roclet serve"
} finally {
    Remove-Item -Recurse -Force $tmp
}
