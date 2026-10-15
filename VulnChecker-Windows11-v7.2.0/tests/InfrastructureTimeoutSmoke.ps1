#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$fixture=Join-Path $root ('runtime\infra-timeout-'+[guid]::NewGuid().ToString('N'))
$folder=Join-Path $fixture ('02.Windows'+[char]0xC11C+[char]0xBC84)
New-Item -ItemType Directory -Path $folder -Force | Out-Null
foreach ($n in 1..64) {
    Set-Content -LiteralPath (Join-Path $folder ('W{0:D2}_check.ps1' -f $n)) -Value 'Start-Sleep -Seconds 30' -Encoding ASCII
}
$watch=[Diagnostics.Stopwatch]::StartNew()
& (Join-Path $root 'infrastructure\scripts\windows-execute.ps1') -Root $fixture -ItemTimeout 1
$parsed=Get-Content -LiteralPath (Join-Path $fixture 'execution.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$records=@($parsed)
if ($records.Count -ne 64 -or @($records | Where-Object rc -eq 124).Count -ne 3 -or @($records | Where-Object rc -eq 125).Count -ne 61) {throw 'Windows consecutive timeout fail-fast failed'}
if ($watch.Elapsed.TotalSeconds -gt 25) {throw 'Windows timeout bound exceeded'}
Write-Host 'PASS Windows: three hung items time out, remaining 61 skipped with explicit reasons'
