#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$testRoot=Join-Path $root ('runtime\infra-ui-test-'+[guid]::NewGuid().ToString('N'))
$ctx=Initialize-Context -Root $testRoot -ConfigPath (Join-Path $root 'config.json')
$m=Get-Module Core
$server=[pscustomobject]@{Alias='fixture-linux';Host='192.0.2.1';User='audit';Connection='ssh';Platform='Debian';Port=22;Protocol='https';Timeout=90;Enabled=$true;TrustNewHostKey=$false;KeyFile='';Password='fixture-private-password';BecomePassword='fixture-private-sudo'}
Save-InfrastructureServer $server
$stored=(Get-InfrastructureSettings).Servers[0]
if ((Read-SharedText (Join-Path $ctx.Runtime 'infra-settings.json')).Contains('fixture-private')) {throw 'Plaintext credentials persisted'}
if ((Get-AiPlainKey $stored.Password) -ne 'fixture-private-password') {throw 'DPAPI credential roundtrip failed'}
$server.Password='';$server.BecomePassword='';Save-InfrastructureServer $server
if ((Get-InfrastructureSettings).Servers[0].Password -ne $stored.Password) {throw 'Empty input erased credential'}
$id='20261012T000000Z-12345678';$run=Join-Path $ctx.Runtime ('infra-runs\'+$id)
New-Item -ItemType Directory -Path $run -Force|Out-Null
@{run_id=$id;preflight=$false;ansible_rc=0;hosts=@('fixture-linux','fixture-ok');failed_hosts=@('fixture-linux');vulnerable_hosts=@('fixture-ok');servers=@{
    'fixture-linux'=@{execution_failed=$true;counts=@{GOOD=41;VULNERABLE=20;MANUAL=4;'N/A'=1};errors=@('U-64: exit 1')}
    'fixture-ok'=@{execution_failed=$false;counts=@{GOOD=64};errors=@()}
}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $run 'summary.json') -Encoding UTF8
$global:InfrastructureMock=@{Worker=$null;Action='';Tool='';Target=''}
function global:Start-Worker {
    param($Action,$Tool,$Target)
    $global:InfrastructureMock.Action=$Action;$global:InfrastructureMock.Tool=$Tool;$global:InfrastructureMock.Target=$Target
    $worker=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    $worker.Handle|Out-Null;$global:InfrastructureMock.Worker=$worker;return $worker
}
$form=New-SetupForm
try {
    $form.ShowInTaskbar=$false;$form.Show();[Windows.Forms.Application]::DoEvents()
    $tabs=@($form.Controls|Where-Object {$_ -is [Windows.Forms.TabControl]})[0]
    if ($tabs.TabPages.Count -ne 8 -or $tabs.TabPages[6].Name -ne 'InfrastructureTab') {throw 'Seventh tab missing'}
    $tabs.SelectedIndex=6
    $sub=$tabs.TabPages[6].Controls[0];$settings=$sub.TabPages[0];$results=$sub.TabPages[1]
    $settings.Controls['InfraKind'].SelectedIndex=2
    $settings.Controls['InfraPort'].Value=5985
    if ($settings.Controls['InfraProtocol'].SelectedItem -ne 'HTTP') {throw 'Changing standard Windows port did not update scheme'}
    $settings.Controls['InfraPort'].Value=15985
    $settings.Controls['InfraProtocol'].SelectedIndex=0
    if ($settings.Controls['InfraPort'].Value -ne 15985) {throw 'Changing scheme overwrote custom port'}
    $settings.Controls['InfraPort'].Value=5986
    if ($settings.Controls['InfraProtocol'].SelectedItem -ne 'HTTPS') {throw '5986 did not select HTTPS'}
    $settings.Controls['InfraKind'].SelectedIndex=0
    if ($settings.Controls['InfrastructureServers'].Items.Count -ne 1) {throw 'Server list missing'}
    $settings.Controls['InfraSearch'].Text='missing-server'
    if ($settings.Controls['InfrastructureServers'].Items.Count) {throw 'Server search filter failed'}
    $settings.Controls['InfraSearch'].Clear()
    $bulk=$sub.TabPages[2]; $bulk.Controls['InfraForks'].Value=30; $bulk.Controls['InfraBatchSize'].Value=150
    foreach ($name in @('InfraPassword','InfraBecomePassword')) {if (-not $settings.Controls[$name].UseSystemPasswordChar -or $settings.Controls[$name].Text) {throw 'Credential mask or blank saved input failed'}}
    $settings.Controls['InfraKind'].SelectedIndex=2
    if ($settings.Controls['InfraPort'].Value -ne 5986 -or $settings.Controls['InfraKeyFile'].Enabled) {throw 'Windows kind fields did not adapt'}
    $settings.Controls['InfraProtocol'].SelectedIndex=1
    if ($settings.Controls['InfraPort'].Value -ne 5985) {throw 'HTTP port not adapted'}
    foreach ($tab in $sub.TabPages) {foreach ($control in $tab.Controls) {if ($control.Right -gt $tab.ClientSize.Width -or $control.Bottom -gt $tab.ClientSize.Height) {throw ('Clipped infrastructure control: '+$control.Name)}}}
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $ctx.Runtime 'infrastructure-settings.png'))} finally {$bitmap.Dispose()}
    $sub.SelectedIndex=2
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $ctx.Runtime 'infrastructure-bulk.png'))} finally {$bitmap.Dispose()}
    $sub.SelectedIndex=1
    $grid=$results.Controls['InfrastructureResults']
    $failedRow=@($grid.Rows | Where-Object {$_.Tag.Alias -eq 'fixture-linux'})[0]
    if ($grid.Rows.Count -ne 2 -or $failedRow.Cells['Errors'].Value -notmatch 'U-64') {throw 'Results or failure reason missing'}
    if ($failedRow.Cells['State'].Value -ne '항목 미완전') {throw 'Collected incomplete items incorrectly shown as connection failure'}
    $grid.Rows[0].Cells['Retry'].Value=$true;$grid.Rows[1].Cells['Retry'].Value=$true
    $button=$results.Controls['InfraRetrySelected']
    [Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'NonPublic,Instance').Invoke($button,@([EventArgs]::Empty))|Out-Null
    $request=$global:InfrastructureMock.Target|ConvertFrom-Json
    if ($request.Forks -ne 30 -or $request.BatchSize -ne 150) {throw 'Concurrency settings were not passed to the worker'}
    if ($global:InfrastructureMock.Action -ne 'Infrastructure' -or $global:InfrastructureMock.Tool -ne 'InfraRetry' -or ($request.Hosts -join ',') -ne 'fixture-linux' -or $request.RunId -ne $id) {throw 'Selective failed-host retry dispatch failed'}
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $ctx.Runtime 'infrastructure-results.png'))} finally {$bitmap.Dispose()}
    Write-Host ('PASS tab 7, credentials, inputs, unclipped layout, results and selective retry. Preview: '+$ctx.Runtime)
} finally {
    if ($global:InfrastructureMock.Worker -and -not $global:InfrastructureMock.Worker.HasExited) {Stop-Process -Id $global:InfrastructureMock.Worker.Id -Force}
    $form.Close();$form.Dispose();Remove-Item Function:\Start-Worker
}
