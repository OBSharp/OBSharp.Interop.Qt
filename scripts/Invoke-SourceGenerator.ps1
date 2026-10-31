#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Generate managed bindings and native Qt forwarding sources.

.DESCRIPTION
    Reads the Qt module umbrella headers from .deps\include and generates
    bindings into the managed and native projects. The native output includes
    a generated-sources.cmake manifest for CMake.

.PARAMETER Modules
    Qt module names without the Qt prefix. Modules whose umbrella header is
    missing are skipped with a warning.

.EXAMPLE
    .\scripts\Invoke-SourceGenerator.ps1

.EXAMPLE
    .\scripts\Invoke-SourceGenerator.ps1 -Modules Core,Gui,Widgets
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Modules = @(
        'Concurrent',
        'Core',
        'Designer',
        'Gui',
        'Multimedia',
        'MultimediaWidgets',
        'Network',
        'OpenGL',
        'OpenGLWidgets',
        'SpatialAudio',
        'Svg',
        'SvgWidgets',
        'UiTools',
        'Widgets',
        'Xml'
    )
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$includeDirectory = Join-Path $projectRoot '.deps\include'
$nativeProject = Join-Path $projectRoot 'src\OBSharp.Interop.Qt.Native'
$managedProject = Join-Path $projectRoot 'src\OBSharp.Interop.Qt'
$nativeOutput = Join-Path $nativeProject 'Generated'
$managedOutput = Join-Path $managedProject 'Generated'

if (-not (Test-Path -LiteralPath $includeDirectory -PathType Container)) {
    throw "Qt headers were not found: $includeDirectory. Restore the Qt dependencies first."
}
if (-not (Test-Path -LiteralPath $nativeProject -PathType Container)) {
    throw "Native project directory was not found: $nativeProject"
}
if (-not (Test-Path -LiteralPath $managedProject -PathType Container)) {
    throw "Managed project directory was not found: $managedProject"
}
if (-not $Modules -or $Modules.Count -eq 0) {
    throw 'At least one Qt module must be specified.'
}

$moduleHeaderMap = [ordered]@{}
$availableModules = [System.Collections.Generic.List[string]]::new()
foreach ($module in $Modules) {
    if ($module -notmatch '^[A-Za-z][A-Za-z0-9]*$') {
        throw "Invalid Qt module name: $module"
    }

    $moduleName = "Qt$module"
    $header = Join-Path (Join-Path $includeDirectory $moduleName) $moduleName
    if (-not (Test-Path -LiteralPath $header -PathType Leaf)) {
        Write-Warning "Skipping $moduleName because its umbrella header was not found: $header"
        continue
    }

    $moduleDirectory = Join-Path $includeDirectory $moduleName
    $moduleHeaders = @(
        Get-ChildItem -LiteralPath $moduleDirectory -File -Filter '*.h' |
            Where-Object { $_.Name -notmatch '(_p|_impl|_win|_mac|_platform)\.h$|^q.*global\.h$' } |
            Sort-Object Name
    )
    if ($moduleHeaders.Count -eq 0) {
        Write-Warning "Skipping $moduleName because it contains no public headers."
        continue
    }

    $moduleHeaderMap[$module] = @($moduleHeaders.FullName)
    $availableModules.Add($module)
}

if ($moduleHeaderMap.Count -eq 0) {
    throw "No Qt module umbrella headers were found under $includeDirectory."
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "OBSharp.Qt.Bindings.$([guid]::NewGuid().ToString('N'))"
$stagingCSharp = Join-Path $stagingRoot 'csharp'
$stagingNative = Join-Path $stagingRoot 'native'
New-Item -ItemType Directory -Path $stagingCSharp, $stagingNative -Force | Out-Null

try {
    # Clang arguments shared by every module run.
    $generatorArguments = [System.Collections.Generic.List[string]]::new()
    $generatorArguments.Add('-I')
    $generatorArguments.Add($includeDirectory)
    $generatorArguments.Add('-std=c++20')

    if ($IsWindows) {
        # The libclang bundled with the generator may be older than the MSVC STL requires.
        $generatorArguments.Add('-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH')
        $generatorArguments.Add('-fms-compatibility')
        $generatorArguments.Add('-fms-extensions')

        # Locate MSVC headers through vswhere when the environment is not a VS developer prompt.
        if (-not $env:INCLUDE) {
            $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
            if (-not (Test-Path -LiteralPath $vswhere)) {
                throw "vswhere.exe was not found: $vswhere. Run from a Visual Studio developer prompt."
            }

            $installPath = & $vswhere -latest -prerelease -products * `
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                -property installationPath
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installPath)) {
                throw 'Visual Studio with the C++ x64/x86 build tools was not found.'
            }

            $msvcRoot = Join-Path $installPath 'VC\Tools\MSVC'
            $msvcVersion = Get-ChildItem -LiteralPath $msvcRoot -Directory |
                Sort-Object { [version]$_.Name } -Descending |
                Select-Object -First 1
            if (-not $msvcVersion) {
                throw "No MSVC toolset was found under $msvcRoot."
            }
            $generatorArguments.Add('-isystem')
            $generatorArguments.Add((Join-Path $msvcVersion.FullName 'include'))

            $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
            $sdkVersion = Get-ChildItem -LiteralPath $kitsRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                Sort-Object { [version]$_.Name } -Descending |
                Select-Object -First 1
            if ($sdkVersion) {
                foreach ($kit in 'ucrt', 'shared', 'um') {
                    $generatorArguments.Add('-isystem')
                    $generatorArguments.Add((Join-Path $sdkVersion.FullName $kit))
                }
            }
        }
    }

    # One run per module keeps the command line under the Windows length limit.
    Push-Location $projectRoot
    try {
        foreach ($module in $moduleHeaderMap.Keys) {
            Write-Host "Generating Qt$module bindings" -ForegroundColor Cyan
            $moduleArguments = [System.Collections.Generic.List[string]]::new()
            foreach ($header in $moduleHeaderMap[$module]) {
                $moduleArguments.Add('--header')
                $moduleArguments.Add($header)
            }
            foreach ($argument in @(
                '--namespace', 'OBSharp.Interop.Qt',
                '--library-name', 'OBSharp.Interop.Qt.Native',
                '--cpp-redirect',
                '--qt',
                '--csharp-output', (Join-Path $stagingCSharp $module),
                '--native-output', (Join-Path $stagingNative $module),
                '--native-name', "OBSharp.Interop.Qt.Native.$module",
                '--return-string-marshaller', 'OBSharp.Interop.Qt.NoFreeUTF8StringMarshaller',
                '--'
            )) {
                $moduleArguments.Add($argument)
            }
            $moduleArguments.AddRange($generatorArguments)

            & dotnet OBSharp.Interop.NativeBindGenerator @moduleArguments
            if ($LASTEXITCODE -ne 0) {
                throw "NativeBindGenerator failed for Qt$module with exit code $LASTEXITCODE."
            }
        }
    }
    finally {
        Pop-Location
    }

    $generatedCSharp = @(Get-ChildItem -LiteralPath $stagingCSharp -File -Recurse -Filter '*.cs')
    $generatedNativeSources = @(Get-ChildItem -LiteralPath $stagingNative -File -Recurse -Filter '*.cpp')
    $generatedNativeHeaders = @(
        Get-ChildItem -LiteralPath $stagingNative -File -Recurse |
            Where-Object { $_.Extension -in @('.h', '.hpp') }
    )
    if ($generatedCSharp.Count -eq 0) {
        throw 'The generator completed without producing C# files.'
    }
    if ($generatedNativeSources.Count -eq 0 -or $generatedNativeHeaders.Count -eq 0) {
        throw 'The generator completed without producing both native source and header files.'
    }

    foreach ($outputDirectory in @($managedOutput, $nativeOutput)) {
        if (Test-Path -LiteralPath $outputDirectory) {
            Remove-Item -LiteralPath $outputDirectory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    foreach ($stagedDirectory in @(
        @{ Source = $stagingCSharp; Destination = $managedOutput },
        @{ Source = $stagingNative; Destination = $nativeOutput }
    )) {
        foreach ($file in Get-ChildItem -LiteralPath $stagedDirectory.Source -File -Recurse) {
            $relativePath = [System.IO.Path]::GetRelativePath($stagedDirectory.Source, $file.FullName)
            $destination = Join-Path $stagedDirectory.Destination $relativePath
            $destinationDirectory = Split-Path -Path $destination -Parent
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination
        }
    }

    $cmakeManifest = [System.Collections.Generic.List[string]]::new()
    $cmakeManifest.Add('set(OBSHARP_QT_GENERATED_MODULES')
    foreach ($module in $availableModules) {
        $cmakeManifest.Add("    $module")
    }
    $cmakeManifest.Add(')')
    $cmakeManifest.Add('')
    foreach ($item in @(
        @{ Variable = 'OBSHARP_QT_GENERATED_SOURCES'; Files = $generatedNativeSources },
        @{ Variable = 'OBSHARP_QT_GENERATED_HEADERS'; Files = $generatedNativeHeaders }
    )) {
        $cmakeManifest.Add("set($($item.Variable)")
        foreach ($file in $item.Files) {
            $relativePath = [System.IO.Path]::GetRelativePath($stagingNative, $file.FullName).Replace('\', '/')
            $cmakeManifest.Add("    `"Generated/$relativePath`"")
        }
        $cmakeManifest.Add(')')
        $cmakeManifest.Add('')
    }

    Set-Content -LiteralPath (Join-Path $nativeOutput 'generated-sources.cmake') `
        -Value $cmakeManifest -Encoding utf8

    Write-Host "Managed bindings: $managedOutput" -ForegroundColor Green
    Write-Host "Native bindings: $nativeOutput" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
