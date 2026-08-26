#Requires -Version 7.4
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Name,
  [Parameter(Mandatory=$true)][string]$Command,
  [Parameter(Mandatory=$true)][ValidateSet('npm','uv','apt','archive','custom')][string]$InstallType,
  [string]$Package,[string]$Version,[string]$Url,[string]$Sha256,
  [ValidateSet('binary','zip','tar.gz')][string]$ArchiveFormat,[string]$BinaryPath,[string]$CustomSnippet,
  [string]$SecretEnv,[string]$SsmParameter,[string]$Egress,[string]$ConfigDir,
  [switch]$Mcp,[string]$McpSubcommand,[switch]$Apply
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Python=(Get-Command python3 -ErrorAction SilentlyContinue)
if(-not $Python){$Python=(Get-Command python -ErrorAction SilentlyContinue)}
if(-not $Python){$Python=(Get-Command py -ErrorAction SilentlyContinue)}
if(-not $Python){throw 'Python 3 is required on the Admin source workstation for the v1.16.16 helper. Use the v1.16.16 manual runbook if Python is not available.'}
$ArgsList=@((Join-Path $Root 'scripts\applications\application-helper.py'),'add','--name',$Name,'--command',$Command,'--install-type',$InstallType)
foreach($pair in @(@('--package',$Package),@('--version',$Version),@('--url',$Url),@('--sha256',$Sha256),@('--archive-format',$ArchiveFormat),@('--binary-path',$BinaryPath),@('--custom-snippet',$CustomSnippet),@('--secret-env',$SecretEnv),@('--ssm-parameter',$SsmParameter),@('--egress',$Egress),@('--config-dir',$ConfigDir),@('--mcp-subcommand',$McpSubcommand))){if($pair[1]){$ArgsList += $pair}}
if($Mcp){$ArgsList+='--mcp'}; if($Apply){$ArgsList+='--apply'}
if($Python.Name -eq 'py.exe' -or $Python.Name -eq 'py'){$ArgsList=@('-3')+$ArgsList}
& $Python.Source @ArgsList
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
