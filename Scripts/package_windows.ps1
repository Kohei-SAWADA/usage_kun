#!/usr/bin/env pwsh
#Requires -Version 7
<#
Builds the Windows release zip, the counterpart of package_release_zip.sh.

Usage (from the repository root, on Windows with the .NET 8 SDK):
  pwsh ./Scripts/package_windows.ps1                      # self-contained win-x64
  pwsh ./Scripts/package_windows.ps1 -Runtime win-arm64   # self-contained win-arm64
  pwsh ./Scripts/package_windows.ps1 -FrameworkDependent  # small zip, needs .NET 8 runtime

Produces UsageKun-Windows-<arch>.zip in the repository root.
#>
param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64",
    [switch]$FrameworkDependent
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent $PSScriptRoot
$appProject = Join-Path $rootDir "Windows/src/UsageKun.App"
$checkProject = Join-Path $rootDir "Windows/tests/UsageKun.Core.Check"
$publishDir = Join-Path $rootDir "Windows/publish/$Runtime"
$archLabel = $Runtime -replace '^win-', ''
$zipPath = Join-Path $rootDir "UsageKun-Windows-$archLabel.zip"

# Core-logic check first; a release zip must never ship failing core logic.
dotnet run --project $checkProject -c Release
if ($LASTEXITCODE -ne 0) {
    throw "UsageKun.Core.Check failed; not packaging."
}

if (Test-Path $publishDir) {
    Remove-Item -Recurse -Force $publishDir
}

$selfContained = -not $FrameworkDependent
dotnet publish $appProject `
    -c Release `
    -r $Runtime `
    --self-contained $selfContained `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=none `
    -o $publishDir
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed."
}

if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}
$exePath = Join-Path $publishDir "UsageKun.exe"
if (-not (Test-Path $exePath)) { throw "Published UsageKun.exe is missing." }
Compress-Archive -Path (Join-Path $publishDir "*") -DestinationPath $zipPath
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path -Leaf $zipPath)" | Set-Content -Encoding ascii "$zipPath.sha256"

Write-Host "Built $zipPath"
