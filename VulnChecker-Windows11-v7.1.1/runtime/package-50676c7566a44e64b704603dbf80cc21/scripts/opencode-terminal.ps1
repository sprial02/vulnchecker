#Requires -Version 5.1
param(
    [Parameter(Mandatory=$true)][string]$Distro,
    [Parameter(Mandatory=$true)][string]$User,
    [Parameter(Mandatory=$true)][string]$Work,
    [Parameter(Mandatory=$true)][string]$Config,
    [Parameter(Mandatory=$true)][string]$Executable,
    [switch]$SkipInitialLaunch
)
$global:VulnCheckerOpenCodeContext=@{Distro=$Distro;User=$User;Work=$Work;Config=$Config;Executable=$Executable}

function global:Show-VulnCheckerOpenCodeGuide {
    Write-Host ''
    Write-Host 'OpenCode가 종료되었습니다. 현재 화면은 PowerShell입니다.' -ForegroundColor Cyan
    Write-Host '  oc                 이전 대화 이어서 다시 열기'
    Write-Host '  oc-new             새 대화로 열기'
    Write-Host '  oc --session ID    지정한 대화 이어서 열기'
    Write-Host 'OpenCode 안에서 /sessions로 다른 대화를 선택할 수 있습니다.'
    Write-Host 'MCP 설정을 바꾼 뒤 oc로 다시 열면 새 설정으로 연결합니다.'
    Write-Host '이 창을 닫았다면 VulnChecker의 같은 실행 버튼으로 다시 여세요.'
    Write-Host '작업 폴더:' $global:VulnCheckerOpenCodeContext.Work
    Write-Host ''
}

function global:Invoke-VulnCheckerOpenCode {
    param([string[]]$OpenCodeArgs=@())
    $context=$global:VulnCheckerOpenCodeContext
    $launcher=$context.Config -replace '/[^/]+$','/launch-opencode.py'
    $launchArgs=@('-d',$context.Distro,'-u',$context.User,'--cd',$context.Work,'--','python3',$launcher,'--config',$context.Config,'--executable',$context.Executable,'--')+$OpenCodeArgs
    try {& wsl.exe @launchArgs}
    finally {Show-VulnCheckerOpenCodeGuide}
}

function global:oc {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$OpenCodeArgs=@())
    if (-not $OpenCodeArgs.Count) {$OpenCodeArgs=@('--continue')}
    Invoke-VulnCheckerOpenCode -OpenCodeArgs $OpenCodeArgs
}

function global:oc-new {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$OpenCodeArgs=@())
    Invoke-VulnCheckerOpenCode -OpenCodeArgs @($OpenCodeArgs)
}

if (-not $SkipInitialLaunch) {Invoke-VulnCheckerOpenCode -OpenCodeArgs @('--continue')}
