#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$ctx=Initialize-Context -Root (Join-Path $root ('runtime\profile-ui-'+[guid]::NewGuid().ToString('N'))) -ConfigPath (Join-Path $root 'config.json')
$server=[pscustomobject]@{Alias='fixture';Host='192.0.2.1';User='audit';Connection='ssh';Platform='Auto';Port=22;Protocol='https';Timeout=90;Enabled=$true;TrustNewHostKey=$false;KeyFile='';Password='fixture-password';BecomePassword=''}
Save-InfrastructureServer $server
$rows=@()
foreach($entry in @(@('os','unix-debian',''),@('was-prod','tomcat','/opt/was-prod'),@('db-prod','mysql',''))){$rows+=,[pscustomobject]@{Id=$entry[0];Profile=$entry[1];Root=$entry[2];RunAs='';Bash='/bin/bash';Python='/usr/bin/python3';DbHost='localhost';DbPort=3307;DbName='prod';DbUser='audit';DbPassword=$(if($entry[1] -eq 'mysql'){'fixture-db-secret'}else{''})}}
Save-InfrastructureServerProfiles 'fixture' $rows
$saved=(Get-InfrastructureSettings).Servers[0]
if($saved.Platform -ne 'Debian' -or @($saved.Profiles).Count -ne 3){throw 'Profile save or OS selection failed'}
if((Get-AiPlainKey $saved.Profiles[2].DbPassword) -ne 'fixture-db-secret'){throw 'DB credential DPAPI failed'}
if((Read-SharedText (Join-Path $ctx.Runtime 'infra-settings.json')).Contains('fixture-db-secret')){throw 'Plain DB credential stored'}
$rows[2].DbPassword='';Save-InfrastructureServerProfiles 'fixture' $rows
if((Get-InfrastructureSettings).Servers[0].Profiles[2].DbPassword -ne $saved.Profiles[2].DbPassword){throw 'Blank DB input erased stored credential'}
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$owner=New-Object Windows.Forms.Form;$owner.ShowInTaskbar=$false;$owner.Show()
$global:ProfileScreenshot=Join-Path $ctx.Runtime 'profile-editor.png'
$timer=New-Object Windows.Forms.Timer;$timer.Interval=250
$timer.Add_Tick({$active=[Windows.Forms.Form]::ActiveForm;if($active -and $active.Name -eq 'InfraProfileEditor'){$bitmap=New-Object Drawing.Bitmap($active.Width,$active.Height);$active.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$active.Width,$active.Height)));$bitmap.Save($global:ProfileScreenshot);$bitmap.Dispose();$active.Close()}})
$timer.Start()
try{[void](Show-InfrastructureProfileEditor -Owner $owner -Server $saved)}finally{$timer.Stop();$timer.Dispose();$owner.Close();$owner.Dispose()}
if(-not(Test-Path -LiteralPath $global:ProfileScreenshot)){throw 'Profile selection dialog did not render'}
Write-Output ('PASS profiles, automatic OS mapping, instance IDs, encrypted DB credential reuse and modal editor. Preview: '+$global:ProfileScreenshot)
