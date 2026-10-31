#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    下载并解压 OBS obs-deps 的 Qt6 依赖包到 $ProjectRoot/.deps。

.DESCRIPTION
    - 版本：-Version 参数，否则读取 $ProjectRoot/.version
    - 平台：-Platform，默认按当前系统自动检测（windows / macos）
    - 架构：-Arch，默认按当前 CPU 自动检测，仅接受 arm64 / x64
      （macOS 上 x64 会自动映射为包名中的 x86_64）
    - 下载：Invoke-WebRequest（cmdlet）
    - 解压：zip 用 Expand-Archive（cmdlet）；.tar.xz 用系统自带 tar
    - 项目根目录默认为脚本所在目录的父目录（脚本应放在 $ProjectRoot/scripts/ 下）

.PARAMETER Version
    依赖版本，例如 2026-07-15。省略时读取 $ProjectRoot/.version。

.PARAMETER Platform
    windows 或 macos。省略时按当前系统自动检测。

.PARAMETER Arch
    arm64 或 x64。省略时按当前 CPU 自动检测。

.PARAMETER ProjectRoot
    项目根目录，默认为 $PSScriptRoot 的父目录。
    .version 与 .deps 都在此目录下。

.PARAMETER Force
    强制重新下载并重新解压（会删除已存在的解压目录）。

.PARAMETER GitHubToken
    GitHub API 令牌，用于读取 release asset 的 SHA-256。省略时读取 GITHUB_TOKEN。

.EXAMPLE
    .\Install-ObsQtDependency.ps1
    # 读 .version，自动识别平台/架构

.EXAMPLE
    .\Install-ObsQtDependency.ps1 -Version 2026-07-15 -Platform macos -Arch arm64

.EXAMPLE
    .\Install-ObsQtDependency.ps1 -ProjectRoot C:\src\myproj -Force
#>

[CmdletBinding()]
param(
    [Parameter()] [string]$Version,
    [Parameter()] [ValidateSet('windows', 'macos')] [string]$Platform,
    [Parameter()] [ValidateSet('arm64', 'x64')]     [string]$Arch,
    [Parameter()] [switch]$Force,
    [Parameter()] [string]$GitHubToken = $env:GITHUB_TOKEN,
    [Parameter()] [string]$ProjectRoot = (Split-Path -Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

# --- 平台检测 ---
if (-not $Platform) {
    if ($IsWindows) { $Platform = 'windows' }
    elseif ($IsMacOS) { $Platform = 'macos' }
    else { throw '当前平台不支持自动检测，请显式指定 -Platform（windows / macos）。' }
}

# --- 架构检测（参数层面只有 arm64 / x64）---
if (-not $Arch) {
    $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $Arch = switch ($osArch) {
        'Arm64' { 'arm64' }
        'X64' { 'x64' }
        'X86' { throw 'x86（32 位）不受支持，仅支持 arm64 / x64。' }
        default { throw "不支持的 CPU 架构：$osArch" }
    }
}

# --- 版本 ---
if (-not $Version) {
    $versionFile = Join-Path $ProjectRoot '.version'
    if (-not (Test-Path -LiteralPath $versionFile)) {
        throw "未指定 -Version，且版本文件不存在：$versionFile"
    }
    $Version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($Version)) { throw '版本号为空。' }

# --- 包名与 URL：macOS 的 x64 在包名里是 x86_64 ---
$archInName = $Platform -eq 'macos' -and $Arch -eq 'x64' ? 'x86_64' : $Arch
$ext = $Platform -eq 'windows' ? 'zip' : 'tar.xz'
$archiveName = "$Platform-deps-qt6-$Version-$archInName.$ext"
$url = "https://github.com/obsproject/obs-deps/releases/download/$Version/$archiveName"

# --- 从 GitHub Releases API 获取可信 SHA-256 ---
$apiUri = "https://api.github.com/repos/obsproject/obs-deps/releases/tags/$([uri]::EscapeDataString($Version))"
$apiHeaders = @{
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'OBSharp.Interop.Qt'
}
if ($GitHubToken) {
    $apiHeaders.Authorization = "Bearer $GitHubToken"
}

Write-Host "从 GitHub API 查询校验和：$archiveName" -ForegroundColor Cyan
$release = Invoke-RestMethod -Uri $apiUri -Headers $apiHeaders
$asset = @($release.assets | Where-Object { $_.name -ceq $archiveName })
if ($asset.Count -ne 1) {
    throw "GitHub release '$Version' 中应有且仅有一个资产 '$archiveName'，实际找到 $($asset.Count) 个。"
}
if ($asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
    throw "GitHub API 未为 '$archiveName' 提供有效的 SHA-256 digest。"
}
$expectedHash = $Matches[1].ToUpperInvariant()

# --- 目录准备 ---
$depsDir = Join-Path $ProjectRoot '.deps'
$cacheDir = Join-Path $ProjectRoot '.cache'
$archivePath = Join-Path $cacheDir $archiveName
$extractRootName = $archiveName -replace '\.(zip|tar\.xz)$', ''
$extractTarget = Join-Path $depsDir $extractRootName

New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

# --- 校验缓存；下载完成后校验再写入缓存 ---
$hasValidArchive = $false
if (-not $Force -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    $cachedHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($cachedHash -eq $expectedHash) {
        Write-Host "缓存校验通过：$archivePath"
        $hasValidArchive = $true
    }
    else {
        Write-Warning "缓存校验失败，将重新下载：$archivePath"
        Remove-Item -LiteralPath $archivePath -Force
    }
}

if (-not $hasValidArchive) {
    Write-Host "下载：$url" -ForegroundColor Cyan
    $downloadPath = Join-Path $cacheDir "$archiveName.$([guid]::NewGuid().ToString('N')).download"
    try {
        Invoke-WebRequest -Uri $url -OutFile $downloadPath
        $downloadHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
        if ($downloadHash -ne $expectedHash) {
            throw "SHA-256 校验失败：期望 $expectedHash，实际 $downloadHash。"
        }
        Move-Item -LiteralPath $downloadPath -Destination $archivePath -Force
        Write-Host "下载校验通过：$archivePath"
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force
        }
    }
}

# --- 解压 ---
if ((Test-Path -LiteralPath $extractTarget) -and -not $Force) {
    Write-Host "目标已存在，跳过解压：$extractTarget"
    return
}
if (Test-Path -LiteralPath $extractTarget) {
    Write-Host "删除旧目录：$extractTarget"
    Remove-Item -LiteralPath $extractTarget -Recurse -Force
}

if ($ext -eq 'zip') {
    Write-Host "解压（Expand-Archive）：$archiveName -> $depsDir"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $depsDir -Force
}
else {
    $tarCmd = Get-Command -Name tar -ErrorAction SilentlyContinue
    if (-not $tarCmd) {
        throw '系统中找不到 tar 命令，无法解压 .tar.xz。'
    }
    Write-Host "解压（tar）：$archiveName -> $depsDir"
    & tar -xf $archivePath -C $depsDir
    if ($LASTEXITCODE -ne 0) { throw "tar 解压失败，退出码 $LASTEXITCODE" }
}

if (-not (Test-Path -LiteralPath $extractTarget)) {
    Write-Warning "解压完成，但预期目录不存在：$extractTarget（包结构可能不同）"
    return
}

Write-Host "完成：$extractTarget" -ForegroundColor Green