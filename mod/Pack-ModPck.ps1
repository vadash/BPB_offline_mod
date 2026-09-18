#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Packs a directory structure into a Godot PCK file (pure PowerShell)
.DESCRIPTION
    Creates a PCK file from extracted mod contents using binary serialization.
    Calculates exact MD5 hashes to prevent silent game crashes.
#>

$ErrorActionPreference = 'Stop'

# All paths relative to script directory
$SourceDir = Join-Path $PSScriptRoot "mod.unpacked"
$OutputPck = Join-Path $PSScriptRoot "mod.pck"

# Validate inputs
if (-not (Test-Path $SourceDir)) {
    Write-Error "Source directory not found: $SourceDir"
    exit 1
}

Write-Host "Packing directory: $SourceDir" -ForegroundColor Cyan

# Read existing PCK to get header values (if it exists)
$ReferencePck = Join-Path $PSScriptRoot "mod_1.pck"
if (Test-Path $ReferencePck) {
    $refBytes = [System.IO.File]::ReadAllBytes($ReferencePck)
    $formatVersion = [BitConverter]::ToUInt32($refBytes, 4)
    $godotMajor = [BitConverter]::ToUInt32($refBytes, 8)
    $godotMinor = [BitConverter]::ToUInt32($refBytes, 12)
    $godotPatch = [BitConverter]::ToUInt32($refBytes, 16)
    Write-Host "Using header from reference PCK: format=$formatVersion godot=$godotMajor.$godotMinor.$godotPatch" -ForegroundColor Green
} else {
    # The hex dump provided matches Godot 3.6 exactly
    $formatVersion = 1
    $godotMajor = 3
    $godotMinor = 6
    $godotPatch = 0
    Write-Host "Using default header: Godot 3.6.0 format=$formatVersion" -ForegroundColor Yellow
}

# Collect files to pack (exclude build artifacts)
$filesToPack = @()
$excludeDirs = @('.godot', '.import', 'import', '__pycache__')
$excludeFiles = @('project.godot', 'export_presets.cfg', '*.uid')

Get-ChildItem -Path $SourceDir -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($SourceDir.Length + 1)
    
    # Skip excluded directories
    $inExcludeDir = $false
    foreach ($dir in $excludeDirs) {
        if ($relativePath -like "$dir\*") {
            $inExcludeDir = $true
            break
        }
    }
    if ($inExcludeDir) { return }
    
    # Skip excluded files
    $fileName = Split-Path $relativePath -Leaf
    if ($excludeFiles -contains $fileName) { return }
    if ($fileName -like '*.uid') { return }
    
    # Convert to res:// path (CRITICAL: ensure paths are case-sensitive to the original game!)
    $resPath = 'res://' + ($relativePath -replace '\\', '/')
    $filesToPack += @{
        Path = $resPath
        LocalPath = $_.FullName
        Size = $_.Length
    }
}

if ($filesToPack.Count -eq 0) {
    Write-Error "No files found to pack in $SourceDir"
    exit 1
}

# Calculate PCK structure & Compute MD5s
$headerSize = 88  # Fixed header size
$indexSize = 0
$indexEntries = @()
$md5Hasher = [System.Security.Cryptography.MD5]::Create()

foreach ($file in $filesToPack) {
    $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($file.Path)
    
    $pathLenWithNull = $pathBytes.Length + 1
    $alignedPathLen = $pathLenWithNull + ((4 - ($pathLenWithNull % 4)) % 4)
    $entrySize = 4 + $alignedPathLen + 32 
    
    # Pre-calculate MD5 Hash for integrity checks
    $fileBytes = [System.IO.File]::ReadAllBytes($file.LocalPath)
    $md5Hash = $md5Hasher.ComputeHash($fileBytes)
    
    $indexEntries += @{
        PathBytes = $pathBytes
        AlignedPathLen = $alignedPathLen
        EntrySize = $entrySize
        MD5 = $md5Hash
    }
    $indexSize += $entrySize
}

$dataOffset = $headerSize + $indexSize
$currentOffset = $dataOffset

# Build PCK data
$ms = [System.IO.MemoryStream]::new()

# Write header
$encoding = [System.Text.Encoding]::ASCII
$ms.Write($encoding.GetBytes('GDPC'), 0, 4)  # Magic
$ms.Write([BitConverter]::GetBytes($formatVersion), 0, 4)
$ms.Write([BitConverter]::GetBytes($godotMajor), 0, 4)
$ms.Write([BitConverter]::GetBytes($godotMinor), 0, 4)
$ms.Write([BitConverter]::GetBytes($godotPatch), 0, 4)

# Reserved (16x uint32 = 64 bytes)
$zeroUInt = [BitConverter]::GetBytes([uint32]0)
for ($i = 0; $i -lt 16; $i++) {
    $ms.Write($zeroUInt, 0, 4)
}

# File count
$ms.Write([BitConverter]::GetBytes($filesToPack.Count), 0, 4)

# Write file index
foreach ($i in 0..($filesToPack.Count - 1)) {
    $file = $filesToPack[$i]
    $entry = $indexEntries[$i]
    
    # Path length
    $ms.Write([BitConverter]::GetBytes([uint32]$entry.AlignedPathLen), 0, 4)
    # Path string
    $ms.Write($entry.PathBytes, 0, $entry.PathBytes.Length)
    # Null terminator
    $ms.WriteByte(0)
    
    # Alignment padding
    $padBytes = $entry.AlignedPathLen - ($entry.PathBytes.Length + 1)
    for ($j = 0; $j -lt $padBytes; $j++) {
        $ms.WriteByte(0)
    }
    
    # Data offset and size
    $ms.Write([BitConverter]::GetBytes([uint64]$currentOffset), 0, 8)
    $ms.Write([BitConverter]::GetBytes([uint64]$file.Size), 0, 8)
    
    # Real MD5 hash (fixes silent crashes on integrity-checked games)
    $ms.Write($entry.MD5, 0, 16)
    
    $currentOffset += $file.Size
}

# Write file data
foreach ($file in $filesToPack) {
    $fileData = [System.IO.File]::ReadAllBytes($file.LocalPath)
    $ms.Write($fileData, 0, $fileData.Length)
    
    Write-Host "  Packed: $($file.Path) ($($fileData.Length) bytes)" -ForegroundColor White
}

if (Test-Path $OutputPck) {
    Remove-Item -Path $OutputPck -Force
}

[System.IO.File]::WriteAllBytes($OutputPck, $ms.ToArray())
$ms.Close()

Write-Host "PCK created successfully!" -ForegroundColor Green
