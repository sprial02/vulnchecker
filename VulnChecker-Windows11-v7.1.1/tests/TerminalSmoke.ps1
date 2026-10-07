#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot
$global:TerminalSmokeCalls=New-Object 'System.Collections.Generic.List[object]'
function global:wsl.exe {
    $global:TerminalSmokeCalls.Add(@($args))
    if ($global:TerminalSmokeFail) {throw 'fixture launch failure'}
}
$global:TerminalSmokeFail=$false
try {
    & (Join-Path $root 'scripts\opencode-terminal.ps1') -Distro 'fixture-kali' -User 'fixture-user' -Work '/work/system space' -Config '/work/managed config.json' -Executable '/tools/opencode' -SkipInitialLaunch
    $guide=oc *>&1 | Out-String
    $launch=$global:TerminalSmokeCalls[0]
    if ($launch[-1] -ne '--continue' -or $launch[5] -ne '/work/system space' -or $launch[8] -ne 'OPENCODE_CONFIG=/work/managed config.json') {throw 'Resume lost working directory, config or continue flag'}
    if ($guide -notmatch 'PowerShell' -or $guide -notmatch 'oc-new' -or $guide -notmatch '/sessions') {throw 'Return guide missing'}
    oc-new | Out-Null
    if ($global:TerminalSmokeCalls[1][-1] -ne '/tools/opencode') {throw 'New session incorrectly resumed history'}
    oc --session ses_fixture | Out-Null
    if (($global:TerminalSmokeCalls[2][-2..-1] -join ' ') -ne '--session ses_fixture') {throw 'Explicit session arguments lost'}
    $global:TerminalSmokeFail=$true
    $failed=$false; $messages=@()
    try {oc *>&1 | ForEach-Object {$messages+=$_}} catch {$failed=$true}
    if (-not $failed -or ($messages | Out-String) -notmatch 'PowerShell') {throw 'Failure did not show recovery guide'}
    Write-Host 'PASS OpenCode resume/new/session commands, preserved context and exit/failure guidance'
} finally {
    foreach ($name in @('wsl.exe','oc','oc-new','Invoke-VulnCheckerOpenCode','Show-VulnCheckerOpenCodeGuide')) {Remove-Item -LiteralPath ('Function:\global:'+$name) -ErrorAction SilentlyContinue}
    Remove-Variable TerminalSmokeCalls,TerminalSmokeFail,VulnCheckerOpenCodeContext -Scope Global -ErrorAction SilentlyContinue
}
