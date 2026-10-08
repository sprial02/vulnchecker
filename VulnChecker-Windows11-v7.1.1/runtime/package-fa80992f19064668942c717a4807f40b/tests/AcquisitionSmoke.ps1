#Requires -Version 5.1
[CmdletBinding()]
param([switch]$RunDeviceTransfer)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$ctx=Initialize-Context -Root $root -ConfigPath (Join-Path $root 'config.json')
$tools=Ensure-ApkTools
$folder=Join-Path $ctx.Runtime ('acquisition-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$sdk=Get-SdkRoot
$platform=@(Get-ChildItem (Join-Path $sdk 'platforms') -Directory | Where-Object {Test-Path (Join-Path $_.FullName 'android.jar')} | Sort-Object Name -Descending)[0]
$keytool=Join-Path (Get-JavaHome) 'bin\keytool.exe'
$key=Join-Path $folder 'fixture.jks'
Invoke-Native $keytool @('-genkeypair','-keystore',$key,'-storepass','fixture-only','-keypass','fixture-only','-alias','fixture','-keyalg','RSA','-keysize','2048','-validity','2','-dname','CN=VulnChecker Test') -Quiet | Out-Null
function New-FixtureApk {
    param([string]$Name,[string]$Split,[string]$Version='1')
    $manifestDir=Join-Path $folder $Name
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
    $manifest=Join-Path $manifestDir 'AndroidManifest.xml'
    $apk=Join-Path $folder "$Name.apk"
    if ($Split) {
        $xml='<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.vulnchecker.acquisitiontest" split="'+$Split+'" android:versionCode="'+$Version+'" android:versionName="1"><uses-sdk android:minSdkVersion="21"/><application android:hasCode="false"/></manifest>'
    } else {
        $xml='<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.vulnchecker.acquisitiontest" android:versionCode="1" android:versionName="1"><uses-sdk android:minSdkVersion="21"/><application android:hasCode="false" android:isSplitRequired="true" android:label="Acquisition test"><activity android:name="android.app.Activity" android:exported="true"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity></application></manifest>'
    }
    [IO.File]::WriteAllText($manifest,$xml,(New-Object Text.UTF8Encoding($false)))
    Invoke-Native (Join-Path $tools 'aapt.exe') @('package','-f','-M',$manifest,'-I',(Join-Path $platform.FullName 'android.jar'),'-F',$apk) -Quiet | Out-Null
    Invoke-Native (Join-Path $tools 'apksigner.bat') @('sign','--ks',$key,'--ks-pass','pass:fixture-only','--key-pass','pass:fixture-only',$apk) -Quiet | Out-Null
    return $apk
}
function Expect-Failure {
    param([scriptblock]$Work,[string]$Name)
    $failed=$false
    try { & $Work | Out-Null } catch {$failed=$true; Write-Host "PASS $Name : $($_.Exception.Message)"}
    if (-not $failed) {throw "Expected rejection: $Name"}
}
$base=New-FixtureApk 'base' ''
$split=New-FixtureApk 'split' 'config.en'
$wrong=New-FixtureApk 'wrong-version' 'config.en' '2'
$info=Get-ApkSetInfo @($base,$split) $tools
if ($info.Package -ne 'com.vulnchecker.acquisitiontest' -or $info.Items.Count -ne 2 -or $info.MinSdk -ne 21) {throw 'Complete signed split metadata failed'}
Write-Host 'PASS complete signed split APK inspection'
Expect-Failure {Get-ApkSetInfo @($base) $tools} 'Missing required splits'
Expect-Failure {Get-ApkSetInfo @($base,$base) $tools} 'Duplicate base'
Expect-Failure {Get-ApkSetInfo @($base,$wrong) $tools} 'Version mismatch'
$otherKey=Join-Path $folder 'other-fixture.jks'
Invoke-Native $keytool @('-genkeypair','-keystore',$otherKey,'-storepass','fixture-only','-keypass','fixture-only','-alias','other','-keyalg','RSA','-keysize','2048','-validity','2','-dname','CN=Other Fixture') -Quiet | Out-Null
$otherSplit=Join-Path $folder 'other-signature.apk'
Invoke-Native (Join-Path $tools 'apksigner.bat') @('sign','--ks',$otherKey,'--ks-pass','pass:fixture-only','--key-pass','pass:fixture-only','--out',$otherSplit,$split) -Quiet | Out-Null
Expect-Failure {Get-ApkSetInfo @($base,$otherSplit) $tools} 'Certificate mismatch'
Expect-Failure {Assert-ApkCompatibility @{MinSdk=35;Abis=@()} 30 @('x86_64')} 'Android minimum version'
Expect-Failure {Assert-ApkCompatibility @{MinSdk=21;Abis=@('arm64-v8a')} 30 @('x86_64')} 'CPU incompatibility'
Expect-Failure {Assert-SourceSerial 'device;injection'} 'Invalid device identifier'
if ($RunDeviceTransfer) {
    $adb=Join-Path $sdk 'platform-tools\adb.exe'
    try {
        Assert-ManagedAvd 'emulator-5560' (Get-PlaySpec).Name
        Invoke-Native $adb @('-s','emulator-5560','install-multiple','-r',$base,$split) -Quiet | Out-Null
        $apps=Get-AcquisitionApps 'emulator-5560'
        if ('com.vulnchecker.acquisitiontest' -notin $apps) {throw 'Source app discovery failed'}
        Import-AcquisitionApp -Serial 'emulator-5560' -Package 'com.vulnchecker.acquisitiontest'
        $saved=& (Get-Module Core) {$script:State['acquired-app']}
        $record=Get-Content -LiteralPath $saved.manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.status -ne 'process-alive' -or $record.Items.Count -ne 2) {throw 'Transfer/run state failed'}
        Write-Host 'PASS installed split extraction -> signed validation -> rooted install -> app process/crash check'
    } finally {
        foreach ($serial in @('emulator-5560','emulator-5554')) {
            try {Invoke-Native $adb @('-s',$serial,'uninstall','com.vulnchecker.acquisitiontest') -Quiet | Out-Null} catch {}
        }
        & (Get-Module Core) {if ($script:State.ContainsKey('acquired-app') -and $script:State['acquired-app'].package -eq 'com.vulnchecker.acquisitiontest') {$script:State.Remove('acquired-app'); Save-State}}
    }
}
Write-Host "Acquisition smoke completed. Evidence: $folder"
