#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Unpacks a Godot PCK file to a directory structure (pure PowerShell)
.DESCRIPTION
    Extracts contents of a PCK file using binary parsing.
    Creates output folder next to PCK file as filename.unpacked
.EXAMPLE
    .\Unpack-ModPck.ps1
#>

$ErrorActionPreference = 'Stop'

# All paths relative to script directory
$PckPath = Join-Path $PSScriptRoot "mod.pck"
$OutputDir = Join-Path $PSScriptRoot "mod.unpacked"

# Validate inputs
if (-not (Test-Path $PckPath)) {
    Write-Error "PCK file not found: $PckPath"
    exit 1
}

# Create output directory and clear existing contents
if (Test-Path $OutputDir) {
    Write-Host "Clearing existing output directory: $OutputDir" -ForegroundColor Yellow
    Remove-Item -Path "$OutputDir\*" -Recurse -Force
} else {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "Extracting PCK file: $PckPath" -ForegroundColor Cyan
Write-Host "Output directory: $OutputDir" -ForegroundColor Cyan

# Read PCK binary data
$pckBytes = [System.IO.File]::ReadAllBytes($PckPath)

# Parse header
$magic = [System.Text.Encoding]::ASCII.GetString($pckBytes[0..3])
if ($magic -ne 'GDPC') {
    Write-Error "Invalid PCK header (expected 'GDPC', got '$magic')"
    exit 1
}

$formatVersion = [BitConverter]::ToUInt32($pckBytes, 4)
$godotMajor = [BitConverter]::ToUInt32($pckBytes, 8)
$godotMinor = [BitConverter]::ToUInt32($pckBytes, 12)
$godotPatch = [BitConverter]::ToUInt32($pckBytes, 16)
$fileCount = [BitConverter]::ToUInt32($pckBytes, 84)

Write-Host "PCK header: format=$formatVersion godot=$godotMajor.$godotMinor.$godotPatch files=$fileCount" -ForegroundColor Green

# Parse file entries and extract data
$offset = 88
for ($i = 0; $i -lt $fileCount; $i++) {
    # Read path length and path
    $pathLen = [BitConverter]::ToUInt32($pckBytes, $offset)
    $pathBytes = $pckBytes[($offset + 4)..($offset + 3 + $pathLen)]
    $path = [System.Text.Encoding]::UTF8.GetString($pathBytes).TrimEnd([char]0)
    
    # Calculate padding to 4-byte boundary
    $pad = (4 - (($pathLen + 4) % 4)) % 4
    $entryOffset = $offset + 4 + $pathLen + $pad
    
    # Read entry data
    $dataOffset = [BitConverter]::ToUInt64($pckBytes, $entryOffset)
    $dataSize = [BitConverter]::ToUInt64($pckBytes, $entryOffset + 8)
    $md5Bytes = $pckBytes[($entryOffset + 16)..($entryOffset + 31)]
    
    # Convert res:// path to filesystem path
    $fsPath = $path -replace '^res://', ''
    $fsPath = $fsPath -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $outputPath = Join-Path $OutputDir $fsPath
    
    # Create directory if needed
    $parentDir = Split-Path $outputPath -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    
    # Extract file data
    $fileData = $pckBytes[$dataOffset..($dataOffset + $dataSize - 1)]
    [System.IO.File]::WriteAllBytes($outputPath, $fileData)
    
    Write-Host "  Extracted: $path ($dataSize bytes)" -ForegroundColor White
    
    # Move to next entry
    $offset = $entryOffset + 32
}

# Generate project.godot (Godot 3.x compatible for rebuilding)
$projectContent = @'
; Engine configuration file.
; It is best edited using the editor UI and not directly,
; since the parameters that go here are not all obvious.
;
; Format:
;   [section] ; section goes between []
;   param=value ; assign values to parameters

config_version=4

[application]
config/name="Mod Project"
'@
Set-Content -Path (Join-Path $OutputDir "project.godot") -Value $projectContent

# Generate export_presets.cfg for PCK export (Godot 4.x format)
$presetsContent = @'
[preset.0]
name="Windows Desktop"
platform="Windows Desktop"
runnable=true
dedicated_server=false
custom_features=""
export_filter="all_resource"
include_filter=""
exclude_filter=""
export_path="./mod.pck"
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false

[preset.0.options]
custom_template/debug=""
custom_template/release=""
debug/export_console_script=1
binary_format/embed_pck=true
texture_format/bptc=true
texture_format/s3tc=true
texture_format/etc=false
binary_format/architecture="x86_64"
'@
Set-Content -Path (Join-Path $OutputDir "export_presets.cfg") -Value $presetsContent

Write-Host "`n✓ Extraction complete!" -ForegroundColor Green
Write-Host "  Extracted $fileCount files to: $OutputDir" -ForegroundColor Green
Write-Host "  Created project.godot and export_presets.cfg for rebuilding" -ForegroundColor Green
