#Requires -Version 7.4
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Name,[switch]$RunLint)
$ErrorActionPreference='Stop'; $Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Python=(Get-Command python3 -ErrorAction SilentlyContinue); if(-not $Python){$Python=(Get-Command python -ErrorAction SilentlyContinue)}; if(-not $Python){$Python=(Get-Command py -ErrorAction SilentlyContinue)}
if(-not $Python){throw 'Python 3 is required on the Admin source workstation for the v1.16.16 helper.'}
$a=@((Join-Path $Root 'scripts\applications\application-helper.py'),'validate','--name',$Name); if($RunLint){$a+='--run-lint'}; if($Python.Name -like 'py*'){$a=@('-3')+$a}; & $Python.Source @a; if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
