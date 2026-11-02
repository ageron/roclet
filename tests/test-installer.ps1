# Run on the Windows release runner, using the archive built by that job.
param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'
$Archive = (Resolve-Path $Archive).Path
$script:fixtureArchive = $Archive
$script:fixtureVersion = $Version
$assetName = Split-Path $Archive -Leaf
$checksum = (Get-FileHash $Archive -Algorithm SHA256).Hash
$savedLocal = $env:LOCALAPPDATA
$savedPath = $env:Path
$savedUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('roclet installer ' + [guid]::NewGuid())
New-Item -ItemType Directory $testRoot | Out-Null
$installer = Join-Path $PSScriptRoot '../install.ps1'
# Replace only the network calls; extraction, checksums, launchers and PATH are real.
function Invoke-RestMethod { param($Uri) return @{tag_name = "server-v$script:fixtureVersion"} }
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [Parameter(Position=0)]$Uri, $OutFile)
    if ($Uri.EndsWith('/SHA256SUMS')) { Set-Content -Encoding ASCII $OutFile "$checksum  $assetName"; return }
    if (!$Uri.EndsWith("/$assetName")) { throw "Unexpected download: $Uri" }
    Copy-Item $script:fixtureArchive $OutFile
}
try {
    $env:LOCALAPPDATA = $testRoot
    & $installer
    $launcher = Join-Path $testRoot 'Roclet/bin/roclet.cmd'
    & $launcher --help
    if ($LASTEXITCODE -ne 0) { throw 'Installed launcher failed.' }
    & $installer # Already installed should succeed.
    # Verify corrupted downloads are rejected before a launcher is created.
    $env:LOCALAPPDATA = Join-Path $testRoot 'bad checksum'
    $checksum = '0' * 64
    $rejected = $false
    try { & $installer } catch {
        if ($_.Exception.Message -notlike '*Checksum mismatch*') { throw }
        $rejected = $true
    }
    if (!$rejected -or (Test-Path "$env:LOCALAPPDATA/Roclet/bin/roclet.cmd")) { throw 'Corrupt archive was installed.' }
    Write-Host 'PASS Windows installer, launcher, repeat installation, and checksum rejection'
} finally {
    $env:LOCALAPPDATA = $savedLocal
    $env:Path = $savedPath
    [Environment]::SetEnvironmentVariable('Path', $savedUserPath, 'User')
    Remove-Item -Recurse -Force $testRoot
}
