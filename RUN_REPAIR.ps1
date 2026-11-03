param([string]$EvidenceDir='',[string]$NativeExe='',
      [string]$Compiler='D:\AMDDesignTools\2025.2\tps\mingw\10.0.0\win64.o\nt\bin\g++.exe',
      [switch]$PrepareOnly)
$ErrorActionPreference='Stop'
$repo=$PSScriptRoot
# A source ZIP has no .git. The qualification models record a Git snapshot;
# create a local one for an extracted archive, preserving the tested files.
if(-not (Test-Path -LiteralPath (Join-Path $repo '.git'))){
    & git -C $repo init -q -b fix/full-vertical-output
    if($LASTEXITCODE -ne 0){throw 'Archive snapshot initialization failed'}
    & git -C $repo config core.autocrlf false
    & git -C $repo config core.whitespace cr-at-eol
    & git -C $repo add -- .
    & git -C $repo -c user.name=RepairArchiveSnapshot -c user.email=repair-local@invalid commit -qm 'Full spatial repair archive snapshot'
    if($LASTEXITCODE -ne 0){throw 'Archive snapshot commit failed'}
}
if($PrepareOnly){Write-Output "REPAIR_WORKSPACE_READY snapshot=$((git -C $repo rev-parse HEAD).Trim())";return}
if(-not $EvidenceDir){throw 'Supply a new -EvidenceDir outside the source directory'}
& (Join-Path $repo '03_verification/step12d_engineering/qualify_full_spatial_repair.ps1') -EvidenceDir $EvidenceDir -NativeExe $NativeExe -Compiler $Compiler
if(-not $?){throw 'Repair qualification failed'}
