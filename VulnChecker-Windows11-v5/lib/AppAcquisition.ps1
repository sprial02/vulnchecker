# Play acquisition is isolated from the rooted AVD and its proxy/account data.
function Get-PlaySpec {
    $api=$script:Config.androidApi
    if ($script:Config.PSObject.Properties['playApi']) { $api=[int]$script:Config.playApi }
    $name="VulnChecker_Play_API$api"
    if ($script:Config.PSObject.Properties['playAvdName']) { $name=[string]$script:Config.playAvdName }
    if ($api -lt 28 -or $api -gt 36 -or $name -notmatch '^VulnChecker_Play_[A-Za-z0-9_]{1,40}$' -or $name -eq $script:Config.avdName) { throw 'Google Play 전용 AVD 설정이 잘못되었습니다.' }
    return @{Api=$api;Name=$name;Serial='emulator-5560';Image="system-images;android-$api;google_apis_playstore;x86_64"}
}

function Assert-SourceSerial {
    param([string]$Serial)
    if ($Serial -notmatch '^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$') { throw '다운로드 기기 또는 실제 단말의 ADB 식별자를 선택하세요.' }
}

function Assert-ManagedAvd {
    param([string]$Serial,[string]$Name)
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $actual=Invoke-Native $adb @('-s',$Serial,'emu','avd','name') -Quiet
    if (($actual -split '\r?\n')[0].Trim() -ne $Name) { throw "$Serial 포트에 다른 에뮬레이터가 있습니다. 다른 기기는 변경하지 않았습니다." }
}

function Ensure-ApkTools {
    param([switch]$AcceptLicenses)
    Set-AndroidEnvironment -RequireJava
    $sdk=Get-SdkRoot
    $versions=@(Get-ChildItem (Join-Path $sdk 'build-tools') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object {[version]$_.Name} -Descending)
    foreach ($version in $versions) {
        if ((Test-Path (Join-Path $version.FullName 'aapt.exe')) -and (Test-Path (Join-Path $version.FullName 'aapt2.exe')) -and (Test-Path (Join-Path $version.FullName 'apksigner.bat'))) { return $version.FullName }
    }
    if (-not $AcceptLicenses) { throw 'APK 검사 도구 설치가 필요합니다. 설치 탭의 약관 확인을 선택한 뒤 다시 실행하세요.' }
    Install-AcquisitionSdkPackage 'build-tools;36.0.0'
    if (-not (Test-Path (Join-Path $sdk 'build-tools\36.0.0\apksigner.bat'))) { throw 'APK 검사 도구 설치 실패' }
    return Ensure-ApkTools
}

function Install-AcquisitionSdkPackage {
    param([string]$Package)
    $sdk=Get-SdkRoot
    $cli=Join-Path $sdk 'cmdline-tools\latest\bin\android.exe'
    $yes=(1..100 | ForEach-Object {'y'}) -join "`n"
    if (Test-Path $cli) { Invoke-Native $cli @("--sdk=$sdk",'sdk','install',$Package.Replace(';','/')) -InputText $yes | Out-Null }
    else {
        $manager=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
        Invoke-Native $manager @("--sdk_root=$sdk",'--licenses') -InputText $yes | Out-Null
        Invoke-Native $manager @("--sdk_root=$sdk",('"'+$Package+'"')) -InputText $yes | Out-Null
    }
}

function Initialize-PlayAvd {
    param([switch]$AcceptLicenses)
    Set-AndroidEnvironment -RequireJava
    $spec=Get-PlaySpec; $sdk=Get-SdkRoot
    $folder=Join-Path $sdk "system-images\android-$($spec.Api)\google_apis_playstore\x86_64"
    if (-not (Test-Path (Join-Path $folder 'system.img'))) {
        if (-not $AcceptLicenses) { throw 'Play 이미지 추가 다운로드가 필요합니다. 설치 탭의 약관 확인을 선택하세요.' }
        $drive=Get-Item -LiteralPath $sdk
        if ($drive.PSDrive.Free -lt 6GB) { throw 'Google Play 이미지와 앱 저장 공간을 위해 SDK 드라이브에 최소 6GB 여유 공간이 필요합니다.' }
        $manager=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
        if (-not (Test-Path $manager)) { throw '먼저 설치 탭에서 Android SDK를 설치하세요.' }
        Write-Log "Google Play 이미지 추가 설치: $($spec.Image)"
        Install-AcquisitionSdkPackage $spec.Image
        if (-not (Test-Path (Join-Path $folder 'system.img'))) { throw 'Google Play 이미지 설치를 확인할 수 없습니다. 다운로드 로그를 확인하세요.' }
    }
    $ini=Join-Path (Get-AvdRoot) "$($spec.Name).avd\config.ini"
    if (-not (Test-Path $ini)) {
        Invoke-Native (Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat') @('create','avd','--name',$spec.Name,'--package',$spec.Image,'--device','pixel_2') -InputText 'no' | Out-Null
    }
    $text=Get-Content -LiteralPath $ini -Raw
    if ($text.Replace('\','/') -notmatch [regex]::Escape("system-images/android-$($spec.Api)/google_apis_playstore/x86_64/")) { throw '기존 Play AVD의 시스템 이미지가 설정과 다릅니다.' }
    foreach ($setting in @('hw.mainKeys=no','hw.ramSize=2048','hw.cpu.ncore=2','hw.gpu.enabled=yes','hw.gpu.mode=software','PlayStore.enabled=true')) {
        $key=($setting -split '=')[0]; $pattern='(?m)^'+[regex]::Escape($key)+'\s*=.*$'
        if ($text -match $pattern) { $text=[regex]::Replace($text,$pattern,$setting) } else { $text+="`n$setting`n" }
    }
    [IO.File]::WriteAllText($ini,$text,(New-Object Text.UTF8Encoding($false)))
    return $spec
}

function Start-PlayDownload {
    param([switch]$AcceptLicenses,[string]$Package='',[switch]$WipeData)
    $spec=Initialize-PlayAvd -AcceptLicenses:$AcceptLicenses
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $devices=Invoke-Native $adb @('devices') -Quiet
    if ($devices -match '(?m)^emulator-5560\s+') {
        Assert-ManagedAvd $spec.Serial $spec.Name
        if ($WipeData) { throw '계정 데이터 초기화 전에 다운로드 기기 종료 버튼을 눌러주세요.' }
    } else {
        foreach ($port in @(5560,5561)) { if (-not (Test-PortAvailable $port)) { throw "Google Play 에뮬레이터 포트 $port 사용 중" } }
        $args=@('-avd',$spec.Name,'-no-snapshot','-gpu','swiftshader','-memory','2048','-cores','2','-port','5560')
        if ($WipeData) { $args+='-wipe-data' }
        $p=Start-Process (Join-Path (Get-SdkRoot) 'emulator\emulator.exe') -WindowStyle Hidden -ArgumentList $args -RedirectStandardOutput (Join-Path $script:Runtime 'play-stdout.log') -RedirectStandardError (Join-Path $script:Runtime 'play-stderr.log') -PassThru
        $script:State['play-process']=@{pid=$p.Id;start=$p.StartTime.ToString('o');avd=$spec.Name}; Save-State
    }
    $end=(Get-Date).AddMinutes(5); $booted=$false
    while ((Get-Date) -lt $end) {
        try { if ((Invoke-Native $adb @('-s',$spec.Serial,'shell','getprop','sys.boot_completed') -Quiet).Trim() -eq '1') { $booted=$true; break } } catch {}
        Start-Sleep -Seconds 3
    }
    if (-not $booted) { throw 'Google Play 기기 부팅 시간 초과. play-stderr.log를 확인하세요.' }
    Assert-ManagedAvd $spec.Serial $spec.Name
    Invoke-Native $adb @('-s',$spec.Serial,'shell','settings','put','global','http_proxy',':0') -Quiet | Out-Null
    Invoke-Native $adb @('-s',$spec.Serial,'reverse','--remove-all') -Quiet | Out-Null
    Invoke-Native $adb @('-s',$spec.Serial,'shell','cmd','overlay','enable-exclusive','--category','com.android.internal.systemui.navbar.threebutton') -Quiet | Out-Null
    $play=Invoke-Native $adb @('-s',$spec.Serial,'shell','pm','path','com.android.vending') -Quiet
    if ($play -notmatch '^package:') { throw '다운로드 기기에 Google Play Store가 없습니다.' }
    $intent=@('-s',$spec.Serial,'shell','am','start','-a','android.intent.action.VIEW','-d')
    if ($Package) { Assert-AppPackage $Package; $intent+="market://details?id=$Package" } else { $intent+='market://search?q=apps' }
    $intent+=@('-p','com.android.vending'); Invoke-Native $adb $intent -Quiet | Out-Null
    Set-ConnectionResult 'Google Play 다운로드' '사용자 작업' '분석용 Google 계정으로 직접 로그인하고 앱을 설치한 뒤 앱 목록 새로고침을 누르세요. 다운로드 기기는 프록시를 사용하지 않습니다.'
}

function Stop-PlayDownload {
    $spec=Get-PlaySpec; $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    if (-not (Test-Path -LiteralPath $adb)) { return }
    $devices=Invoke-Native $adb @('devices') -Quiet
    if ($devices -match '(?m)^emulator-5560\s+') {
        Assert-ManagedAvd $spec.Serial $spec.Name
        Invoke-Native $adb @('-s',$spec.Serial,'emu','kill') -Quiet | Out-Null
        Start-Sleep -Seconds 3
    }
    Stop-ManagedProcessTree 'play-process' @('emulator')
}

function Assert-AcquisitionDeviceConnected {
    param([string]$Serial)
    Assert-SourceSerial $Serial
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $devices=Invoke-Native $adb @('devices') -Quiet
    $match=[regex]::Match($devices,'(?m)^'+[regex]::Escape($Serial)+'\s+(\S+)')
    if (-not $match.Success) {
        if ($Serial -eq 'emulator-5560') {throw 'Google Play 다운로드 기기(emulator-5560)가 연결되어 있지 않습니다. 앱 가져오기 탭의 1) Google Play 기기 실행을 누르고 부팅 완료 후 앱 목록을 새로고침하세요.'}
        throw "기기 $Serial 연결이 없습니다. USB 연결과 기기 식별자를 확인한 뒤 다시 조회하세요."
    }
    if ($match.Groups[1].Value -eq 'unauthorized') {throw "기기 $Serial USB 디버깅이 승인되지 않았습니다. 단말 화면에서 허용한 뒤 다시 조회하세요."}
    if ($match.Groups[1].Value -ne 'device') {throw "기기 $Serial 상태가 $($match.Groups[1].Value)입니다. 부팅 완료와 ADB 연결을 확인한 뒤 다시 조회하세요."}
}
function Get-AcquisitionApps {
    param([string]$Serial)
    Assert-SourceSerial $Serial
    Assert-AcquisitionDeviceConnected $Serial
    if ($Serial -eq 'emulator-5560') { $spec=Get-PlaySpec; Assert-ManagedAvd $Serial $spec.Name }
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $apps=@((Invoke-Native $adb @('-s',$Serial,'shell','pm','list','packages','-3') -Quiet) -split '\r?\n' | Where-Object {$_ -match '^package:'} | ForEach-Object {$_.Substring(8).Trim()} | Sort-Object)
    @{Serial=$Serial;Packages=$apps;Updated=(Get-Date).ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:Runtime 'acquisition-apps.json') -Encoding UTF8
    Set-ConnectionResult '설치 앱 목록' '확인됨' "$Serial 사용자 앱 $($apps.Count)개. 패키지를 선택하거나 직접 입력하세요."
    return $apps
}

function Get-AcquisitionDevices {
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $output=Invoke-Native $adb @('devices') -Quiet
    $devices=@()
    foreach ($line in ($output -split '\r?\n')) {
        if ($line -match '^(\S+)\s+(device|offline|unauthorized)\b' -and $Matches[1] -notmatch '^emulator-') {
            $devices+=@{Serial=$Matches[1];Status=$Matches[2]}
        }
    }
    @{Devices=$devices;Updated=(Get-Date).ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:Runtime 'acquisition-devices.json') -Encoding UTF8
    Set-ConnectionResult '실제 단말 연결' '확인됨' "단말 $($devices.Count)개. 목록에는 디버깅 허용된 기기만 선택할 수 있습니다. unauthorized는 단말 화면에서 USB 디버깅을 허용하고 다시 갱신하세요."
}

function Get-ApkSetInfo {
    param([string[]]$Paths,[string]$Tools)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not $Paths.Count) { throw 'APK 파일을 선택하세요.' }
    $items=@(); $splits=@{}; $libraries=@()
    foreach ($path in $Paths) {
        $path=(Resolve-Path -LiteralPath $path).Path
        if ([IO.Path]::GetExtension($path) -ne '.apk') { throw 'APK 파일만 지원합니다. split APK는 함께 선택하세요.' }
        $badging=Invoke-Native (Join-Path $Tools 'aapt.exe') @('dump','badging',$path) -Quiet
        $match=[regex]::Match($badging,"(?m)^package: name='([^']+)' versionCode='([^']+)' versionName='([^']*)'([^\r\n]*)")
        if (-not $match.Success) { throw "APK 패키지 정보 식별 실패: $path" }
        $split=[regex]::Match($match.Groups[4].Value,"split='([^']+)'").Groups[1].Value
        if ($splits.ContainsKey($split)) { throw '중복 base 또는 split APK가 있습니다.' }; $splits[$split]=$true
        $signature=Invoke-Native (Join-Path $Tools 'apksigner.bat') @('verify','--print-certs',$path) -Quiet
        $certs=@([regex]::Matches($signature,'(?m)^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)') | ForEach-Object {$_.Groups[1].Value.ToLowerInvariant()} | Sort-Object)
        if (-not $certs.Count) { throw "APK 서명 확인 실패: $path" }
        $zip=[IO.Compression.ZipFile]::OpenRead($path)
        try { $libraries+=@($zip.Entries | Where-Object {$_.FullName -match '^lib/[^/]+/[^/]+\.so$'} | ForEach-Object {$_.FullName}) } finally { $zip.Dispose() }
        $min=[regex]::Match($badging,"(?m)^sdkVersion:'(\d+)'")
        $items+=@{Path=$path;Package=$match.Groups[1].Value;VersionCode=$match.Groups[2].Value;VersionName=$match.Groups[3].Value;Split=$split;Certificates=($certs -join ',');MinSdk=$(if ($min.Success) {[int]$min.Groups[1].Value} else {0});SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    }
    $base=@($items | Where-Object {-not $_.Split})
    if ($base.Count -ne 1 -or $base[0].MinSdk -eq 0) { throw '정상 base APK 1개와 minSdk 정보가 필요합니다.' }
    foreach ($item in $items) {
        if ($item.Package -ne $base[0].Package -or $item.VersionCode -ne $base[0].VersionCode -or $item.Certificates -ne $base[0].Certificates) { throw 'APK 세트의 패키지, 버전 또는 서명이 일치하지 않습니다.' }
    }
    $xml=Invoke-Native (Join-Path $Tools 'aapt2.exe') @('dump','xmltree','--file','AndroidManifest.xml',$base[0].Path) -Quiet
    if ($xml -match 'isSplitRequired[^\r\n]*(true|0xffffffff)' -and $items.Count -eq 1) { throw 'split APK가 필요한 앱입니다. base.apk 외 전체 split 파일을 함께 가져오세요.' }
    return @{Package=$base[0].Package;VersionCode=$base[0].VersionCode;VersionName=$base[0].VersionName;MinSdk=$base[0].MinSdk;Items=$items;Libraries=$libraries;Abis=@($libraries | ForEach-Object {($_ -split '/')[1]} | Sort-Object -Unique)}
}

function Assert-ApkCompatibility {
    param($Info,[int]$Api,[string[]]$Abis)
    if ($Info.MinSdk -gt $Api) { throw "앱 최소 Android API $($Info.MinSdk), 분석 기기는 API $Api 입니다. 호환되는 분석 단말 또는 고객 테스트 빌드가 필요합니다." }
    if (@($Info.Abis).Count -and -not @($Info.Abis | Where-Object {$_ -in $Abis}).Count) { throw "앱 CPU=$($Info.Abis -join ',') / 분석 기기 CPU=$($Abis -join ','). 호환되는 APK 또는 분석 단말이 필요합니다." }
}

function Import-AcquisitionApp {
    param([string]$Serial,[string]$Package,[string[]]$ApkPaths=@(),[switch]$AcceptLicenses,[switch]$LaunchWithBypass,[ValidateSet('Auto','Burp','Direct','Preview')][string]$CaptureRoute='Preview')
    foreach ($name in @('APK 확보','APK 호환성','분석 기기 설치','앱 초기 실행','통신 분석')) { Set-ConnectionResult $name '대기' '앱 확보 및 검사 완료 후 진행' }
    $tools=Ensure-ApkTools -AcceptLicenses:$AcceptLicenses
    $folder=Join-Path $script:Runtime ('acquired-apps\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $files=@()
    if ($ApkPaths.Count) {
        for ($i=0;$i -lt $ApkPaths.Count;$i++) {
            if ([IO.Path]::GetExtension($ApkPaths[$i]) -ne '.apk') { throw 'APK 파일만 선택하세요. 압축 컨테이너는 APK 세트로 먼저 풀어야 합니다.' }
            $target=Join-Path $folder "$i.apk"; Copy-Item -LiteralPath $ApkPaths[$i] -Destination $target; $files+=$target
        }
        $origin='customer-apk'
    } else {
        Assert-SourceSerial $Serial; Assert-AppPackage $Package
        Assert-AcquisitionDeviceConnected $Serial
        if ($Serial -eq 'emulator-5560') { $spec=Get-PlaySpec; Assert-ManagedAvd $Serial $spec.Name }
        $paths=@((Invoke-Native $adb @('-s',$Serial,'shell','pm','path',$Package) -Quiet) -split '\r?\n' | Where-Object {$_ -match '^package:'} | ForEach-Object {$_.Substring(8).Trim()})
        if (-not $paths.Count) { throw '선택한 기기에 앱이 설치되어 있지 않습니다.' }
        for ($i=0;$i -lt $paths.Count;$i++) {
            $target=Join-Path $folder "$i.apk"; Invoke-Native $adb @('-s',$Serial,'pull',$paths[$i],$target) -Quiet | Out-Null; $files+=$target
        }
        $origin=$Serial
    }
    $info=Get-ApkSetInfo -Paths $files -Tools $tools
    Assert-AppPackage $info.Package
    if ($Package -and $info.Package -ne $Package) { throw '입력한 패키지명과 가져온 APK가 다릅니다.' }
    $info['Origin']=$origin; $info['Status']='collected'; $info['Acquired']=(Get-Date).ToString('o')
    $record=Join-Path $folder 'manifest.json'
    $info | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $record -Encoding UTF8
    $script:State['acquired-app']=@{package=$info.Package;manifest=$record;status='collected'}; Save-State
    Set-ConnectionResult 'APK 확보' '완료' "$($info.Package) / 버전 $($info.VersionName) / APK $($files.Count)개 / 라이브러리 $($info.Libraries.Count)개. 원본 서명과 파일 해시 기록."
    # Check API before launching the rooted AVD; never replace its system image.
    if ($info.MinSdk -gt $script:Config.androidApi) { throw "앱 최소 Android API $($info.MinSdk), 분석 기기는 API $($script:Config.androidApi)입니다. 호환되는 분석 단말이 필요합니다." }
    Start-Emulator; Wait-AdbRoot
    Assert-ManagedAvd 'emulator-5554' $script:Config.avdName
    $api=[int](Invoke-Native $adb @('-s','emulator-5554','shell','getprop','ro.build.version.sdk') -Quiet).Trim()
    $abis=((Invoke-Native $adb @('-s','emulator-5554','shell','getprop','ro.product.cpu.abilist') -Quiet).Trim() -split ',')
    Assert-ApkCompatibility $info $api $abis
    Set-ConnectionResult 'APK 호환성' '통과' "API $api / CPU $($abis -join ',') / 패키지·버전·서명 일치"
    Invoke-Native $adb (@('-s','emulator-5554','install-multiple','-r')+$files) | Out-Null
    $installed=@((Invoke-Native $adb @('-s','emulator-5554','shell','pm','path',$info.Package) -Quiet) -split '\r?\n' | Where-Object {$_ -match '^package:'})
    if ($installed.Count -ne $files.Count) { throw '설치 후 APK 개수가 가져온 세트와 다릅니다.' }
    $script:State['acquired-app'].status='installed'; Save-State
    $info.Status='installed'; $info | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $record -Encoding UTF8
    Set-ConnectionResult '분석 기기 설치' '완료' '전체 APK 세트 설치. Google 계정과 앱의 사용자 데이터는 복사하지 않습니다.'
    Get-InstalledAnalysisApps | Out-Null
    Set-MobileAnalysisTarget $info.Package | Out-Null
    if ($LaunchWithBypass) {
        Set-ConnectionResult '앱 초기 실행' '진행 중' '일반 실행 대신 Frida 주입 후 앱을 실행합니다.'
        Start-RootBypassWorkflow $info.Package -CaptureRoute $CaptureRoute
        $script:State['acquired-app'].status='instrumented'; Save-State
        $info.Status='instrumented'; $info | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $record -Encoding UTF8
        Set-ConnectionResult '앱 초기 실행' '주입 후 실행' "$($info.Package) / Frida Java 후크 초기화 확인. 화면·로그인·주요 기능은 직접 확인하세요."
        $captureDetail='선택한 통신 경로 설정 완료. API 응답과 앱 화면을 확인하세요.'; $captureStatus='수집 준비'
        if ($CaptureRoute -eq 'Preview') {$captureDetail='설치 후 실행 확인 완료. 실행 탭에서 MobSF 정적/동적 분석 또는 모바일 API 분석(앱 → Burp)을 선택하세요.'; $captureStatus='분석 선택 대기'}
        Set-ConnectionResult '통신 분석' $captureStatus $captureDetail
        return
    }
    # Use a fresh logcat process/timestamp window without clearing existing logs.
    Invoke-Native $adb @('-s','emulator-5554','shell','am','force-stop',$info.Package) -Quiet | Out-Null
    $since=(Invoke-Native $adb @('-s','emulator-5554','shell',"date '+%m-%d %H:%M:%S.000'") -Quiet).Trim()
    $launch=Invoke-Native $adb @('-s','emulator-5554','shell','monkey','-p',$info.Package,'-c','android.intent.category.LAUNCHER','1') -Quiet
    if ($launch -match 'No activities found|monkey aborted') { throw '실행 가능한 앱 화면이 없습니다.' }
    Start-Sleep -Seconds 10
    $process=(Invoke-Native $adb @('-s','emulator-5554','shell',"pidof $($info.Package) || true") -Quiet).Trim()
    $crash=Invoke-Native $adb @('-s','emulator-5554','logcat','-d','-b','crash','-T',$since) -Quiet
    $crash | Set-Content (Join-Path $folder 'launch-crash.log') -Encoding UTF8
    if (-not $process -or $crash -match ('Process:\s*'+[regex]::Escape($info.Package)+',') ) {
        $script:State['acquired-app'].status='launch-failed'; Save-State
        $info.Status='launch-failed'; $info | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $record -Encoding UTF8
        throw "앱 실행 실패. $folder\launch-crash.log 확인. 네이티브 라이브러리 누락·루팅 탐지·Play 라이선스/무결성 등을 구분해야 합니다."
    }
    $script:State['acquired-app'].status='process-alive'; Save-State
    $info.Status='process-alive'; $info | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $record -Encoding UTF8
    Set-ConnectionResult '앱 초기 실행' '프로세스 확인' '10초 후 프로세스 유지 및 새 충돌 없음. 루팅 차단 안내가 떠도 프로세스는 유지될 수 있습니다. 실제 화면·로그인·주요 기능은 직접 확인하세요. 루팅 차단은 실행 탭의 루팅 우회 후 앱 실행을 사용하세요.'
    Set-ConnectionResult '통신 분석' '준비 가능' '실행/연동 탭의 모바일 분석 실행 후 앱을 다시 실행하세요. APK 설치 성공만으로 TLS/pinning 통과를 판단하지 않습니다.'
}

function Invoke-AppAcquisition {
    param([string]$Tool,[string]$Package,[string]$SourceSerial,[string[]]$ApkPaths=@(),[switch]$AcceptLicenses,[switch]$LaunchWithBypass,[ValidateSet('Auto','Burp','Direct','Preview')][string]$CaptureRoute='Preview')
    Set-ConnectionResult "앱 확보: $Tool" '진행 중' '선택한 앱 확보 작업 진행'
    try {
        switch ($Tool) {
            'PlayDownload' { Start-PlayDownload -Package $Package -AcceptLicenses:$AcceptLicenses }
            'RefreshApps' { Get-AcquisitionApps $SourceSerial | Out-Null }
            'RefreshDevices' { Get-AcquisitionDevices }
            'AcquireApp' { Import-AcquisitionApp -Serial $SourceSerial -Package $Package -ApkPaths $ApkPaths -AcceptLicenses:$AcceptLicenses -LaunchWithBypass:$LaunchWithBypass -CaptureRoute $CaptureRoute }
            'ResetPlay' { Stop-PlayDownload; Start-PlayDownload -WipeData -AcceptLicenses:$AcceptLicenses; Set-ConnectionResult 'Google Play 초기화' '완료' '전용 다운로드 기기의 계정·설치 앱·사용자 데이터 초기화. 추출된 APK 및 분석 기기 데이터는 유지.' }
        }
        Set-ConnectionResult "앱 확보: $Tool" '완료' '세부 결과를 확인하세요. Google 로그인·앱 설치는 다운로드 기기에서 직접 수행합니다.'
    } catch {
        if ($Tool -eq 'AcquireApp') {
            if ($LaunchWithBypass -and $script:State.ContainsKey('acquired-app') -and $script:State['acquired-app'].status -eq 'installed') {
                Set-ConnectionResult '앱 초기 실행' '주입 실패' 'APK는 설치되었지만 Frida 실행 단계가 실패했습니다. 오류를 해결한 뒤 실행 탭의 루팅 우회 후 앱 실행으로 재시도하세요.'
            }
            foreach ($name in @('APK 확보','APK 호환성','분석 기기 설치','앱 초기 실행','통신 분석')) {
                if ($script:State.ContainsKey('connections') -and $script:State['connections'].ContainsKey($name) -and $script:State['connections'][$name].Status -eq '대기') { Set-ConnectionResult $name '미완료' '앞 단계 실패. 실패 내용을 해결한 뒤 다시 가져오세요.' }
            }
        }
        Set-ConnectionResult "앱 확보: $Tool" '실패' $_.Exception.Message; throw
    }
}
