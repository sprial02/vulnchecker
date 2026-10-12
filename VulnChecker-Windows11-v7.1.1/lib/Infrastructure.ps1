function Get-InfrastructureSettings {
    $path=Join-Path $script:Runtime 'infra-settings.json'
    if (Test-Path -LiteralPath $path) {return (Read-SharedText $path | ConvertFrom-Json)}
    return [pscustomobject]@{Servers=@()}
}

function Save-InfrastructureServer {
    param($Server,[switch]$Remove)
    if ($Server.Alias -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') {throw '서버 이름은 영문, 숫자, 점, 밑줄, 하이픈으로 입력하세요.'}
    $existing=Get-InfrastructureSettings
    $rows=@($existing.Servers | Where-Object Alias -ne $Server.Alias)
    if (-not $Remove) {
        if ($Server.Host -notmatch '^[A-Za-z0-9:_.-]+$' -or -not $Server.User.Trim()) {throw '서버 주소와 접속 계정을 입력하세요.'}
        if ($Server.Connection -notin @('ssh','winrm','psrp') -or $Server.Platform -notin @('Debian','RedHat')) {throw '지원하는 서버 종류를 선택하세요.'}
        if ([int]$Server.Port -lt 1 -or [int]$Server.Port -gt 65535 -or [int]$Server.Timeout -lt 10 -or [int]$Server.Timeout -gt 3600) {throw '포트(1~65535)와 항목 제한(10~3600초)을 확인하세요.'}
        $old=@($existing.Servers | Where-Object Alias -eq $Server.Alias | Select-Object -First 1)
        $data=@{}
        foreach ($name in @('Alias','Host','User','Connection','Platform','Port','Protocol','KeyFile','Timeout','Enabled','TrustNewHostKey')) {$data[$name]=$Server.$name}
        foreach ($name in @('Password','BecomePassword')) {
            $value=[string]$Server.$name
            if ($value -match '[\r\n\x00]') {throw '암호에 줄바꿈을 넣을 수 없습니다.'}
            if ($value) {$data[$name]=ConvertFrom-SecureString (ConvertTo-SecureString $value -AsPlainText -Force)}
            elseif ($old.Count) {$data[$name]=[string]$old[0].$name}
            else {$data[$name]=''}
        }
        $rows+=,[pscustomobject]$data
    }
    Write-AtomicText -Path (Join-Path $script:Runtime 'infra-settings.json') -Text (ConvertTo-Json -InputObject @{Servers=@($rows)} -Depth 8)
}

function Invoke-InfrastructureKali {
    param([string[]]$Arguments,[string]$InputText,[int[]]$SuccessCodes=@(0),[switch]$Quiet,[switch]$Root)
    $args=@('-d',$script:Config.kaliDistro)
    if ($Root) {$args+=@('-u','root')}
    elseif ($script:Config.existing.kaliUser) {$args+=@('-u',$script:Config.existing.kaliUser)}
    $params=@{File='wsl.exe';Arguments=($args+@('--exec')+$Arguments);SuccessCodes=$SuccessCodes;Quiet=$Quiet}
    if ($PSBoundParameters.ContainsKey('InputText')) {$params.InputText=$InputText}
    return (Invoke-Native @params)
}

function Get-InfrastructureHome {
    $infraHome=Invoke-InfrastructureKali -Arguments @('python3','-c','from pathlib import Path; print(Path.home())') -Quiet
    return ($infraHome.Trim()+'/.local/share/vulnchecker-infra')
}

function Get-InfrastructureRuns {
    $path=Join-Path $script:Runtime 'infra-runs'
    if (-not (Test-Path -LiteralPath $path)) {return @()}
    foreach ($folder in @(Get-ChildItem -LiteralPath $path -Directory | Sort-Object Name -Descending)) {
        $summary=Join-Path $folder.FullName 'summary.json'
        if (Test-Path -LiteralPath $summary) {
            try {
                $data=Read-SharedText $summary | ConvertFrom-Json
                $kind='점검'; if ($data.preflight) {$kind='접속 확인'}
                [pscustomobject]@{Id=$folder.Name;Folder=$folder.FullName;Summary=$data;Label=($folder.Name+' · '+$kind+' · '+($data.hosts -join ', '))}
            } catch {}
        }
    }
}

function Invoke-InfrastructureAction {
    param([string]$Tool,[string]$Target='')
    $name='인프라 점검'
    try {
        Set-ConnectionResult $name '진행 중' 'Kali의 Ansible 환경과 서버 연결을 준비합니다.'
        $source=Join-Path $script:Root 'infrastructure'
        $linuxSource=(Invoke-InfrastructureKali -Arguments @('wslpath','-a',$source) -Quiet).Trim()
        if ($Tool -eq 'InfraInstall') {
            $infraHome=Get-InfrastructureHome
            try {Invoke-InfrastructureKali -Arguments @('python3','-m','venv',($infraHome+'/.venv')) -Quiet | Out-Null}
            catch {
                Write-Log 'Ansible 전용 Python 환경 구성 요소를 Kali에 추가 설치합니다.'
                Invoke-InfrastructureKali -Root -Arguments @('apt-get','update') | Out-Null
                Invoke-InfrastructureKali -Root -Arguments @('apt-get','install','-y','--no-install-recommends','python3-venv','git') | Out-Null
            }
            Invoke-InfrastructureKali -Arguments @('bash',($linuxSource+'/scripts/manage-kali.sh'),'install') | Out-Null
            Set-ConnectionResult $name '완료' 'Ansible Core 및 Windows 접속 구성 설치 완료. ⑦ 인프라 점검에서 서버 등록 후 접속 확인하세요.'
            return
        }
        $infraHome=Get-InfrastructureHome
        # Refresh only shipped code; preserve existing inventories, credentials, runs and venv.
        Invoke-InfrastructureKali -Arguments @('bash',($linuxSource+'/scripts/manage-kali.sh'),'refresh') -Quiet | Out-Null
        if ($Tool -eq 'InfraImport') {
            $raw=Invoke-InfrastructureKali -Arguments @(($infraHome+'/.venv/bin/python'),($infraHome+'/scripts/gui-bridge.py'),'import') -Quiet
            try {$imported=$raw | ConvertFrom-Json; foreach ($server in $imported) {Save-InfrastructureServer $server}} finally {$raw=$null;$imported=$null}
            Set-ConnectionResult $name '완료' '이전에 검증한 서버를 UI로 가져왔습니다. 암호는 현재 Windows 계정으로 암호화했습니다.'
            return
        }
        $servers=@((Get-InfrastructureSettings).Servers)
        if (-not $servers.Count) {throw '⑦ 인프라 점검에서 서버를 등록하세요.'}
        $plain=@()
        foreach ($server in $servers) {
            $row=@{}
            foreach ($prop in $server.PSObject.Properties) {$row[$prop.Name]=$prop.Value}
            foreach ($key in @('Password','BecomePassword')) {$row[$key]=Get-AiPlainKey ([string]$row[$key])}
            $plain+=,$row
        }
        $request=@{Hosts=@();RunId=''}
        if ($Target) {$request=$Target | ConvertFrom-Json}
        $output=Join-Path $script:Runtime 'infra-runs'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $linuxOutput=(Invoke-InfrastructureKali -Arguments @('wslpath','-a',$output) -Quiet).Trim()
        $action=@{InfraPreflight='preflight';InfraRun='run';InfraRetry='retry'}[$Tool]
        if (-not $action) {throw '지원하지 않는 인프라 작업입니다.'}
        $payload=@{Servers=$plain;Hosts=@($request.Hosts);RunId=$request.RunId;Output=$linuxOutput} | ConvertTo-Json -Depth 10
        $before=@(Get-InfrastructureRuns | ForEach-Object Id)
        try {
            $outputText=Invoke-InfrastructureKali -Arguments @(($infraHome+'/.venv/bin/python'),($infraHome+'/scripts/gui-bridge.py'),$action) -InputText $payload -SuccessCodes @(0,1)
        } finally {$payload=$null;$plain=$null}
        $new=@(Get-InfrastructureRuns | Where-Object Id -notin $before | Select-Object -First 1)
        if (-not $new.Count) {
            if ($outputText -match '재실행 대상이 없습니다') {Set-ConnectionResult $name '완료' '재실행할 실패 서버가 없습니다.'; return}
            throw '점검 요약이 생성되지 않았습니다. 아래 로그의 접속/설정 오류를 확인하세요.'
        }
        $summary=$new[0].Summary
        $detail=('대상 '+@($summary.hosts).Count+'대 · 실행 실패 '+@($summary.failed_hosts).Count+'대 · 취약 발견 '+@($summary.vulnerable_hosts).Count+'대 · ⑦ 점검 결과에서 증적 확인')
        if (@($summary.failed_hosts).Count -or $summary.ansible_rc -ne 0) {throw $detail}
        Set-ConnectionResult $name '완료' $detail
    } catch {Set-ConnectionResult $name '실패' $_.Exception.Message; throw}
}
