#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('install','preflight','run')][string]$Action = 'install',
    [string]$Distribution = 'kali-linux',
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$RunnerArguments
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$linuxRoot = (& wsl.exe -d $Distribution --exec wslpath -a $PSScriptRoot | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $linuxRoot.StartsWith('/')) { throw 'Kali WSL path resolution failed.' }
& wsl.exe -d $Distribution --exec bash "$linuxRoot/scripts/manage-kali.sh" $Action @RunnerArguments
if ($LASTEXITCODE -ne 0) { throw "Infrastructure action failed (exit $LASTEXITCODE). See run summary." }
