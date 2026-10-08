#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$smokeRoot=Join-Path $root ('runtime\gui-smoke-'+[guid]::NewGuid().ToString('N'))
$ctx=Initialize-Context -Root $smokeRoot -ConfigPath (Join-Path $root 'config.json')
$m=Get-Module Core
& $m {Initialize-InstallationProgress; Set-InstallationProgressStage 'preflight' 'complete'; Set-InstallationProgressStage 'windows-features' 'complete'; Set-InstallationProgressStage 'burp' 'running'; Save-State}
$global:GuiSmokeWorkerState=@{Process=$null}
function global:Start-Worker {
    param($Action,$Tool,$Package,$Target,$SourceSerial,$ApkPaths,$AcceptLicenses,$LaunchWithBypass,$CaptureRoute)
    $command='Start-Sleep -Seconds 60'
    if ($Action -eq 'Stop') {$command='exit 0'}
    $worker=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command',$command) -PassThru
    $worker.Handle | Out-Null
    $global:GuiSmokeWorkerState.Process=$worker
    $global:GuiSmokeWorkerState.Pid=$worker.Id
    $global:GuiSmokeWorkerState.Start=$worker.StartTime
    $global:GuiSmokeWorkerState.Action=$Action
    $global:GuiSmokeWorkerState.AcceptLicenses=$AcceptLicenses
    return $worker
}
$form=New-SetupForm
try {
    $form.ShowInTaskbar=$false
    $form.Opacity=0
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $tabs=@($form.Controls | Where-Object {$_ -is [Windows.Forms.TabControl]})[0]
    $release=Get-Content (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $form.Text.Contains('v'+$release.version) -or -not $form.Controls['AppVersionTitle'].Text.Contains('v'+$release.version)) {throw 'Release version missing'}
    if (($tabs.TabPages.Text -join '|') -ne '① 설치|② 실행 / 연동|③ 연동 결과|④ 앱 가져오기|⑤ APK 보관함|⑥ AI 설정') {throw 'Circled tab numbering missing'}
    if ($form.TopMost) {throw 'Startup left the window permanently topmost'}
    $theme=$form.Controls['ThemeChoice']
    $theme.SelectedIndex=1
    if ($form.BackColor.R -lt 200 -or (Get-Content (Join-Path $ctx.Runtime 'ui-preferences.json') -Raw | ConvertFrom-Json).Theme -ne 'Light') {throw 'Light theme or saved preference failed'}
    $lightPreview=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($lightPreview,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $lightPreview.Save((Join-Path $ctx.Runtime 'gui-light.png'),[Drawing.Imaging.ImageFormat]::Png)} finally {$lightPreview.Dispose()}
    $theme.SelectedIndex=0
    if ($form.BackColor.R -gt 60) {throw 'Dark theme failed'}
    $theme.SelectedIndex=1
    $secondForm=New-SetupForm
    try {if ($secondForm.Controls['ThemeChoice'].SelectedIndex -ne 1) {throw 'Theme preference not restored'}} finally {
        [Windows.Forms.Form].GetMethod('OnFormClosed',[Reflection.BindingFlags]'NonPublic,Instance').Invoke($secondForm,@([Windows.Forms.FormClosedEventArgs]::new([Windows.Forms.CloseReason]::None))) | Out-Null
        $secondForm.Dispose()
    }
    $theme.SelectedIndex=0
    $libraryRoot=Get-ApkLibraryRoot
    $fixture=Join-Path $libraryRoot 'smoke-set'
    $legacy=Join-Path $ctx.Runtime 'acquired-apps\legacy-set'
    foreach ($dir in @($fixture,$legacy)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content (Join-Path $dir '0.apk') 'fixture-base'
        Set-Content (Join-Path $dir '1.apk') 'fixture-split'
        @{Package='com.company.saved';VersionName='1';Acquired='2026-10-07';Items=@(@{},@{})} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'manifest.json') -Encoding UTF8
    }
    if (@(Get-SavedApkSets).Count -ne 2 -or $libraryRoot.StartsWith($ctx.Runtime)) {throw 'Persistent and legacy APK discovery failed'}
    $tabs.SelectedIndex=4
    $library=$tabs.TabPages[4].Controls['SavedApkSets']
    if ($library.Items.Count -ne 2) {throw 'Library UI did not refresh'}
    $reuse=@($tabs.TabPages[4].Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Tag.Action -eq 'ReuseApks'})[0]
    [Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'NonPublic,Instance').Invoke($reuse,@([EventArgs]::Empty)) | Out-Null
    if ($tabs.SelectedIndex -ne 3) {throw "Saved APK reuse did not open acquisition: tab=$($tabs.SelectedIndex), enabled=$($reuse.Enabled), action=$($reuse.Tag.Action), status=$($form.Controls | Where-Object Top -eq 448 | ForEach-Object Text)"}
    $savedPackage=@($tabs.TabPages[3].Controls | Where-Object {$_ -is [Windows.Forms.ComboBox] -and $_.Width -eq 835})[0]
    $selectedApkLabel=@($tabs.TabPages[3].Controls | Where-Object {$_ -is [Windows.Forms.Label] -and $_.Top -eq 85})[0]
    if ($savedPackage.Text -ne 'com.company.saved' -or $selectedApkLabel.Text -notmatch '2개') {throw 'Saved split set selection failed'}
    $groups=@($tabs.TabPages[1].Controls | Where-Object {$_ -is [Windows.Forms.GroupBox]})
    if ($groups.Count -ne 2 -or $groups[0].Text -notmatch '모바일' -or $groups[1].Text -notmatch 'IP / URL') {throw 'Mobile and system categories missing'}
    $mobileButtons=@($groups[0].Controls | Where-Object {$_ -is [Windows.Forms.Button]})
    $systemButtons=@($groups[1].Controls | Where-Object {$_ -is [Windows.Forms.Button]})
    if ($mobileButtons.Count -ne 7 -or $mobileButtons[0].Tag.Action -ne 'OpenAcquisition' -or ($mobileButtons[1..6].Tag.Tool -join ',') -ne 'RefreshAnalysisApps,MobSfAnalysis,MobileApi,MobileAI,RootBypass,StopRootBypass') {throw 'Mobile acquire/select/analyze/pentest workflow missing'}
    if (($systemButtons.Tag.Tool -join ',') -ne 'SystemAnalysis,WebProxyTest,CheckMcp') {throw 'System pentest, Burp and MCP diagnostic workflows missing'}
    foreach ($group in $groups) {
        foreach ($control in $group.Controls) {
            if ($control.Right -gt $group.ClientSize.Width -or $control.Bottom -gt $group.ClientSize.Height) {throw "Control outside analysis group: $($control.Text)"}
        }
    }
    $grid=$tabs.TabPages[2].Controls[0]
    foreach ($row in $grid.Rows) { if ($row.Cells[0].Value -match 'System.Object\[\]') { throw 'Connections rendered as an array instead of individual rows' } }
    $acquireButtons=@($tabs.TabPages[3].Controls | Where-Object {$_ -is [Windows.Forms.Button]})
    if ($acquireButtons.Count -ne 6 -or -not @($acquireButtons | Where-Object {$_.Tag.Tool -eq 'AcquireApp'}).Count) {throw 'Acquisition workflow missing'}
    if (@($tabs.TabPages[1].Controls | Where-Object {$_ -is [Windows.Forms.ComboBox]}).Count) {throw 'Capture route selector should be replaced by purpose-specific buttons'}
    $autoLaunch=@($tabs.TabPages[3].Controls | Where-Object {$_ -is [Windows.Forms.CheckBox]})[0]
    if (-not $autoLaunch.Checked) {throw 'Acquisition instrumentation is not enabled by default'}
    $analysisPackage=@($groups[0].Controls | Where-Object {$_ -is [Windows.Forms.ComboBox]})[0]
    if (-not $analysisPackage -or $analysisPackage.AutoCompleteSource -ne 'ListItems') {throw 'Installed app selection missing'}
    $sourcePackage=@($tabs.TabPages[3].Controls | Where-Object {$_ -is [Windows.Forms.ComboBox] -and $_.Width -eq 835})[0]
    $analysisPackage.Text='com.company.selected'; $sourcePackage.Text='com.company.listed'
    if ($analysisPackage.Text -ne 'com.company.selected') {throw 'Source list overwrote analysis package'}
    $tabs.SelectedTab=$tabs.TabPages[1]
    $mobileButtons[0].PerformClick()
    if ($tabs.SelectedTab -ne $tabs.TabPages[3]) {throw 'App acquisition shortcut does not open original tab'}
    $aiPage=$tabs.TabPages[5]
    if (-not $aiPage.Controls['IbmIcaApiKey'].UseSystemPasswordChar -or -not $aiPage.Controls['DeepSeekApiKey'].UseSystemPasswordChar) {throw 'API key fields must be masked'}
    $tabs.SelectedIndex=5
    $aiPage.Controls['IbmIcaApiKey'].Text='fixture-gui-ibm'
    $aiPage.Controls['DeepSeekApiKey'].Text='fixture-gui-ds'
    $aiPage.Controls['SaveAiSettings'].PerformClick()
    if (-not (Get-AiSettings).IbmKey -or $aiPage.Controls['IbmIcaApiKey'].Text) {throw 'GUI save did not persist and clear keys'}
    $aiPage.Controls['AiModel'].SelectedItem='deepseek/deepseek-flash'
    $aiPage.Controls['SaveAiSettings'].PerformClick()
    if ((Get-AiSettings).Model -ne 'deepseek/deepseek-flash' -or -not (Get-AiSettings).IbmKey) {throw 'GUI model switch lost existing key'}
    foreach ($index in @(0,1,2,3,4,5)) {
      $tabs.SelectedIndex=$index
      [Windows.Forms.Application]::DoEvents()
      $bmp=New-Object Drawing.Bitmap($form.Width,$form.Height)
      try {
        $form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
        $path=Join-Path $ctx.Runtime "gui-preview-$index.png"
        $bmp.Save($path,[Drawing.Imaging.ImageFormat]::Png)
        Write-Host $path
      } finally {$bmp.Dispose()}
    }
    # Exercise the actual WinForms timer and stop button with a harmless worker.
    $tabs.SelectedIndex=1
    $analysisPackage.Text='com.company.selected'
    [Windows.Forms.Application]::DoEvents()
    $progress=@($form.Controls | Where-Object {$_.Name -eq 'InstallationProgress'})[0]
    $progressText=@($form.Controls | Where-Object {$_.Name -eq 'InstallationProgressText'})[0]
    if ($progress.Value -ne 22 -or $progressText.Text -notmatch '2/9 단계 완료' -or $progressText.Text -notmatch 'Burp') {throw 'Persisted installation progress not rendered'}
    # The invisible smoke form can lose focus to Docker's updater. Dispatch the
    # same Click event directly rather than requiring an active native window.
    $clickMethod=[Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'NonPublic,Instance')
    $clickMethod.Invoke($mobileButtons[3],@([EventArgs]::Empty)) | Out-Null
    if (-not $global:GuiSmokeWorkerState.Process) {throw 'GUI launch button did not dispatch the test worker'}
    for ($wait=0; $wait -lt 5 -and $mobileButtons[3].Enabled; $wait++) {Start-Sleep -Milliseconds 1000; [Windows.Forms.Application]::DoEvents()}
    $stop=@($tabs.TabPages[2].Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Tag.Action -eq 'Stop'})[0]
    if ($mobileButtons[3].Enabled -or -not $stop.Enabled) {throw "Busy worker must allow stop while preventing concurrent launch: launch=$($mobileButtons[3].Enabled), stop=$($stop.Enabled)"}
    $clickMethod.Invoke($stop,@([EventArgs]::Empty)) | Out-Null
    for ($wait=0; $wait -lt 10 -and -not $mobileButtons[3].Enabled; $wait++) {Start-Sleep -Milliseconds 1000; [Windows.Forms.Application]::DoEvents()}
    if (-not $mobileButtons[3].Enabled -or -not $systemButtons[0].Enabled) {throw 'Stop completion did not restore launch buttons'}
    $statusLabel=@($form.Controls | Where-Object {$_ -is [Windows.Forms.Label] -and $_.Top -eq 448})[0]
    if ($statusLabel.Text -notmatch '작업 완료') {throw "Worker completion status not reset: $($statusLabel.Text)"}
    Write-Host 'PASS GUI worker cancellation and button recovery'
    $install=@($tabs.TabPages[0].Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Tag.Action -eq 'Install'})[0]
    $check=@($tabs.TabPages[0].Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Tag.Action -eq 'Preflight'})[0]
    $terms=@($tabs.TabPages[0].Controls | Where-Object {$_ -is [Windows.Forms.CheckBox]})[0]
    if ($form.AcceptButton -ne $install -or $install.Left -ge $check.Left -or $install.Text -notmatch '자동 설치') {throw 'Default setup action is not automatic installation'}
    $tabs.SelectedIndex=0; $terms.Checked=$true
    $clickMethod.Invoke($install,@([EventArgs]::Empty)) | Out-Null
    if ($global:GuiSmokeWorkerState.Action -ne 'Install' -or -not $global:GuiSmokeWorkerState.AcceptLicenses -or $tabs.SelectedIndex -ne 2) {throw 'Installation did not dispatch with accepted terms and show progress'}
    & $m {Initialize-InstallationProgress; foreach ($id in @('preflight','windows-features','burp','android-java')) {Set-InstallationProgressStage $id 'complete'}; Set-InstallationProgressStage 'docker-desktop' 'running'; Save-State}
    for ($wait=0; $wait -lt 5 -and $install.Enabled; $wait++) {Start-Sleep -Milliseconds 1000; [Windows.Forms.Application]::DoEvents()}
    if ($progress.Value -ne 44 -or $progressText.Text -notmatch 'Docker Desktop' -or $progress.Style -ne 'Continuous') {throw 'Live installation progress not updated'}
    $bmp=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $bmp.Save((Join-Path $ctx.Runtime 'gui-progress.png'),[Drawing.Imaging.ImageFormat]::Png)} finally {$bmp.Dispose()}
    $clickMethod.Invoke($stop,@([EventArgs]::Empty)) | Out-Null
    for ($wait=0; $wait -lt 10 -and -not $install.Enabled; $wait++) {Start-Sleep -Milliseconds 1000; [Windows.Forms.Application]::DoEvents()}
    if (-not $install.Enabled) {throw 'Installation cancellation left setup button disabled'}
    Write-Host 'PASS GUI automatic installation dispatch and progress'
} finally {
    if ($global:GuiSmokeWorkerState.ContainsKey('Pid')) {
        $remaining=Get-Process -Id $global:GuiSmokeWorkerState.Pid -ErrorAction SilentlyContinue
        if ($remaining -and $remaining.StartTime -eq $global:GuiSmokeWorkerState.Start) {$remaining.Kill()}
    }
    Remove-Variable GuiSmokeWorkerState -Scope Global
    $form.Close();$form.Dispose()
}
