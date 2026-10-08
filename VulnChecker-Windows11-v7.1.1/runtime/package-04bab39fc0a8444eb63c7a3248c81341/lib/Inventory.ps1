function Get-ExistingOption {
    param([string]$Name)
    $options=$script:Config.PSObject.Properties['existing']
    if ($options -and $options.Value.PSObject.Properties[$Name]) { return [string]$options.Value.$Name }
    return ''
}

function Get-KaliToolPlan {
    if (-not $script:KaliToolCatalog) {$script:KaliToolCatalog=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\kali-tools.json') -Raw -Encoding UTF8 | ConvertFrom-Json}
    return @($script:KaliToolCatalog | Where-Object {$script:Config.profile -in $_.profiles})
}

function Get-SdkCandidates {
    $paths=@((Get-ExistingOption sdkRoot),$env:ANDROID_HOME,$env:ANDROID_SDK_ROOT,
        [Environment]::GetEnvironmentVariable('ANDROID_HOME','User'),[Environment]::GetEnvironmentVariable('ANDROID_SDK_ROOT','User'),
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),(Join-Path $env:LOCALAPPDATA 'VulnChecker\Android\Sdk'))
    $adb=Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($adb -and (Split-Path (Split-Path $adb.Source) -Leaf) -eq 'platform-tools') { $paths+=(Split-Path (Split-Path $adb.Source)) }
    return @($paths | Where-Object {$_} | Select-Object -Unique)
}

function Get-AvdCandidates {
    $paths=@((Get-ExistingOption avdRoot),$env:ANDROID_AVD_HOME,
        [Environment]::GetEnvironmentVariable('ANDROID_AVD_HOME','User'))
    if ($env:ANDROID_USER_HOME) { $paths+=Join-Path $env:ANDROID_USER_HOME 'avd' }
    $paths+=@((Join-Path $env:USERPROFILE '.android\avd'),(Join-Path $env:LOCALAPPDATA 'VulnChecker\Android\avd'))
    return @($paths | Where-Object {$_} | Select-Object -Unique)
}

function Get-WslDistributions {
    $items=New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue)) {
        $p=Get-ItemProperty -LiteralPath $entry.PSPath
        if ($p.PSObject.Properties['DistributionName'] -and $p.DistributionName) {
            $version=$null
            if ($p.PSObject.Properties['Version']) { $version=[int]$p.Version }
            $items.Add([pscustomobject]@{Name=$p.DistributionName;Version=$version})
        }
    }
    return @($items.ToArray())
}

function Get-LinuxInventory {
    param([string]$Distro)
    $options=@{hexstrikePath=(Get-ExistingOption hexstrikePath);hexstrikePython=(Get-ExistingOption hexstrikePython);opencodePath=(Get-ExistingOption opencodePath)}
    $options['toolNames']=@((Get-KaliToolPlan | ForEach-Object {$_.command}) + @('frida','objection','opencode') | Select-Object -Unique)
    $options['packages']=@((Get-KaliToolPlan | ForEach-Object {$_.package}) + @($script:Config.extraKaliPackages) | Select-Object -Unique)
    $json=$options | ConvertTo-Json -Compress
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $args=@('-d',$Distro,'--cd','/')
    $user=Get-ExistingOption kaliUser
    if ($user) { $args+=@('-u',$user) }
    $args+=@('--','python3','-',$encoded)
    $scriptText=Get-Content -LiteralPath (Join-Path $script:Root 'scripts\kali-inventory.py') -Raw -Encoding UTF8
    $out=Invoke-Native wsl.exe $args -InputText $scriptText -Quiet
    $jsonLines=@($out -split '\r?\n' | Where-Object {$_.Trim() -match '^\{.*\}$'})
    if ($jsonLines.Count -ne 1) {throw "Kali 도구 탐지 응답을 읽지 못했습니다: $out"}
    foreach ($line in @($out -split '\r?\n' | Where-Object {$_ -match '^wsl:'})) {Write-Log "Kali 탐지 경고: $line"}
    return ($jsonLines[0] | ConvertFrom-Json)
}

function Get-AndroidInventory {
    $sdks=New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in Get-SdkCandidates) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $sdks.Add([pscustomobject]@{Root=$root; Adb=(Test-Path -LiteralPath (Join-Path $root 'platform-tools\adb.exe')); Emulator=(Test-Path -LiteralPath (Join-Path $root 'emulator\emulator.exe'))})
    }
    $avds=New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in Get-AvdCandidates) {
        foreach ($ini in @(Get-ChildItem -LiteralPath $root -Filter *.ini -File -ErrorAction SilentlyContinue)) {
            $text=Get-Content -LiteralPath $ini.FullName -Raw -Encoding UTF8
            $path=Join-Path $root ($ini.BaseName+'.avd')
            $match=[regex]::Match($text,'(?m)^path=(.+)\r?$')
            if ($match.Success) { $path=$match.Groups[1].Value.Trim() }
            $config=Join-Path $path 'config.ini'
            if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { continue }
            $body=Get-Content -LiteralPath $config -Raw -Encoding UTF8
            $api=$null; $tag='';$arch=''
            $m=[regex]::Match($body.Replace('\','/'),'system-images/android-(\d+)/([^/]+)/([^/]+)/')
            if ($m.Success) { $api=[int]$m.Groups[1].Value; $tag=$m.Groups[2].Value; $arch=$m.Groups[3].Value }
            $candidate=($api -eq $script:Config.androidApi -and $tag -in @('default','google_apis') -and $arch -eq 'x86_64')
            $avds.Add([pscustomobject]@{Name=$ini.BaseName;Root=$root;Path=$path;Api=$api;Tag=$tag;Architecture=$arch;RootCandidate=$candidate})
        }
    }
    return [pscustomobject]@{Sdks=@($sdks.ToArray());Avds=@($avds.ToArray())}
}

function New-InventoryItem {
    param([string]$Id,[string]$Name,$Installed,$Ready,[string]$Location,[string]$Detail,[bool]$NeedsInstall=$false,[double]$GB=0)
    $status='미확인'
    if ($Installed -eq $false) { $status='미탐지' }
    if ($Installed -eq $true) { $status='설치됨'; if ($Ready -eq $false) { $status='설치됨 / 준비 필요' } }
    return [pscustomobject]@{Id=$Id;Name=$Name;Installed=$Installed;Ready=$Ready;Status=$status;Location=$Location;Detail=$Detail;NeedsInstall=$NeedsInstall;EstimatedGB=$GB}
}

function Get-InstallationInventory {
    $items=New-Object 'System.Collections.Generic.List[object]'
    foreach ($app in @(@{Id='burp';Name="Burp $($script:Config.burpEdition)";App='Burp';GB=1.0},@{Id='docker';Name='Docker Desktop';App='Docker';GB=4.0})) {
        if ($app.Id -in @('docker') -and $script:Config.profile -eq 'web') { continue }
        $path=Get-AppPath $app.App
        $items.Add((New-InventoryItem $app.Id $app.Name ([bool]$path) ([bool]$path) $path '등록 정보와 실제 실행 파일 확인' (-not [bool]$path) $app.GB))
    }
    if ($script:Config.profile -ne 'web') {
        $java=Get-JavaHome
        $items.Add((New-InventoryItem 'java' 'Java (SDK 가상 기기 생성용)' ([bool]$java) ([bool]$java) $java 'Standalone Java 또는 기존 JBR 재사용; Studio 설치 안 함' (-not [bool]$java) 0.5))
    }
    $distros=@(Get-WslDistributions)
    $wsl=[bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
    $items.Add((New-InventoryItem 'wsl' 'WSL' $wsl $null '' '배포판 등록 정보는 현재 Windows 사용자 기준' (-not $wsl) 1))
    $distro=@($distros | Where-Object {$_.Name -eq $script:Config.kaliDistro})
    $linux=$null
    if ($distro.Count) {
        $items.Add((New-InventoryItem 'kali' 'Kali 배포판' $true ($distro[0].Version -eq 2) $distro[0].Name "WSL version=$($distro[0].Version). 전용 계정 존재와 무관하게 설치 판정." $false 0))
        try { $linux=Get-LinuxInventory $distro[0].Name }
        catch { $items.Add((New-InventoryItem 'linux-probe' 'Kali 내부 탐지' $null $false '' $_.Exception.Message)) }
    } else { $items.Add((New-InventoryItem 'kali' 'Kali 배포판' $false $false $script:Config.kaliDistro '현재 계정에 해당 배포판 미등록' $true 6)) }
    $toolNames=@('opencode')
    $toolNames+=@(Get-KaliToolPlan | ForEach-Object {$_.command})
    if ($script:Config.profile -ne 'web') { $toolNames+=@('frida','objection') }
    foreach ($name in $toolNames) {
        $path=$null; $installed=$null; $ready=$null; $needs=$false; $detail='Kali 내부 탐지 불가. 미설치로 단정하지 않음.'
        if ($linux) { $property=$linux.commands.PSObject.Properties[$name]; if ($property) {$path=$property.Value}; $installed=[bool]$path; $ready=$installed; $needs=-not $installed; $detail="Kali 사용자 $($linux.user)의 PATH 및 알려진 사용자별 도구 경로 확인" }
        elseif (-not $distro.Count) { $installed=$false; $ready=$false; $needs=$true; $detail='Kali 배포판 설치 후 필요' }
        $windows=Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $path -and $windows) {
            $path=$windows.Source; $installed=$true; $ready=$false
            $detail='Windows에 설치됨. Kali 연동에 필요한 Linux 설치 여부는 별도로 확인.'
        }
        $gb=0.1; if ($name -eq 'opencode') { $gb=0.5 }
        $tool=@(Get-KaliToolPlan | Where-Object {$_.command -eq $name})
        if ($tool.Count -and $tool[0].PSObject.Properties['estimatedGB']) {$gb=$tool[0].estimatedGB}
        $items.Add((New-InventoryItem $name $name $installed $ready $path $detail $needs $gb))
    }
    $hexInstalled=$null; $hexReady=$null; $hexPath=''; $hexDetail='Kali 내부 탐지 불가'; $hexNeeds=$false
    if ($linux) {
        $hexPath=[string]$linux.hexstrike.path; $hexInstalled=[bool]$hexPath; $hexReady=($hexInstalled -and $linux.hexstrike.dependencies -eq $true); $hexNeeds=-not $hexReady
        $hexDetail="기존 사용자=$($linux.user); Python=$($linux.hexstrike.python); commit=$($linux.hexstrike.commit). 전용 경로/고정 커밋과 달라도 설치를 인정."
    } elseif (-not $distro.Count) { $hexInstalled=$false; $hexReady=$false; $hexNeeds=$true }
    $items.Add((New-InventoryItem 'hexstrike' 'HexStrike' $hexInstalled $hexReady $hexPath $hexDetail $hexNeeds 2))
    $android=$null
    if ($script:Config.profile -ne 'web') {
        $android=Get-AndroidInventory
        $sdk=@($android.Sdks | Where-Object {$_.Adb -and $_.Emulator})
        $items.Add((New-InventoryItem 'sdk' 'Android SDK / Emulator' ([bool]$sdk.Count) ([bool]$sdk.Count) (($sdk | ForEach-Object {$_.Root}) -join '; ') '환경변수·기본 SDK·전용 SDK·PATH 검사' (-not [bool]$sdk.Count) 2))
        $candidates=@($android.Avds | Where-Object {$_.RootCandidate})
        $avdFound=$android.Avds.Count -gt 0
        $managed=@($candidates | Where-Object {$_.Name -eq $script:Config.avdName})
        $detail="기존 AVD 탐지. 요청 API $($script:Config.androidApi) 루트 후보: $(($candidates | ForEach-Object {$_.Name}) -join ', '). 동적 분석은 전용 $($script:Config.avdName)에서 검증하며 기존 AVD는 변경하지 않음."
        $avdGB=6; if ($candidates.Count) { $avdGB=2 }
        $items.Add((New-InventoryItem 'avd' 'Android AVD' $avdFound $null (($android.Avds | ForEach-Object {$_.Name}) -join '; ') $detail (-not [bool]$managed.Count) $avdGB))
        $play=Get-PlaySpec
        $playImage=Join-Path (Get-SdkRoot) "system-images\android-$($play.Api)\google_apis_playstore\x86_64\system.img"
        $playAvd=@($android.Avds | Where-Object {$_.Name -eq $play.Name -and $_.Tag -eq 'google_apis_playstore' -and $_.Api -eq $play.Api})
        $items.Add((New-InventoryItem 'play-download' 'Google Play 다운로드 기기 (선택 설치)' (Test-Path $playImage) ([bool]$playAvd.Count) $play.Name '앱 가져오기 탭에서 필요할 때 설치. 다운로드 시 SDK 드라이브 6GB 여유 공간 검사. 루팅 기기와 분리.' $false 0))
        $imageInstalled=$null; $imageDetail='Docker 엔진이 정지했거나 접근 불가하면 이미지 설치 여부는 미확인.'; $imageNeeds=$false; $imagePath=''
        try {
            $docker=Get-DockerCli
            $os=Invoke-Native $docker @('info','--format','{{.OSType}}') -Quiet -TimeoutSeconds 10
            $items.Add((New-InventoryItem 'docker-engine' 'Docker 엔진' $true ($os.Trim() -eq 'linux') $docker "엔진 응답: $($os.Trim())"))
            try {
                $imagePath=Invoke-Native $docker @('image','inspect',$script:Config.mobSfImage,'--format','{{.Id}}') -Quiet -TimeoutSeconds 10
                $imageInstalled=$true; $imageDetail='Docker 로컬 이미지 확인'
            } catch {
                if ($_.Exception.Message -match '(?i)no such image|not found') { $imageInstalled=$false; $imageNeeds=$true; $imageDetail='엔진 정상 응답 후 지정한 이미지 미탐지' }
                else { $imageDetail='이미지 조회 실패. 권한/접근 오류를 미설치로 판정하지 않음.' }
            }
        } catch {
            $items.Add((New-InventoryItem 'docker-engine' 'Docker 엔진' $null $false '' '설치 여부와 별개로 엔진 정지/접근 불가. 재설치 판정하지 않음.'))
        }
        $items.Add((New-InventoryItem 'mobsf' 'MobSF Docker 이미지' $imageInstalled $null $imagePath $imageDetail $imageNeeds 5))
    }
    $script:Inventory=[pscustomobject]@{CheckedAt=(Get-Date).ToString('o');Items=@($items.ToArray());Distributions=$distros;Linux=$linux;Android=$android}
    $script:Inventory | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $script:Runtime 'inventory.json') -Encoding UTF8
    Write-InstallationReport $script:Inventory
    return $script:Inventory
}

function Write-InstallationReport {
    param($Inventory)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# 기존 설치 점검 결과')
    $lines.Add('')
    $lines.Add("확인 시각: $($Inventory.CheckedAt)")
    $lines.Add('')
    $lines.Add('설치 여부와 실행 준비 상태를 구분합니다. 미탐지는 정해진 검색 범위에서 찾지 못했다는 뜻이며, 미확인은 접근/엔진 상태 때문에 판단할 수 없다는 뜻입니다.')
    $lines.Add('')
    $lines.Add('| 도구 | 설치 상태 | 발견 위치 | 확인 근거 / 다음 작업 |')
    $lines.Add('| --- | --- | --- | --- |')
    foreach ($item in $Inventory.Items) {
        $cells=@($item.Name,$item.Status,$item.Location,$item.Detail) | ForEach-Object { ([string]$_).Replace('|','\|') -replace '[\r\n]+',' ' }
        $lines.Add('| '+($cells -join ' | ')+' |')
    }
    $plan=Get-CapacityPlan $Inventory
    $lines.Add('')
    $lines.Add("추가 설치/준비 예상: $($plan.AdditionalGB)GB. 여유 공간 포함 기준: $($plan.RequiredGB)GB. 실제 다운로드·작업 공간에 따라 달라질 수 있습니다.")
    $lines.Add('')
    $lines.Add('MobSF 이미지는 Docker 엔진이 응답할 때 확인합니다. 실제 AVD root/remount와 동적 분석 연결은 별도 실행 단계에서 검증합니다.')
    $lines.ToArray() | Set-Content -LiteralPath (Join-Path $script:Runtime 'installation-report.md') -Encoding UTF8
}

function Get-CapacityPlan {
    param($Inventory)
    $missing=@($Inventory.Items | Where-Object {$_.NeedsInstall})
    $gb=0.0
    foreach ($item in $missing) { $gb+=$item.EstimatedGB }
    $unknown=@($Inventory.Items | Where-Object {$null -eq $_.Installed} | ForEach-Object {$_.Name})
    $reserve=0
    if ($gb -gt 0) { $reserve=5; if ($script:Config.PSObject.Properties['reserveFreeGB']) { $reserve=$script:Config.reserveFreeGB } }
    return [pscustomobject]@{AdditionalGB=[math]::Round($gb,1);RequiredGB=[math]::Ceiling($gb+$reserve);Unknown=$unknown;Items=@($missing | Select-Object Name,EstimatedGB)}
}

function Write-Inventory {
    param($Inventory)
    foreach ($item in $Inventory.Items) { Write-Log "[$($item.Status)] $($item.Name) | $($item.Location) | $($item.Detail)" }
    Write-Log '설치 여부 검사 완료. 엔진 정지·전용 계정 없음·기존 경로 차이를 미설치로 처리하지 않습니다.'
}

function Get-KaliRuntime {
    param([switch]$Refresh)
    if ($script:LinuxRuntime -and -not $Refresh) { return $script:LinuxRuntime }
    $linux=Get-LinuxInventory $script:Config.kaliDistro
    $user=$linux.user; $home=$linux.home
    if ($user -eq 'root') { $user='vulnchecker'; $home='/home/vulnchecker' }
    $repo="$home/tools/hexstrike-ai"; $python="$repo/.venv/bin/python"
    if ($linux.user -ne 'root' -and $linux.hexstrike.path) {
        $repo=$linux.hexstrike.path
        $python="$repo/.venv/bin/python"
        if ($linux.hexstrike.python) { $python=$linux.hexstrike.python }
    }
    $oc="$home/tools/opencode/node_modules/.bin/opencode"
    if ($linux.user -ne 'root' -and $linux.commands.opencode) { $oc=$linux.commands.opencode }
    $script:LinuxRuntime=[pscustomobject]@{User=$user;Home=$home;HexRepo=$repo;HexPython=$python;OpenCode=$oc;Work="$home/work/vulnchecker";Wrapper="$home/tools/vulnchecker/hexstrike-local.py";Probe=$linux}
    return $script:LinuxRuntime
}

function Ensure-KaliIntegration {
    param($Runtime)
    Invoke-Kali -Arguments @('mkdir','-p',"$($Runtime.Home)/tools/vulnchecker",$Runtime.Work) -Quiet | Out-Null
    foreach ($pair in @(@('hexstrike-local.py',$Runtime.Wrapper),@('hexstrike-mcp-local.py',"$($Runtime.Home)/tools/vulnchecker/hexstrike-mcp-local.py"),@('web-tools.py',"$($Runtime.Home)/tools/vulnchecker/web-tools.py"),@('configure-mcp.py',"$($Runtime.Home)/tools/vulnchecker/configure-mcp.py"),@('check-mcp.py',"$($Runtime.Home)/tools/vulnchecker/check-mcp.py"),@('stop-hexstrike.py',"$($Runtime.Home)/tools/vulnchecker/stop-hexstrike.py"))) {
        $content=Get-Content -LiteralPath (Join-Path $script:Root ('scripts\'+$pair[0])) -Raw -Encoding UTF8
        Invoke-Kali -Arguments @('tee',$pair[1]) -InputText $content -Quiet | Out-Null
    }
    $entry=@{type='local';command=@($Runtime.HexPython,"$($Runtime.Home)/tools/vulnchecker/hexstrike-mcp-local.py",'--upstream',"$($Runtime.HexRepo)/hexstrike_mcp.py",'--server',"http://127.0.0.1:$($script:Config.hexstrikePort)",'--timeout','300');enabled=$true;timeout=360000} | ConvertTo-Json -Depth 8
    Invoke-Kali -Arguments @($Runtime.HexPython,"$($Runtime.Home)/tools/vulnchecker/configure-mcp.py","$($Runtime.Work)/opencode.json") -InputText $entry -Quiet | Out-Null
    Write-Log "OpenCode MCP hexstrike 활성화: $($Runtime.Work)/opencode.json (기존 설정 변경 전 백업). 사용자=$($Runtime.User)"
}
