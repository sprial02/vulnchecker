#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$fixture=Join-Path $root ('runtime\reports-gui-'+[guid]::NewGuid().ToString('N'))
$ctx=Initialize-Context -Root $fixture -ConfigPath (Join-Path $root 'config.json')
$rows=@(@{id='infra-QA';kind='infra';name='QA 인프라';assets=1200;failed_assets=0;total_checks=2400;counts=@{GOOD=2400}},@{id='web-QA';kind='web';name='QA 웹';assets=1;failed_assets=0;total_checks=1;counts=@{VULNERABLE=1}})
Write-AtomicText -Path (Join-Path $ctx.Runtime 'report-catalog.json') -Text (ConvertTo-Json -InputObject $rows -Depth 5)
Write-AtomicText -Path (Join-Path $ctx.Runtime 'report-preview.json') -Text (@{source_id='infra-QA';offset=0;rows=@(@{asset='server-QA';item_id='U-01';title='QA 항목';status='GOOD';severity='Unknown'})}|ConvertTo-Json -Depth 5)
$global:ReportGuiMock=@{}
function global:Start-Worker {
    param($Action,$Tool,$Target)
    $global:ReportGuiMock.Action=$Action;$global:ReportGuiMock.Tool=$Tool;$global:ReportGuiMock.Target=$Target
    $worker=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    $worker.Handle|Out-Null;$global:ReportGuiMock.Worker=$worker;return $worker
}
$form=New-SetupForm
try {
    $form.ShowInTaskbar=$false;$form.Opacity=0;$form.Show()
    $tabs=@($form.Controls|Where-Object {$_ -is [Windows.Forms.TabControl]})[0];$tabs.SelectedIndex=7
    $until=(Get-Date).AddSeconds(3);while ((Get-Date) -lt $until) {[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 30}
    $page=$tabs.TabPages[7]
    if ($page.Name -ne 'ReportsTab' -or $page.Controls['ReportSource'].Items.Count -ne 1) {throw 'Report tab source filtering failed'}
    if ($page.Controls['ReportResults'].Rows.Count -ne 1) {throw 'Preview did not load'}
    if ($page.Controls['ReportSummary'].Text -notmatch '2400') {throw 'Statistics with absent MANUAL/VULNERABLE failed'}
    foreach ($control in $page.Controls) {if ($control.Right -gt $page.ClientSize.Width -or $control.Bottom -gt $page.ClientSize.Height) {throw ('Clipped report control '+$control.Name)}}
    $title=$form.Controls['AppVersionTitle'];$subtitle=$form.Controls['AppScopeSubtitle']
    if ($title.Text -ne 'IBM TriGuard AI' -or $subtitle.Text -notmatch 'Korea Delivery') {throw 'Branding missing'}
    $textSize=[Windows.Forms.TextRenderer]::MeasureText($subtitle.Text,$subtitle.Font)
    if ($textSize.Width -gt $subtitle.Width) {throw 'Full subtitle does not fit'}
    $page.Controls['ReportCustomer'].Text='QA 고객사';$page.Controls['ReportAuthor'].Text='QA 담당';$page.Controls['ReportPeriod'].Text='QA 기간';$page.Controls['ReportScope'].Text='QA 범위'
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $ctx.Runtime 'reports-tab.png'))} finally {$bitmap.Dispose()}
    $button=$page.Controls['ReportExport'];[Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'NonPublic,Instance').Invoke($button,@([EventArgs]::Empty))|Out-Null
    $request=$global:ReportGuiMock.Target|ConvertFrom-Json
    if ($global:ReportGuiMock.Action -ne 'Report' -or $global:ReportGuiMock.Tool -ne 'ReportExport' -or $request.Customer -ne 'QA 고객사' -or $request.SourceId -ne 'infra-QA' -or $request.DetailLimit -ne 30) {throw 'Report worker dispatch failed'}
    Stop-Process -Id $global:ReportGuiMock.Worker.Id -Force;$global:ReportGuiMock.Worker.WaitForExit()
    $button=$page.Controls['ReportRawExport'];[Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'NonPublic,Instance').Invoke($button,@([EventArgs]::Empty))|Out-Null
    $request=$global:ReportGuiMock.Target|ConvertFrom-Json
    if ($global:ReportGuiMock.Tool -ne 'ReportRawExport' -or $request.SourceId -ne 'infra-QA') {throw 'RAW selected source dispatch failed'}
    Write-Host ('PASS report tab, filtering, paging preview, statistics, customer export and branding. '+(Join-Path $ctx.Runtime 'reports-tab.png'))
} finally {
    if ($global:ReportGuiMock.Worker -and -not $global:ReportGuiMock.Worker.HasExited) {Stop-Process -Id $global:ReportGuiMock.Worker.Id -Force}
    $form.Close();$form.Dispose();Remove-Item Function:\Start-Worker
}
