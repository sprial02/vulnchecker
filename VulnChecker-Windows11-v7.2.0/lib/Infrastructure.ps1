function Get-InfrastructureSettings {
    $path=Join-Path $script:Runtime 'infra-settings.json'
    if (Test-Path -LiteralPath $path) {return (Read-SharedText $path | ConvertFrom-Json)}
    return [pscustomobject]@{Servers=@()}
}

function Resolve-InfrastructureProtocol {
    param([string]$Connection,[int]$Port,[string]$Protocol='')
    if ($Protocol.Trim()) {return $Protocol.Trim().ToLowerInvariant()}
    if ($Connection -in @('winrm','psrp')) {
        if ($Port -eq 5985) {return 'http'}
        if ($Port -eq 5986) {return 'https'}
        throw 'Windows 사용자 지정 포트는 Protocol(http/https)도 입력하세요.'
    }
    return 'https'
}

function Save-InfrastructureServer {
    param($Server,[switch]$Remove,$Settings,[switch]$DeferWrite)
    if (-not $Remove -and -not ([string]$Server.Alias).Trim()) {
        $alias=([string]$Server.Host).Trim()
        if ($alias.Contains(':')) {$alias='ip6-'+$alias.Replace(':','-')}
        $Server | Add-Member -NotePropertyName Alias -NotePropertyValue $alias -Force
    }
    if ($Server.Alias -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') {throw '서버 이름은 영문, 숫자, 점, 밑줄, 하이픈으로 입력하세요.'}
    $existing=$Settings; if (-not $existing) {$existing=Get-InfrastructureSettings}
    $rows=@($existing.Servers | Where-Object Alias -ne $Server.Alias)
    if (-not $Remove) {
        if ($Server.Host -notmatch '^[A-Za-z0-9:_][A-Za-z0-9:_.-]*$' -or -not $Server.User.Trim()) {throw '서버 주소와 접속 계정을 입력하세요.'}
        $Server.Connection=([string]$Server.Connection).ToLowerInvariant()
        $Server.Protocol=Resolve-InfrastructureProtocol ([string]$Server.Connection) ([int]$Server.Port) ([string]$Server.Protocol)
        if ($Server.Connection -notin @('ssh','winrm','psrp') -or $Server.Platform -notin @('Auto','Debian','RedHat','AIX','HP-UX','Solaris','Windows')) {throw '지원하는 서버 종류를 선택하세요.'}
        $Server.Platform=@('Auto','Debian','RedHat','AIX','HP-UX','Solaris','Windows') | Where-Object {$_ -eq $Server.Platform} | Select-Object -First 1
        $parsedPort=0;$parsedTimeout=0
        if (-not [int]::TryParse([string]$Server.Port,[ref]$parsedPort) -or -not [int]::TryParse([string]$Server.Timeout,[ref]$parsedTimeout)) {throw 'Port와 Timeout은 정수로 입력하세요.'}
        if ($Server.Protocol -notin @('http','https')) {throw 'Protocol은 http 또는 https입니다.'}
        if ([int]$Server.Port -lt 1 -or [int]$Server.Port -gt 65535 -or [int]$Server.Timeout -lt 10 -or [int]$Server.Timeout -gt 3600) {throw '포트(1~65535)와 항목 제한(10~3600초)을 확인하세요.'}
        if ($Server.Connection -eq 'ssh' -and $Server.Platform -eq 'Windows') {throw 'SSH의 Platform은 Unix OS 또는 Auto를 사용하세요.'}
        $old=@($existing.Servers | Where-Object Alias -eq $Server.Alias | Select-Object -First 1)
        $data=@{}
        foreach ($name in @('Alias','Host','User','Connection','Platform','Port','Protocol','KeyFile','Timeout','Enabled','TrustNewHostKey')) {$data[$name]=$Server.$name}
        if ($old.Count -and $old[0].PSObject.Properties['Profiles']) {$data.Profiles=$old[0].Profiles}
        foreach ($name in @('Password','BecomePassword')) {
            $value=[string]$Server.$name
            if ($value -match '[\r\n\x00]') {throw '암호에 줄바꿈을 넣을 수 없습니다.'}
            if ($value) {$data[$name]=ConvertFrom-SecureString (ConvertTo-SecureString $value -AsPlainText -Force)}
            elseif ($old.Count) {$data[$name]=[string]$old[0].$name}
            else {$data[$name]=''}
        }
        $rows+=,[pscustomobject]$data
    }
    if ($DeferWrite) {return [pscustomobject]@{Servers=@($rows)}}
    Write-AtomicText -Path (Join-Path $script:Runtime 'infra-settings.json') -Text (ConvertTo-Json -InputObject @{Servers=@($rows)} -Depth 12)
}

function Import-InfrastructureCsv {
    param([string]$Path)
    $rows=@(Import-Csv -LiteralPath $Path -Encoding UTF8)
    if (-not $rows.Count) {throw 'CSV에 서버가 없습니다.'}
    $required=@('Host','User','Connection','Platform','Port')
    foreach ($column in $required) {if (-not $rows[0].PSObject.Properties[$column]) {throw ('CSV 필수 열 누락: '+$column+' · 필수: '+($required -join ', '))}}
    $allowed=@('Alias','Host','User','Connection','Platform','Port','Protocol','KeyFile','Timeout','Enabled','TrustNewHostKey','Password','BecomePassword')
    foreach ($column in $rows[0].PSObject.Properties.Name) {if ($column -notin $allowed) {throw ('CSV 지원하지 않는 열: '+$column+' · 양식의 열 이름을 사용하세요.')}}
    $settings=Get-InfrastructureSettings; $aliases=@{};$errors=New-Object 'System.Collections.Generic.List[string]';$line=1
    foreach ($row in $rows) {
        $line++
        try {
        foreach ($column in $required) {if ([string]::IsNullOrWhiteSpace([string]$row.$column)) {throw ('필수 값 누락: '+$column)}}
        $data=@{Alias='';Protocol='';Timeout=90;Enabled=$true;TrustNewHostKey=$true;KeyFile='';Password='';BecomePassword=''}
        foreach ($p in $row.PSObject.Properties) {
            $value=[string]$p.Value
            if ($p.Name -notin @('Password','BecomePassword')) {$value=$value.Trim()}
            if ($value -ne '') {$data[$p.Name]=$value}
        }
        if (-not $data.Alias) {$data.Alias=$data.Host;if ($data.Alias.Contains(':')) {$data.Alias='ip6-'+$data.Alias.Replace(':','-')}}
        if ($aliases.ContainsKey($data.Alias)) {throw ('서버 이름 중복: '+$data.Alias+' (앞선 '+$aliases[$data.Alias]+'행)')};$aliases[$data.Alias]=$line
        foreach ($key in @('Enabled','TrustNewHostKey')) {
            if ([string]$data[$key] -notin @('true','false')) {throw "CSV $key 값은 true 또는 false입니다."}
            $data[$key]=[bool]::Parse([string]$data[$key])
        }
        $old=@($settings.Servers | Where-Object Alias -eq $data.Alias | Select-Object -First 1)
        $savedPassword=$old.Count -and $old[0].Password
        $savedKey=$old.Count -and $old[0].KeyFile
        if ($data.Enabled -and [string]::IsNullOrWhiteSpace([string]$data.Password) -and -not $savedPassword -and -not ($data.Connection -eq 'ssh' -and ($data.KeyFile -or $savedKey))) {throw '인증 정보 누락: SSH는 Password 또는 KeyFile, Windows는 Password 필수 (기존 저장 암호 재사용 가능)'}
        if (-not $data.KeyFile -and $savedKey) {$data.KeyFile=$old[0].KeyFile}
        $settings=Save-InfrastructureServer ([pscustomobject]$data) -Settings $settings -DeferWrite
        } catch {$errors.Add(('CSV '+$line+'행: '+$_.Exception.Message))}
    }
    if ($errors.Count) {throw (($errors -join "`r`n")+"`r`n등록하지 않았습니다. CSV를 수정한 뒤 다시 가져오세요.")}
    # Validate every row first; commit once, preserving the prior inventory on errors.
    Write-AtomicText -Path (Join-Path $script:Runtime 'infra-settings.json') -Text ($settings | ConvertTo-Json -Depth 8)
    return $rows.Count
}

function Assert-InfrastructureWsl {
    param([switch]$Install)
    try {
        Invoke-Native wsl.exe @('--version') -Quiet -TimeoutSeconds 15 | Out-Null
        Invoke-Native wsl.exe @('--status') -Quiet -TimeoutSeconds 15 | Out-Null
    }
    catch {
        if (-not $Install) {throw 'WSL이 준비되지 않았습니다. ⑦ Ansible 설치 / 확인을 관리자 권한으로 실행하세요. WSL 기능 설치 후 재부팅이 필요할 수 있습니다.'}
        if (-not (Test-Admin)) {throw 'WSL 설치에는 관리자 권한이 필요합니다. 프로그램을 관리자 권한으로 실행하고 ⑦ Ansible 설치 / 확인을 누르세요.'}
        Write-Log 'WSL이 준비되지 않아 Windows 가상화 기능과 WSL을 자동 설치합니다.'
        $restart=Enable-VirtualizationFeatures -WslOnly
        if ($restart) {return $false}
        Invoke-Native wsl.exe @('--status') -Quiet -TimeoutSeconds 15 | Out-Null
    }
    $distros=(Invoke-Native wsl.exe @('--list','--quiet') -Quiet -TimeoutSeconds 15) -split '\r?\n' | ForEach-Object {$_.Trim()}
    if ($script:Config.kaliDistro -notin $distros) {
        if (-not $Install) {throw 'Kali 배포판이 없습니다. ⑦ Ansible 설치 / 확인을 먼저 실행하세요.'}
        Write-Log 'Kali 배포판이 없어 자동 다운로드 / 설치합니다.'
        Install-Kali
    }
    return $true
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
                [pscustomobject]@{Id=$folder.Name;Folder=$folder.FullName;Summary=$data;Label=($folder.Name+' · '+$kind+' · '+@($data.hosts).Count+'대')}
            } catch {}
        }
    }
}

function Invoke-InfrastructureAction {
    param([string]$Tool,[string]$Target='')
    $name='인프라 점검'
    try {
        if ($Tool -eq 'InfraOfflineImport') {Set-ConnectionResult $name '진행 중' '고객 실행 결과 ZIP의 형식과 파일 무결성을 확인합니다.'}
        else {Set-ConnectionResult $name '진행 중' 'Kali의 Ansible 환경과 서버 연결을 준비합니다.'}
        if ($Tool -eq 'InfraOfflineImport') {
            $request=$Target | ConvertFrom-Json
            if (-not @($request.Files).Count) {throw '고객 실행 결과 ZIP을 선택하세요.'}
            $python=Ensure-ReportRuntime
            $arguments=@((Join-Path $script:Root 'scripts\import-offline.py'),'--root',(Join-Path $script:Runtime 'infra-runs'),'--out',(Join-Path $script:Runtime 'offline-import.json'))
            foreach ($file in @($request.Files)) {$arguments+=@('--file',[string]$file)}
            try {Invoke-ReportPython $python $arguments | Out-Null} finally {Sync-InfrastructureReportDatabase}
            Set-ConnectionResult $name '완료' '고객 실행 결과 가져오기 완료. ⑦ 점검 이력과 ⑧ 레포트 / RAW 보관함에서 확인하세요.'
            return
        }
        if (-not (Assert-InfrastructureWsl -Install:($Tool -eq 'InfraInstall'))) {
            Set-ConnectionResult $name '재부팅 필요' 'WSL 필수 구성 요소 자동 설치 완료. Windows 재부팅 후 ⑦ Ansible 설치 / 확인을 다시 누르면 Kali와 Ansible 설치를 이어갑니다.'
            return 3010
        }
        $source=Join-Path $script:Root 'infrastructure'
        $linuxSource=(Invoke-InfrastructureKali -Arguments @('wslpath','-a',$source) -Quiet).Trim()
        $infraHome=Get-InfrastructureHome
        $installAnsible=$Tool -eq 'InfraInstall'
        if (-not $installAnsible) {
            $ansibleProbe='import ansible, winrm, pypsrp; from pathlib import Path; assert Path("'+$infraHome+'/collections/ansible_collections/ansible/windows/plugins/modules/win_ping.py").is_file()'
            try {Invoke-InfrastructureKali -Arguments @(($infraHome+'/.venv/bin/python'),'-c',$ansibleProbe) -Quiet | Out-Null}
            catch {$installAnsible=$true;Write-Log 'Ansible 전용 환경 또는 Windows 접속 구성 요소가 없어 자동 설치합니다.'}
        }
        if ($installAnsible) {
            Invoke-InfrastructureKali -Root -Arguments @('apt-get','update') | Out-Null
            Invoke-InfrastructureKali -Root -Arguments @('apt-get','install','-y','--no-install-recommends','python3-venv','git','openssh-client') | Out-Null
            $infraHome=Get-InfrastructureHome
            try {Invoke-InfrastructureKali -Arguments @('python3','-m','venv',($infraHome+'/.venv')) -Quiet | Out-Null}
            catch {
                Write-Log 'Ansible 전용 Python 환경 구성 요소를 Kali에 추가 설치합니다.'
                Invoke-InfrastructureKali -Root -Arguments @('apt-get','update') | Out-Null
                Invoke-InfrastructureKali -Root -Arguments @('apt-get','install','-y','--no-install-recommends','python3-venv','git') | Out-Null
            }
            Invoke-InfrastructureKali -Arguments @('bash',($linuxSource+'/scripts/manage-kali.sh'),'install') | Out-Null
            if ($Tool -eq 'InfraInstall') {
                Set-ConnectionResult $name '완료' 'Ansible Core 및 Windows 접속 구성 설치 완료. ⑦ 인프라 점검에서 서버 등록 후 접속 확인하세요.'
                return
            }
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
        if (@($servers | Where-Object {$_.Connection -eq 'ssh' -and $_.Password -and -not $_.KeyFile}).Count) {
            $passwordReady=Invoke-InfrastructureKali -Arguments @('python3','-c','import shutil; print(bool(shutil.which(''sshpass'')))') -Quiet
            if ($passwordReady.Trim() -ne 'True') {
                Write-Log 'SSH 아이디 / 비밀번호 접속에 필요한 sshpass를 자동 설치합니다.'
                Invoke-InfrastructureKali -Root -Arguments @('apt-get','update') | Out-Null
                Invoke-InfrastructureKali -Root -Arguments @('apt-get','install','-y','--no-install-recommends','sshpass','openssh-client') | Out-Null
            }
        }
        $plain=@()
        foreach ($server in $servers) {
            $row=@{}
            foreach ($prop in $server.PSObject.Properties) {$row[$prop.Name]=$prop.Value}
            foreach ($key in @('Password','BecomePassword')) {$row[$key]=Get-AiPlainKey ([string]$row[$key])}
            if ($server.PSObject.Properties['Profiles']) {
                $row.Profiles=@(foreach($instance in $server.Profiles){$instanceRow=@{};foreach($p in $instance.PSObject.Properties){$instanceRow[$p.Name]=$p.Value};$instanceRow.DbPassword=Get-AiPlainKey ([string]$instanceRow.DbPassword);$instanceRow})
            }
            $plain+=,$row
        }
        $request=@{Hosts=@();RunId=''}
        if ($Target) {$request=$Target | ConvertFrom-Json}
        $output=Join-Path $script:Runtime 'infra-runs'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $linuxOutput=(Invoke-InfrastructureKali -Arguments @('wslpath','-a',$output) -Quiet).Trim()
        $action=@{InfraDiscover='discover';InfraPreflight='preflight';InfraRun='run';InfraRetry='retry'}[$Tool]
        if (-not $action) {throw '지원하지 않는 인프라 작업입니다.'}
        $forks=20; $batch=100
        if ($request.PSObject.Properties['Forks']) {$forks=[int]$request.Forks}
        if ($request.PSObject.Properties['BatchSize']) {$batch=[int]$request.BatchSize}
        if ($forks -lt 1 -or $forks -gt 100 -or $batch -lt 1 -or $batch -gt 1000) {throw '동시 작업은 1~100, 배치는 1~1000으로 설정하세요.'}
        $payload=@{Servers=$plain;Hosts=@($request.Hosts);RunId=$request.RunId;Output=$linuxOutput;Forks=$forks;BatchSize=$batch} | ConvertTo-Json -Depth 14
        $before=@(Get-InfrastructureRuns | ForEach-Object Id)
        Set-ConnectionResult '인프라 서버 연결' '진행 중' '선택한 서버의 Ansible 접속 / 작업 응답을 확인합니다.'
        try {
            $outputText=Invoke-InfrastructureKali -Arguments @(($infraHome+'/.venv/bin/python'),($infraHome+'/scripts/gui-bridge.py'),$action) -InputText $payload -SuccessCodes @(0,1)
        } finally {$payload=$null;$plain=$null}
        if($Tool -eq 'InfraDiscover'){
            if($outputText -match '(?m)^인프라 작업 오류:\s*(.+)$'){throw $Matches[1]}
            Set-ConnectionResult $name '완료' '자동 감지 완료. 선택 창에서 실행 대상과 DB 접속 정보를 저장하세요.';return
        }
        $new=@(Get-InfrastructureRuns | Where-Object Id -notin $before | Select-Object -First 1)
        if (-not $new.Count) {
            if ($outputText -match '재실행 대상이 없습니다') {Set-ConnectionResult $name '완료' '재실행할 실패 서버가 없습니다.'; return}
            if ($outputText -match '(?m)^인프라 작업 오류:\s*(.+)$') {throw $Matches[1]}
            throw '점검 요약이 생성되지 않았습니다. 아래 로그의 접속/설정 오류를 확인하세요.'
        }
        $summary=$new[0].Summary
        Sync-InfrastructureReportDatabase
        $physical=@($summary.hosts).Count;if($summary.PSObject.Properties['physical_servers']){$physical=[int]$summary.physical_servers}
        $detail=('서버 '+$physical+'대 · OS/서비스 대상 '+@($summary.hosts).Count+'개 · 실행 실패 '+@($summary.failed_hosts).Count+'개 · 취약 발견 '+@($summary.vulnerable_hosts).Count+'개 · ⑦ 점검 결과에서 증적 확인')
        if ($summary.ansible_rc -eq 0) {Set-ConnectionResult '인프라 서버 연결' '연결됨' ('대상 '+@($summary.hosts).Count+'대 · Ansible 접속 및 작업 응답 확인 완료')}
        if (@($summary.failed_hosts).Count -or $summary.ansible_rc -ne 0) {
            $reasons=@(foreach ($hostName in @($summary.failed_hosts)) {
                $server=$summary.servers.PSObject.Properties[[string]$hostName]
                if ($server) {$hostName+': '+(@($server.Value.errors) -join '; ')}
            })
            if ($summary.ansible_rc -eq 0) {$detail='접속 및 수집 완료 · 항목 결과 미완전 · '+$detail}
            if ($reasons.Count) {$detail+=' · '+($reasons -join ' / ')}
            throw $detail
        }
        Set-ConnectionResult $name '완료' $detail
    } catch {Set-ConnectionResult $name '실패' $_.Exception.Message; throw}
}
