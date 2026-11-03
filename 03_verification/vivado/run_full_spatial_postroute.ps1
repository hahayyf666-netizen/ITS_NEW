param([Parameter(Mandatory=$true)][string]$InputCheckpoint,
      [Parameter(Mandatory=$true)][string]$EvidenceDir,
      [ValidateSet('Cleanup','Refine')][string]$Mode='Cleanup')
$ErrorActionPreference='Stop'
$vivado='D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
if(-not (Test-Path -LiteralPath $InputCheckpoint)){throw 'Input checkpoint missing'}
if(Test-Path -LiteralPath $EvidenceDir){throw 'Use a new evidence directory'}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$env:ITS_REPAIR_INPUT_DCP=(Resolve-Path -LiteralPath $InputCheckpoint).Path
$env:ITS_REPAIR_OUTPUT_DIR=(Resolve-Path -LiteralPath $EvidenceDir).Path
$env:XILINX_LOCAL_USER_DATA=Join-Path $env:TEMP 'its_repair_postroute_user'
New-Item -ItemType Directory -Force -Path $env:XILINX_LOCAL_USER_DATA | Out-Null
$scriptName=if($Mode -eq 'Cleanup'){'full_spatial_postroute_cleanup.tcl'}else{'full_spatial_postroute_refine.tcl'}
$marker=if($Mode -eq 'Cleanup'){'POSTROUTE_REPAIR_DONE'}else{'BOUNDED_POSTROUTE_REPAIR_DONE'}
$console=Join-Path $env:ITS_REPAIR_OUTPUT_DIR 'console.log'
& $vivado -mode batch -source (Join-Path $PSScriptRoot $scriptName) -log (Join-Path $env:ITS_REPAIR_OUTPUT_DIR 'vivado.log') -journal (Join-Path $env:ITS_REPAIR_OUTPUT_DIR 'vivado.jou') *> $console
if($LASTEXITCODE -ne 0 -or -not (Get-Content -LiteralPath $console -Raw).Contains($marker)){throw 'Post-route flow failed'}
Write-Output "POSTROUTE_FLOW_COMPLETED mode=$Mode; inspect final setup/hold reports for timing acceptance."
