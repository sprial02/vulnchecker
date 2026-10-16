function Show-Guide {
    $path=Join-Path $script:Root 'docs\GUIDE.ko.html'
    if (Test-Path -LiteralPath $path) { Start-Process -FilePath $path | Out-Null }
    Write-Log "사용 가이드: $path"
}

function Get-WorkerCompletionMessage {
    param([string]$Action,$ExitCode,[string]$ConnectionsPath,[DateTime]$Started)
    if ($Action -eq 'Report' -and $ExitCode -eq 0) {return '보고서 작업 완료 · ⑧ 레포트에서 결과 선택 또는 보고서 폴더를 여세요.'}
    if ($Action -eq 'Infrastructure') {
        if ($ExitCode -eq 3010) {return '재부팅 필요 · Windows 재부팅 → Start.cmd → ⑦ Ansible 설치 / 확인으로 이어하기'}
        if ($ExitCode -eq 0) {return '인프라 작업 완료 · ⑦ 점검 결과 / 재실행 → 점검 결과 TXT 열기 · 저장 위치: 프로그램 폴더\점검결과'}
        return '인프라 작업에 실패 항목이 있습니다 · ⑦에서 실행 상태 확인 · 수집된 스크립트 결과는 점검 결과 TXT 열기'
    }
    if ($ExitCode -eq 3010) {
        if ($Action -eq 'Launch') {return '재부팅 필요 · Windows 재부팅 → Start.cmd → 같은 실행 버튼으로 설치 / 실행 이어가기'}
        return '재부팅 필요 · Windows 재부팅 → Start.cmd → 같은 계정으로 자동 설치 / 이어하기'
    }
    if ($Action -eq 'Preflight') {
        if ($ExitCode -eq 0) {return '사전 확인 완료 · 미탐지 / 미확인은 설치 전 상태입니다. 약관 확인 후 자동 설치 / 이어하기를 누르세요.'}
        return '사전 확인 중 제한 조건 발견 · 아래 로그의 사유를 확인하세요. 이 버튼은 프로그램을 설치하지 않습니다.'
    }
    if ($Action -eq 'Verify' -and $ExitCode -ne 0) {return '설치가 필요한 항목이 있습니다 · 설치 탭에서 약관 확인 후 자동 설치 / 이어하기를 누르세요.'}
    if ($ExitCode -eq 0) {
        if ($Action -eq 'Install') {return '설치 완료 · 실행 / 연동 탭에서 분석 도구를 선택하세요.'}
        return '작업 완료 · 연동 결과를 확인하고 열린 도구에서 분석을 시작하세요.'
    }
    try {
        $rows=Read-SharedText $ConnectionsPath | ConvertFrom-Json
        $failure=@($rows | Where-Object {$_.Status -eq '실패' -and [DateTimeOffset]::Parse($_.Updated).LocalDateTime -ge $Started} | Sort-Object Updated | Select-Object -First 1)
        if ($failure.Count) {
            $detail=([string]$failure[0].Detail -replace '[\r\n]+',' ')
            if ($detail.Length -gt 80) {$detail=$detail.Substring(0,80)+'…'}
            return "실패: $($failure[0].Name) · $detail"
        }
    } catch {}
    return '작업 실패 · 아래 로그의 ERROR / FAILED 원인을 확인하세요. 자동 설치 / 이어하기로 다시 시도할 수 있습니다.'
}

function Get-InstallationProgressView {
    param($Progress)
    $steps=@($Progress.Steps); $total=$steps.Count
    $completed=@($steps | Where-Object {$_.Status -eq 'complete'}).Count
    $percent=0; if ($total) {$percent=[int][Math]::Floor(100*$completed/$total)}
    $current=@($steps | Where-Object {$_.Id -eq $Progress.Current} | Select-Object -First 1)
    $name='설치 준비'; if ($current.Count) {$name=$current[0].Name}
    $detail=$Progress.Status
    if ($Progress.Status -eq '진행 중') {$detail="$name 확인 / 다운로드 / 설치 중"}
    return [pscustomobject]@{Percent=$percent;Completed=$completed;Total=$total;Text="설치 $percent% · $completed/$total 단계 완료 · $detail"}
}

function Set-SetupTheme {
    param($Control,[ValidateSet('Dark','Light')][string]$Theme)
    $dark=$Theme -eq 'Dark'
    $background=[Drawing.Color]::FromArgb(245,247,250); $foreground=[Drawing.Color]::FromArgb(30,39,52)
    $surface=[Drawing.Color]::White; $buttonColor=[Drawing.Color]::FromArgb(220,228,239)
    if ($dark) {
        $background=[Drawing.Color]::FromArgb(22,27,38); $foreground=[Drawing.Color]::FromArgb(230,235,244)
        $surface=[Drawing.Color]::FromArgb(13,17,25); $buttonColor=[Drawing.Color]::FromArgb(42,54,75)
    }
    $Control.BackColor=$background; $Control.ForeColor=$foreground
    if ($Control -is [Windows.Forms.TextBoxBase] -or $Control -is [Windows.Forms.ComboBox] -or $Control -is [Windows.Forms.ListBox]) {$Control.BackColor=$surface}
    if ($Control -is [Windows.Forms.Button]) {
        $Control.BackColor=$buttonColor
        if ($Control.Tag -and $Control.Tag.Action -eq 'Install') {$Control.BackColor=[Drawing.Color]::FromArgb(26,109,90); $Control.ForeColor=[Drawing.Color]::White}
    }
    if ($Control -is [Windows.Forms.DataGridView]) {
        $Control.EnableHeadersVisualStyles=$false; $Control.BackgroundColor=$background
        foreach ($style in @($Control.DefaultCellStyle,$Control.ColumnHeadersDefaultCellStyle,$Control.RowHeadersDefaultCellStyle)) {
            $style.BackColor=$surface; $style.ForeColor=$foreground
            $style.SelectionBackColor=[Drawing.Color]::FromArgb(45,100,160); $style.SelectionForeColor=[Drawing.Color]::White
        }
        $Control.GridColor=$buttonColor
    }
    foreach ($child in $Control.Controls) {Set-SetupTheme $child $Theme}
}

function Get-ConnectionMapView {
    param([object[]]$Rows=@())
    $groups=@(
        @{Name='모바일'; DisplayName='모바일'; Pattern='Android|Frida server|모바일.*연결|모바일 API 분석|루팅 우회 세션|분석 앱 실행|^실행: (Emulator|MobileAI|MobileApi|RootBypass)$|^앱 확보:'},
        @{Name='HexStrike'; DisplayName='시스템'; Pattern='^HexStrike HTTP$|HexStrike MCP|^실행: (HexStrike|CheckMcp|SystemAnalysis)$'},
        @{Name='웹 / Burp'; DisplayName='웹 / Burp'; Pattern='^Burp Proxy$|^자동 웹 점검 → Burp$|^실행: (Burp|WebProxyTest)$'},
        @{Name='인프라'; DisplayName='인프라'; Pattern='^인프라 점검$|^인프라 서버 연결$|^실행 준비: Infra'}
    )
    foreach ($group in $groups) {
        $matches=@($Rows | Where-Object {$_.Name -match $group.Pattern} | Sort-Object Updated -Descending)
        $state='Unknown'; $label='미확인'
        # An unresolved failed check must not be hidden by a successful sibling check.
        foreach ($rule in @(
            @{State='Failed'; Label='실패'; Values=@('실패','미완료')},
            @{State='Pending'; Label='확인 중'; Values=@('진행 중','준비 중','대기')},
            @{State='Stopped'; Label='연결 종료'; Values=@('중지됨','종료됨','전환됨')},
            @{State='Connected'; Label='연결됨'; Values=@('연결됨')}
        )) {
            $found=@($matches | Where-Object {$_.Status -in $rule.Values} | Select-Object -First 1)
            if ($found.Count) {$state=$rule.State; $label=$rule.Label; break}
        }
        $detail='실행 후 실제 연결 검사 결과를 표시합니다.'
        if ($matches.Count) {$detail=($matches | ForEach-Object {"$($_.Name): $($_.Status) · $($_.Detail) [$($_.Updated)]"}) -join "`r`n"}
        [pscustomobject]@{Name=$group.Name; DisplayName=$group.DisplayName; State=$state; Label=$label; Detail=$detail}
    }
}

function New-ConnectionMap {
    $panel=New-Object Windows.Forms.Panel
    $panel.Name='ConnectionMap'; $panel.SetBounds(650,65,380,80); $panel.Anchor='Top,Right'
    $panel.Tag=@{Views=@(Get-ConnectionMapView)}
    $panel.AccessibleName='컴퓨터와 모바일, 시스템, 웹, 인프라의 실제 실행 연결 결과'
    $panel.Cursor=[Windows.Forms.Cursors]::Hand
    $panel.Add_Paint({
        param($sender,$eventArgs)
        $g=$eventArgs.Graphics; $g.SmoothingMode='AntiAlias'
        $ink=New-Object Drawing.SolidBrush($sender.ForeColor)
        $iconPen=New-Object Drawing.Pen($sender.ForeColor,1.6)
        $font=New-Object Drawing.Font('맑은 고딕',9)
        try {
            # Four independent lines from the local computer to each workflow.
            $g.DrawRectangle($iconPen,8,25,32,23); $g.DrawLine($iconPen,24,48,24,54); $g.DrawLine($iconPen,15,54,33,54)
            $g.DrawString('컴퓨터',$font,$ink,0,56)
            for ($i=0; $i -lt 4; $i++) {
                $view=$sender.Tag.Views[$i]; $y=10+20*$i
                $color=[Drawing.Color]::FromArgb(133,145,163)
                if ($view.State -eq 'Connected') {$color=[Drawing.Color]::FromArgb(37,175,119)}
                elseif ($view.State -eq 'Failed') {$color=[Drawing.Color]::FromArgb(231,78,91)}
                elseif ($view.State -eq 'Pending') {$color=[Drawing.Color]::FromArgb(211,158,37)}
                $pen=New-Object Drawing.Pen($color,2)
                $brush=New-Object Drawing.SolidBrush($color)
                try {
                    if ($view.State -ne 'Connected') {$pen.DashStyle='Dash'}
                    if ($view.State -eq 'Failed') {
                        $middle=([single]($y+37)/2)
                        $g.DrawLine($pen,48,37,78,($middle-($y-37)*0.06))
                        $g.DrawLine($pen,102,($middle+($y-37)*0.06),134,$y)
                        $g.DrawString('×',$font,$brush,82,($middle-10))
                    } else {$g.DrawLine($pen,48,37,134,$y)}
                    $pen.DashStyle='Solid'
                    if ($i -eq 0) {
                        $g.DrawRectangle($pen,144,($y-8),10,16); $g.DrawLine($pen,147,($y+5),151,($y+5))
                    } elseif ($i -eq 1) {
                        $points=[Drawing.Point[]]@([Drawing.Point]::new(149,$y-8),[Drawing.Point]::new(157,$y-4),[Drawing.Point]::new(157,$y+4),[Drawing.Point]::new(149,$y+8),[Drawing.Point]::new(141,$y+4),[Drawing.Point]::new(141,$y-4))
                        $g.DrawPolygon($pen,$points)
                    } elseif ($i -eq 2) {
                        $g.DrawEllipse($pen,141,($y-8),16,16); $g.DrawEllipse($pen,146,($y-8),6,16); $g.DrawLine($pen,141,$y,157,$y)
                    } else {
                        # Two server units form the infrastructure rack icon.
                        foreach ($offset in @(-8,1)) {
                            $g.DrawRectangle($pen,141,($y+$offset),17,7)
                            $g.FillEllipse($brush,144,($y+$offset+2),3,3)
                            $g.DrawLine($pen,150,($y+$offset+3),155,($y+$offset+3))
                        }
                    }
                    $g.DrawString($view.DisplayName,$font,$ink,170,($y-9))
                    $g.FillEllipse($brush,276,($y-3),6,6)
                    $g.DrawString($view.Label,$font,$brush,289,($y-9))
                } finally {$pen.Dispose(); $brush.Dispose()}
            }
        } finally {$ink.Dispose(); $iconPen.Dispose(); $font.Dispose()}
    }.GetNewClosure())
    return $panel
}

function New-SetupForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form
    $form.Text="IBM TriGuard AI | v$($script:AppRelease.version)"
    $form.Size=New-Object Drawing.Size(1080,780)
    $form.MinimumSize=New-Object Drawing.Size(1080,780)
    $form.StartPosition='CenterScreen'
    $form.BackColor=[Drawing.Color]::FromArgb(22,27,38)
    $form.ForeColor=[Drawing.Color]::FromArgb(230,235,244)
    $form.Font=New-Object Drawing.Font('맑은 고딕',10)
    $title=New-Object Windows.Forms.Label
    $title.Name='AppVersionTitle'; $title.Text='IBM TriGuard AI'
    $title.Font=New-Object Drawing.Font('맑은 고딕',24,[Drawing.FontStyle]::Bold)
    $title.SetBounds(26,14,730,50)
    $form.Controls.Add($title)
    $themeLabel=New-Object Windows.Forms.Label; $themeLabel.Name='ThemeLabel'; $themeLabel.Text='화면 테마'; $themeLabel.SetBounds(780,33,90,28); $form.Controls.Add($themeLabel)
    $themeChoice=New-Object Windows.Forms.ComboBox; $themeChoice.Name='ThemeChoice'; $themeChoice.DropDownStyle='DropDownList'; $themeChoice.SetBounds(874,30,156,30)
    [void]$themeChoice.Items.AddRange(@('다크','밝게')); $form.Controls.Add($themeChoice)
    $preferencesPath=Join-Path $script:Runtime 'ui-preferences.json'
    $themeChoice.SelectedIndex=1
    try {if ((Get-Content -LiteralPath $preferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json).Theme -eq 'Dark') {$themeChoice.SelectedIndex=0}} catch {}
    $sub=New-Object Windows.Forms.Label
    $sub.Name='AppScopeSubtitle'; $sub.Text='Integrated Automated Vulnerability Assessment & Reporting Suite (Korea Delivery)'
    $sub.UseMnemonic=$false
    $sub.SetBounds(30,67,590,24)
    $sub.Font=New-Object Drawing.Font('Segoe UI',9)
    $form.Controls.Add($sub)
    $releaseInfo=New-Object Windows.Forms.Label; $releaseInfo.Name='AppReleaseInfo'
    $releaseInfo.Text="v$($script:AppRelease.version) · Windows 11 x64 · 프로필: $($script:Config.profile) · 빌드: $($script:AppRelease.buildDate)"
    $releaseInfo.Font=New-Object Drawing.Font('맑은 고딕',8); $releaseInfo.SetBounds(30,94,590,20); $form.Controls.Add($releaseInfo)
    $info=New-Object Windows.Forms.Label
    $info.Text='실행 결과 · 녹색: 연결 / 빨강: 실패 / 노랑: 확인 중 / 회색: 미확인·종료'
    $info.Font=New-Object Drawing.Font('맑은 고딕',8)
    $info.SetBounds(30,118,610,22)
    $form.Controls.Add($info)
    $connectionMap=New-ConnectionMap; $form.Controls.Add($connectionMap)
    $connectionTip=New-Object Windows.Forms.ToolTip
    $connectionTip.AutoPopDelay=20000
    $connectionTip.SetToolTip($connectionMap,'실제 실행의 마지막 연결 검사 결과입니다. 클릭하면 연동 결과를 엽니다.')
    $terms=New-Object Windows.Forms.CheckBox
    $terms.Text='고객사 설치 허용 및 소프트웨어 약관을 확인했습니다. 아래 자동 설치 버튼으로 없는 도구를 다운로드·설치합니다.'
    $terms.SetBounds(14,18,960,30)
    $status=New-Object Windows.Forms.Label
    $status.Text='대기 중 · 자동 설치 / 이어하기를 눌러 환경을 준비하세요.'
    $status.SetBounds(30,448,1000,30)
    $form.Controls.Add($status)
    $log=New-Object Windows.Forms.TextBox
    $log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'
    $log.BackColor=[Drawing.Color]::FromArgb(13,17,25)
    $log.ForeColor=[Drawing.Color]::FromArgb(173,219,199)
    $log.Font=New-Object Drawing.Font('Consolas',10)
    $log.SetBounds(30,526,1000,164)
    $log.Anchor='Top,Bottom,Left,Right'
    $form.Controls.Add($log)
    $progressBar=New-Object Windows.Forms.ProgressBar
    $progressBar.Name='InstallationProgress'; $progressBar.SetBounds(30,485,380,20)
    $progressBar.Minimum=0; $progressBar.Maximum=100; $progressBar.MarqueeAnimationSpeed=30
    $form.Controls.Add($progressBar)
    $progressLabel=New-Object Windows.Forms.Label
    $progressLabel.Name='InstallationProgressText'; $progressLabel.Text='설치 진행률 · 대기 중'
    $progressLabel.SetBounds(424,480,606,38); $progressLabel.AutoEllipsis=$true
    $form.Controls.Add($progressLabel)
    $note=New-Object Windows.Forms.Label
    $note.Text='분석 기기: 루팅 가능 · 다운로드 기기: Google Play 포함 · Google 로그인은 다운로드 기기에서 직접 진행합니다.'
    $note.SetBounds(30,699,1000,26)
    $note.Anchor='Bottom,Left,Right'
    $form.Controls.Add($note)
    $buttons=New-Object 'System.Collections.Generic.List[object]'
    $tabs=New-Object Windows.Forms.TabControl
    $tabs.SetBounds(30,145,1000,294)
    $tabs.Anchor='Top,Left,Right'
    $form.Controls.Add($tabs)
    $installTab=New-Object Windows.Forms.TabPage; $installTab.Text='① 설치'
    $runTab=New-Object Windows.Forms.TabPage; $runTab.Text='② 실행 / 연동'
    $resultTab=New-Object Windows.Forms.TabPage; $resultTab.Text='③ 연동 결과'
    $connectionMap.Add_Click({$tabs.SelectedTab=$resultTab}.GetNewClosure())
    $acquireTab=New-Object Windows.Forms.TabPage; $acquireTab.Text='④ 앱 가져오기'
    foreach ($page in @($installTab,$runTab,$resultTab,$acquireTab)) { $page.BackColor=$form.BackColor; $page.ForeColor=$form.ForeColor; $tabs.TabPages.Add($page) }
    $libraryTab=New-Object Windows.Forms.TabPage; $libraryTab.Text='⑤ APK 보관함'; $tabs.TabPages.Add($libraryTab)
    $aiTab=New-Object Windows.Forms.TabPage; $aiTab.Text='⑥ AI 설정'; $tabs.TabPages.Add($aiTab)
    $aiSaved=Get-AiSettings
    $aiIntro=New-Object Windows.Forms.Label; $aiIntro.Text='IBM ICA · https://api.nextgen-beta.ica.ibm.com/ica/v1'; $aiIntro.SetBounds(14,12,950,25); $aiTab.Controls.Add($aiIntro)
    $ibmLabel=New-Object Windows.Forms.Label; $ibmLabel.Text='IBM ICA API KEY'; $ibmLabel.SetBounds(14,48,195,26); $aiTab.Controls.Add($ibmLabel)
    $ibmKeyInput=New-Object Windows.Forms.TextBox; $ibmKeyInput.Name='IbmIcaApiKey'; $ibmKeyInput.UseSystemPasswordChar=$true; $ibmKeyInput.SetBounds(214,45,530,28); $aiTab.Controls.Add($ibmKeyInput)
    $removeIbm=New-Object Windows.Forms.CheckBox; $removeIbm.Text='저장 키 삭제'; $removeIbm.SetBounds(766,46,180,26); $aiTab.Controls.Add($removeIbm)
    $dsLabel=New-Object Windows.Forms.Label; $dsLabel.Text='DEEPSEEK API KEY'; $dsLabel.SetBounds(14,86,195,26); $aiTab.Controls.Add($dsLabel)
    $dsKeyInput=New-Object Windows.Forms.TextBox; $dsKeyInput.Name='DeepSeekApiKey'; $dsKeyInput.UseSystemPasswordChar=$true; $dsKeyInput.SetBounds(214,83,530,28); $aiTab.Controls.Add($dsKeyInput)
    $removeDs=New-Object Windows.Forms.CheckBox; $removeDs.Text='저장 키 삭제'; $removeDs.SetBounds(766,84,180,26); $aiTab.Controls.Add($removeDs)
    $aiModelLabel=New-Object Windows.Forms.Label; $aiModelLabel.Text='시작 모델 (기본 IBM ICA)'; $aiModelLabel.SetBounds(14,124,195,26); $aiTab.Controls.Add($aiModelLabel)
    $aiModel=New-Object Windows.Forms.ComboBox; $aiModel.Name='AiModel'; $aiModel.DropDownStyle='DropDownList'; $aiModel.SetBounds(214,121,530,28); [void]$aiModel.Items.AddRange([object[]](Get-AiModelIds)); $aiModel.SelectedItem=$aiSaved.Model; $aiTab.Controls.Add($aiModel)
    $aiState=New-Object Windows.Forms.Label; $aiState.Name='AiKeyStatus'; $aiState.SetBounds(14,158,950,25); $aiTab.Controls.Add($aiState)
    $refreshAiStatus={
        $saved=Get-AiSettings
        $ibm='미입력'; if ($saved.IbmKey) {$ibm='저장됨'}
        $ds='미입력 (선택)'; if ($saved.DeepSeekKey) {$ds='저장됨'}
        $aiState.Text="IBM ICA: $ibm / DeepSeek: $ds · 빈 입력란은 기존 키 유지"
    }.GetNewClosure()
    & $refreshAiStatus
    $aiSave=New-Object Windows.Forms.Button; $aiSave.Name='SaveAiSettings'; $aiSave.Text='API 키 / 모델 저장'; $aiSave.SetBounds(14,190,260,36); $aiTab.Controls.Add($aiSave)
    $aiSave.Add_Click({
        try {
            Save-AiSettings -Model $aiModel.SelectedItem -IbmKey $ibmKeyInput.Text -DeepSeekKey $dsKeyInput.Text -RemoveIbm:$removeIbm.Checked -RemoveDeepSeek:$removeDs.Checked
            $ibmKeyInput.Clear(); $dsKeyInput.Clear(); $removeIbm.Checked=$false; $removeDs.Checked=$false
            & $refreshAiStatus
            $status.Text='AI 설정 저장 완료 · 다음 펜테스트 실행에 적용됩니다. 열린 OpenCode는 종료 후 실행 버튼으로 다시 여세요.'
        } catch {[Windows.Forms.MessageBox]::Show($_.Exception.Message,'AI 설정') | Out-Null}
    }.GetNewClosure())
    $aiHint=New-Object Windows.Forms.Label; $aiHint.Text='토큰 소진 시 OpenCode /models → DeepSeek 선택 (수동 전환). 키는 Windows 계정 암호화로 저장됩니다.'; $aiHint.SetBounds(14,236,950,27); $aiTab.Controls.Add($aiHint)
    $libraryPathLabel=New-Object Windows.Forms.Label; $libraryPathLabel.Name='ApkLibraryPath'; $libraryPathLabel.Text=('저장 위치: '+(Get-ApkLibraryRoot)); $libraryPathLabel.SetBounds(14,10,950,28); $libraryPathLabel.AutoEllipsis=$true; $libraryTab.Controls.Add($libraryPathLabel)
    $libraryList=New-Object Windows.Forms.ListBox; $libraryList.Name='SavedApkSets'; $libraryList.SetBounds(14,42,950,144); $libraryList.DisplayMember='Label'; $libraryList.HorizontalScrollbar=$true; $libraryTab.Controls.Add($libraryList)
    $refreshLibrary={
        $libraryList.Items.Clear()
        foreach ($entry in @(Get-SavedApkSets)) {[void]$libraryList.Items.Add($entry)}
        if ($libraryList.Items.Count) {$libraryList.SelectedIndex=0}
    }.GetNewClosure()
    $libraryHint=New-Object Windows.Forms.Label; $libraryHint.Text='base와 split APK를 한 세트로 보관합니다. 선택한 앱을 다시 가져와 분석 기기에 설치할 수 있습니다.'; $libraryHint.SetBounds(14,240,950,25); $libraryTab.Controls.Add($libraryHint)
    $tabs.Add_SelectedIndexChanged({if ($tabs.SelectedTab -eq $libraryTab) {& $refreshLibrary}}.GetNewClosure())
    $sourceLabel=New-Object Windows.Forms.Label; $sourceLabel.Text='앱 출처'; $sourceLabel.SetBounds(14,12,90,24); $acquireTab.Controls.Add($sourceLabel)
    $sourceChoice=New-Object Windows.Forms.ComboBox; $sourceChoice.DropDownStyle='DropDownList'; $sourceChoice.SetBounds(105,10,220,28)
    [void]$sourceChoice.Items.AddRange(@('Google Play 다운로드 기기','연결된 실제 단말','고객 제공 APK 파일')); $sourceChoice.SelectedIndex=0; $acquireTab.Controls.Add($sourceChoice)
    $serialLabel=New-Object Windows.Forms.Label; $serialLabel.Text='기기 식별자'; $serialLabel.SetBounds(340,12,105,24); $acquireTab.Controls.Add($serialLabel)
    $serialInput=New-Object Windows.Forms.ComboBox; $serialInput.Text='emulator-5560'; $serialInput.Enabled=$false; $serialInput.SetBounds(450,10,490,28); $acquireTab.Controls.Add($serialInput)
    $packageLabel=New-Object Windows.Forms.Label; $packageLabel.Text='앱 패키지'; $packageLabel.SetBounds(14,49,90,24); $acquireTab.Controls.Add($packageLabel)
    $packageInput=New-Object Windows.Forms.ComboBox; $packageInput.SetBounds(105,46,835,28); $acquireTab.Controls.Add($packageInput)
    $apkLabel=New-Object Windows.Forms.Label; $apkLabel.Text='선택한 APK: 없음 (split 파일은 함께 선택)'; $apkLabel.SetBounds(14,85,930,24); $acquireTab.Controls.Add($apkLabel)
    $acquireHint=New-Object Windows.Forms.Label
    $launchWithBypass=New-Object Windows.Forms.CheckBox; $launchWithBypass.Text='설치 후 앱 실행 확인 (루팅 우회 · 통신 분석은 실행 탭에서 선택)'; $launchWithBypass.Checked=$true
    $launchWithBypass.SetBounds(14,213,940,25); $acquireTab.Controls.Add($launchWithBypass)
    $acquireHint.Text='Google 로그인은 다운로드 기기에서 직접 진행합니다. 설치와 Frida 주입 결과는 연동 결과에 각각 표시합니다.'
    $acquireHint.SetBounds(14,241,940,24); $acquireTab.Controls.Add($acquireHint)
    $acquisition=@{Paths=@();LastApps='';LastDevices=''}
    $sourceChoice.Add_SelectedIndexChanged({
        $serialInput.Enabled=$sourceChoice.SelectedIndex -eq 1
        if ($sourceChoice.SelectedIndex -eq 0) {$serialInput.Text='emulator-5560'} else {$serialInput.Text=''}
        $packageInput.Items.Clear(); $packageInput.Text=''; $acquisition.LastApps=''
    }.GetNewClosure())
    $installTab.Controls.Add($terms)
    $hint=New-Object Windows.Forms.Label
    $hint.Text="새 PC: 약관 확인란 선택 → 자동 설치 / 이어하기 → 관리자 권한 허용.`r`n재부팅이 필요하면 재부팅 후 같은 버튼으로 계속 설치합니다. 확인 버튼은 설치하지 않고 상태만 조회합니다."
    $hint.SetBounds(14,135,950,60); $installTab.Controls.Add($hint)
    $mobileGroup=New-Object Windows.Forms.GroupBox; $mobileGroup.Text='모바일 앱 · APK / 앱 API'; $mobileGroup.ForeColor=$form.ForeColor
    $mobileGroup.SetBounds(14,8,612,252); $runTab.Controls.Add($mobileGroup)
    $systemGroup=New-Object Windows.Forms.GroupBox; $systemGroup.Text='시스템 · IP / URL'; $systemGroup.ForeColor=$form.ForeColor
    $systemGroup.SetBounds(640,8,326,252); $runTab.Controls.Add($systemGroup)
    $runHint=New-Object Windows.Forms.Label
    $rootPackageLabel=New-Object Windows.Forms.Label; $rootPackageLabel.Text='대상 앱'; $rootPackageLabel.SetBounds(14,72,75,26); $mobileGroup.Controls.Add($rootPackageLabel)
    $rootPackageInput=New-Object Windows.Forms.ComboBox; $rootPackageInput.SetBounds(92,68,502,30); $rootPackageInput.AutoCompleteMode='SuggestAppend'; $rootPackageInput.AutoCompleteSource='ListItems'; $mobileGroup.Controls.Add($rootPackageInput)
    if ($script:State.ContainsKey('acquired-app')) {$rootPackageInput.Text=$script:State['acquired-app'].package}
    if ($script:State.ContainsKey('mobile-target')) {$rootPackageInput.Text=$script:State['mobile-target'].Package}
    $routeHint=New-Object Windows.Forms.Label
    $routeHint.Text='앱 추출·설치 → 대상 앱 선택 → MobSF/Burp 분석 → 모바일 펜테스트'
    $routeHint.SetBounds(14,222,580,26); $mobileGroup.Controls.Add($routeHint)
    $systemTargetLabel=New-Object Windows.Forms.Label; $systemTargetLabel.Text='대상 IP / URL (또는 OpenCode에서 입력)'; $systemTargetLabel.SetBounds(14,25,298,25); $systemGroup.Controls.Add($systemTargetLabel)
    $systemTargetInput=New-Object Windows.Forms.TextBox; $systemTargetInput.SetBounds(14,53,298,28); $systemGroup.Controls.Add($systemTargetInput)
    $runHint.Text='웹 점검은 Burp 포함 버튼을 선택하세요.'
    $runHint.Font=New-Object Drawing.Font('맑은 고딕',8)
    $runHint.SetBounds(14,234,298,16); $systemGroup.Controls.Add($runHint)
    $grid=New-Object Windows.Forms.DataGridView
    $grid.SetBounds(0,0,970,200); $grid.Anchor='Top,Left,Right'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false
    $grid.AutoSizeColumnsMode='Fill'; $grid.RowHeadersVisible=$false
    $grid.BackgroundColor=$form.BackColor; $grid.DefaultCellStyle.ForeColor=[Drawing.Color]::Black
    foreach ($column in @(@('Name','서비스 / 연결'),@('Status','결과'),@('Detail','확인 내용'),@('Updated','검사 시간'))) { [void]$grid.Columns.Add($column[0],$column[1]) }
    $grid.Columns['Detail'].FillWeight=240; $grid.Columns['Status'].FillWeight=60
    $grid.DefaultCellStyle.WrapMode='True'; $grid.AutoSizeRowsMode='AllCells'
    $resultTab.Controls.Add($grid)
    $model=@(
        @{Text='기존 설치 / 사전 확인';Action='Preflight';X=211;Y=65;W=185;Page=$installTab},
        @{Text='자동 설치 / 이어하기';Action='Install';X=14;Y=65;W=185;Page=$installTab},
        @{Text='설치 상태 확인';Action='Verify';X=408;Y=65;W=170;Page=$installTab},
        @{Text='설정 파일';Action='Config';X=590;Y=65;W=140;Page=$installTab},
        @{Text='사용 가이드';Action='Guide';X=742;Y=65;W=140;Page=$installTab},
        @{Text='① 앱 추출 / 루팅 기기 설치';Action='OpenAcquisition';X=14;Y=25;W=284;H=36;Page=$mobileGroup},
        @{Text='② 설치 앱 찾기 / 새로고침';Action='Launch';Tool='RefreshAnalysisApps';X=310;Y=25;W=284;H=36;Page=$mobileGroup},
        @{Text='③ MobSF 정적 / 동적 분석';Action='Launch';Tool='MobSfAnalysis';X=14;Y=108;W=284;H=36;Page=$mobileGroup},
        @{Text='③ 앱 API 분석 (Burp)';Action='Launch';Tool='MobileApi';X=310;Y=108;W=284;H=36;Page=$mobileGroup},
        @{Text='④ 모바일 앱 펜테스트 연결 · OpenCode + HexStrike';Action='Launch';Tool='MobileAI';X=14;Y=150;W=580;H=36;Page=$mobileGroup},
        @{Text='루팅 우회 후 앱 실행';Action='Launch';Tool='RootBypass';X=14;Y=190;W=284;H=28;Page=$mobileGroup},
        @{Text='우회 세션 종료';Action='Launch';Tool='StopRootBypass';X=310;Y=190;W=284;H=28;Page=$mobileGroup},
        @{Text='시스템(IP/URL) 펜테스트 실행';Action='Launch';Tool='SystemAnalysis';X=14;Y=91;W=298;H=30;Page=$systemGroup},
        @{Text='웹 프록시 + 시스템 펜테스트';Action='Launch';Tool='WebProxyTest';X=14;Y=128;W=298;H=30;Page=$systemGroup},
        @{Text='MCP 실제 응답 확인 / 복구 판단';Action='Launch';Tool='CheckMcp';X=14;Y=165;W=298;H=30;Page=$systemGroup},
        @{Text='바이너리 분석 도구 추가 설치';Action='Launch';Tool='BinaryAnalysisTools';X=14;Y=202;W=298;H=28;Page=$systemGroup},
        @{Text='관리 환경 전체 종료';Action='Stop';X=14;Y=210;W=190;Page=$resultTab},
        @{Text='① Google Play 기기 실행';Action='Launch';Tool='PlayDownload';X=14;Y=115;W=285;Page=$acquireTab},
        @{Text='② 설치 앱 목록 새로고침';Action='Launch';Tool='RefreshApps';X=315;Y=115;W=285;Page=$acquireTab},
        @{Text='③ 가져오기 / 분석 기기 설치';Action='Launch';Tool='AcquireApp';X=615;Y=115;W=325;Page=$acquireTab},
        @{Text='고객 APK 파일 선택';Action='PickApks';X=14;Y=166;W=285;Page=$acquireTab},
        @{Text='다운로드 계정·앱 초기화';Action='Launch';Tool='ResetPlay';X=315;Y=166;W=285;Page=$acquireTab},
        @{Text='연결된 실제 단말 확인';Action='Launch';Tool='RefreshDevices';X=615;Y=166;W=325;Page=$acquireTab},
        @{Text='선택한 APK 세트 재사용';Action='ReuseApks';X=14;Y=190;W=300;H=40;Page=$libraryTab},
        @{Text='보관 폴더 열기';Action='OpenLibrary';X=330;Y=190;W=300;H=40;Page=$libraryTab},
        @{Text='보관함 새로고침';Action='RefreshLibrary';X=646;Y=190;W=318;H=40;Page=$libraryTab}
    )
    $gui=@{Process=$null; LastLogLength=-1; Log=$script:Log; ConfigPath=$script:ConfigPath; Connections=(Join-Path $script:Runtime 'connections.json'); LastConnections=''; LastAction=''; Started=[DateTime]::MinValue; NextSessionCheck=[DateTime]::MinValue}
    Add-InfrastructureTab -Tabs $tabs -Gui $gui -Status $status -Buttons $buttons -Form $form
    Add-ReportsTab -Tabs $tabs -Gui $gui -Status $status -Buttons $buttons -Form $form
    foreach ($item in $model) {
        $button=New-Object Windows.Forms.Button
        $button.Text=$item.Text
        $height=46; if ($item.ContainsKey('H')) {$height=$item.H}
        $button.SetBounds($item.X,$item.Y,$item.W,$height)
        $button.FlatStyle='Flat'; $button.FlatAppearance.BorderSize=0
        $button.BackColor=[Drawing.Color]::FromArgb(42,54,75)
        if ($item.Action -eq 'Install') { $button.BackColor=[Drawing.Color]::FromArgb(26,109,90) }
        $button.Tag=$item
        $button.Add_Click({
            $task=$this.Tag
            try {
                if ($task.Action -eq 'Guide') { Show-Guide; return }
                if ($task.Action -eq 'OpenAcquisition') {$tabs.SelectedTab=$acquireTab; return}
                if ($task.Action -eq 'Config') { Start-Process notepad.exe -ArgumentList ('"'+$gui.ConfigPath+'"'); return }
                if ($task.Action -eq 'RefreshLibrary') {& $refreshLibrary; return}
                if ($task.Action -eq 'OpenLibrary') {
                    $folder=Get-ApkLibraryRoot
                    if ($libraryList.SelectedItem) {$folder=$libraryList.SelectedItem.Folder}
                    New-Item -ItemType Directory -Path $folder -Force | Out-Null
                    Start-Process explorer.exe -ArgumentList ('"'+$folder+'"'); return
                }
                if ($gui.Process) {$gui.Process.Refresh()}
                if ($gui.Process -and -not $gui.Process.HasExited) {
                    if ($task.Action -eq 'Stop') {Stop-GuiWorker $gui.Process; $gui.Process.Dispose(); $gui.Process=$null}
                    else { [Windows.Forms.MessageBox]::Show('현재 작업이 끝난 뒤 실행하거나 관리 환경 전체 종료로 취소하세요.','작업 진행 중') | Out-Null; return }
                }
                if ($task.Action -eq 'PickApks') {
                    $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Filter='Android APK (*.apk)|*.apk'; $dialog.Multiselect=$true
                    try { if ($dialog.ShowDialog() -eq 'OK') { $sourceChoice.SelectedIndex=2; $acquisition.Paths=@($dialog.FileNames); $packageInput.Text=''; $apkLabel.Text="선택한 APK: $($acquisition.Paths.Count)개 · "+(($acquisition.Paths | ForEach-Object {[IO.Path]::GetFileName($_)}) -join ',') } } finally {$dialog.Dispose()}; return
                }
                if ($task.Action -eq 'Install' -and -not $terms.Checked) { [Windows.Forms.MessageBox]::Show('약관을 검토하고 동의란을 선택하세요. 사용 가이드에 공식 약관 링크가 있습니다.','약관 확인') | Out-Null; return }
                if ($task.Action -eq 'ReuseApks') {
                    if (-not $libraryList.SelectedItem) {throw '보관된 APK 세트를 선택하세요.'}
                    $entry=$libraryList.SelectedItem
                    $sourceChoice.SelectedIndex=2; $acquisition.Paths=@($entry.Paths); $packageInput.Text=$entry.Package
                    $apkLabel.Text="보관 APK: $($entry.Package) · $($acquisition.Paths.Count)개 (전체 세트)"
                    $tabs.SelectedTab=$acquireTab; $status.Text='보관 APK 선택 완료 · 가져오기 / 분석 기기 설치를 누르세요.'; return
                }
                $params=@{Action=$task.Action; AcceptLicenses=$terms.Checked}
                if ($task.ContainsKey('Tool')) { $params.Tool=$task.Tool }
                if ($task.Tool -in @('MobileApi','MobileAI','MobSfAnalysis','RootBypass')) { $params.Package=$rootPackageInput.Text.Trim(); Assert-AppPackage $params.Package }
                if ($task.Tool -in @('SystemAnalysis','WebProxyTest')) {$params.Target=$systemTargetInput.Text.Trim()}
                if ($task.Tool -eq 'RootBypass') {$params.CaptureRoute='Preview'}
                if ($task.Tool -eq 'AcquireApp') {$params.LaunchWithBypass=$launchWithBypass.Checked; $params.CaptureRoute='Preview'}
                if ($task.ContainsKey('Tool') -and $task.Tool -in @('PlayDownload','RefreshApps','RefreshDevices','AcquireApp','ResetPlay')) {
                    $params.Package=$packageInput.Text.Trim()
                    if ($task.Tool -eq 'RefreshDevices') {$sourceChoice.SelectedIndex=1; $acquisition.LastDevices=''}
                    if ($task.Tool -eq 'ResetPlay') {
                        if ([Windows.Forms.MessageBox]::Show('전용 Play 다운로드 기기의 Google 계정, 설치 앱과 사용자 데이터를 삭제하고 다시 시작합니다. 추출한 APK와 분석 기기 데이터는 유지됩니다. 초기화할까요?','다운로드 기기 초기화','YesNo','Warning') -ne 'Yes') {return}
                    }
                    if ($task.Tool -in @('AcquireApp','RefreshApps')) {
                        if ($sourceChoice.SelectedIndex -eq 2) {
                            if ($task.Tool -eq 'RefreshApps') {throw '고객 APK는 파일 선택 버튼으로 가져오세요.'}
                            if (-not $acquisition.Paths.Count) {throw '고객 APK 파일을 먼저 선택하세요.'}
                            $params.ApkPaths=$acquisition.Paths
                        } else {$params.SourceSerial=$serialInput.Text.Trim()}
                    }
                }
                $gui.Started=Get-Date
                $gui.Process=Start-Worker @params
                $acquisition.PendingImport=$task.Tool -eq 'AcquireApp'
                $gui.LastAction=$task.Action
                if ($task.Action -eq 'Install' -or ($task.Action -in @('Launch','Stop') -and $task.Tool -ne 'RefreshAnalysisApps')) { $tabs.SelectedTab=$resultTab }
                $status.Text="$($task.Text) 진행 중 · 백그라운드 준비 상태를 연동 결과와 아래 로그에서 확인하세요."
            } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'실행 오류') | Out-Null }
        }.GetNewClosure())
        $item.Page.Controls.Add($button); $buttons.Add($button)
        if ($item.Action -eq 'Install') {$form.AcceptButton=$button}
    }
    $timer=New-Object Windows.Forms.Timer
    $timer.Interval=1000
    $tick={
        if ((-not $gui.Process -or $gui.Process.HasExited) -and (Get-Date) -ge $gui.NextSessionCheck) {
            $gui.NextSessionCheck=(Get-Date).AddSeconds(3)
            try {if (Sync-MobileSessionState) {$status.Text='모바일 분석 세션 종료 · 다른 실행 / 연동 작업을 선택하세요.'}} catch {}
        }
        $analysisAppsPath=Join-Path (Split-Path $gui.Connections) 'analysis-apps.json'
        if (Test-Path -LiteralPath $analysisAppsPath) {
            try {
                $analysisJson=Read-SharedText $analysisAppsPath
                if (-not $acquisition.ContainsKey('LastAnalysisApps') -or $analysisJson -ne $acquisition.LastAnalysisApps) {
                    $selected=$rootPackageInput.Text; $acquisition.LastAnalysisApps=$analysisJson
                    $rootPackageInput.Items.Clear()
                    foreach ($app in ($analysisJson | ConvertFrom-Json).Packages) {[void]$rootPackageInput.Items.Add([string]$app)}
                    if ($selected) {$rootPackageInput.Text=$selected} elseif ($rootPackageInput.Items.Count) {$rootPackageInput.SelectedIndex=0}
                }
            } catch {}
        }
        $devicesPath=Join-Path (Split-Path $gui.Connections) 'acquisition-devices.json'
        if ((Test-Path -LiteralPath $devicesPath) -and $sourceChoice.SelectedIndex -eq 1) {
            try {
                $devicesJson=[IO.File]::ReadAllText($devicesPath,[Text.Encoding]::UTF8)
                if ($devicesJson -ne $acquisition.LastDevices) {
                    $devices=$devicesJson | ConvertFrom-Json; $acquisition.LastDevices=$devicesJson; $serialInput.Items.Clear()
                    foreach ($device in $devices.Devices) {if ($device.Status -eq 'device') {[void]$serialInput.Items.Add([string]$device.Serial)}}
                    if ($serialInput.Items.Count) {$serialInput.SelectedIndex=0}
                }
            } catch {}
        }
        $appsPath=Join-Path (Split-Path $gui.Connections) 'acquisition-apps.json'
        if (Test-Path -LiteralPath $appsPath) {
            try {
                $appsJson=[IO.File]::ReadAllText($appsPath,[Text.Encoding]::UTF8)
                $apps=$appsJson | ConvertFrom-Json
                if ($appsJson -ne $acquisition.LastApps -and $apps.Serial -eq $serialInput.Text -and $sourceChoice.SelectedIndex -ne 2) {
                    $selectedPackage=$packageInput.Text
                    $acquisition.LastApps=$appsJson; $packageInput.Items.Clear()
                    foreach ($app in $apps.Packages) { [void]$packageInput.Items.Add([string]$app) }
                    if ($selectedPackage) {$packageInput.Text=$selectedPackage}
                }
            } catch {}
        }
        if (Test-Path -LiteralPath $gui.Connections) {
            try {
                $json=Read-SharedText $gui.Connections
                if ($json -ne $gui.LastConnections) {
                    $gui.LastConnections=$json; $grid.Rows.Clear()
                    $rows=$json | ConvertFrom-Json
                    foreach ($row in $rows) { [void]$grid.Rows.Add([string]$row.Name,[string]$row.Status,[string]$row.Detail,[string]$row.Updated) }
                    $connectionMap.Tag.Views=@(Get-ConnectionMapView -Rows @($rows))
                    $connectionTip.SetToolTip($connectionMap,('마지막 실행 검사 결과 · 클릭하여 상세 보기'+"`r`n"+(($connectionMap.Tag.Views | ForEach-Object {$_.Name+': '+$_.Label+"`r`n"+$_.Detail}) -join "`r`n`r`n")))
                    $connectionMap.Invalidate()
                }
            } catch { }
        }

        if (Test-Path -LiteralPath $gui.Log) {
            try {
                $text=Read-SharedText $gui.Log
                if ($text.Length -ne $gui.LastLogLength) {
                    $gui.LastLogLength=$text.Length
                    if ($text.Length -gt 18000) { $text=$text.Substring($text.Length-18000) }
                    $log.Text=$text; $log.SelectionStart=$log.TextLength; $log.ScrollToCaret()
                }
            } catch { }
        }
        if ($gui.Process) {$gui.Process.Refresh()}
        $busy=$gui.Process -and -not $gui.Process.HasExited
        if ($busy -and $gui.LastAction -ne 'Install') {
            $progressBar.Style='Marquee'; $progressLabel.Text='작업 진행 중 · 아래 로그에서 준비 상태를 확인하세요.'
        } else {
            $progressBar.Style='Continuous'
            try {
                $statePath=Join-Path (Split-Path $gui.Connections) 'state.json'
                $snapshot=Read-SharedText $statePath | ConvertFrom-Json
                $saved=$snapshot.PSObject.Properties['install-progress']
                if ($saved -and (-not $busy -or [DateTimeOffset]::Parse($saved.Value.Started).LocalDateTime -ge $gui.Started)) {
                    $view=Get-InstallationProgressView $saved.Value
                    $progressBar.Value=$view.Percent; $progressLabel.Text=$view.Text
                } elseif ($busy) {$progressBar.Value=0; $progressLabel.Text='설치 0% · 설치 준비 중'}
                elseif ($gui.LastAction -and $gui.LastAction -ne 'Install') {$progressLabel.Text='작업 종료 · 설치 진행률은 완료한 단계 기준입니다.'}
            } catch {if ($busy) {$progressBar.Value=0; $progressLabel.Text='설치 0% · 설치 준비 중'}}
        }
        foreach ($b in $buttons) { $b.Enabled=(-not $busy) -or $b.Tag.Action -eq 'Guide' -or ($b.Tag.Action -eq 'Stop' -and $gui.LastAction -ne 'Stop') }
        if ($gui.Process -and $gui.Process.HasExited) {
            $gui.Process.WaitForExit()
            $code=$gui.Process.ExitCode
            if ($acquisition.ContainsKey('PendingImport') -and $acquisition.PendingImport) {
                $acquisition.PendingImport=$false
                try {
                    $fresh=Get-Content -LiteralPath (Join-Path (Split-Path $gui.Connections) 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($fresh.'acquired-app'.status -in @('installed','instrumented','process-alive','launch-failed')) {$rootPackageInput.Text=$fresh.'acquired-app'.package; $tabs.SelectedTab=$runTab}
                } catch {}
            }
            $status.Text=Get-WorkerCompletionMessage -Action $gui.LastAction -ExitCode $code -ConnectionsPath $gui.Connections -Started $gui.Started
            $gui.Process.Dispose(); $gui.Process=$null
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    & $tick
    $timer.Start()
    if ($script:State.ContainsKey('play-process')) { $tabs.SelectedTab=$acquireTab }
    elseif ($script:State.ContainsKey('mobile-target')) {$tabs.SelectedTab=$runTab}
    $applyTheme={
        $theme='Dark'; if ($themeChoice.SelectedIndex -eq 1) {$theme='Light'}
        Set-SetupTheme $form $theme
        $connectionMap.Invalidate()
    }.GetNewClosure()
    & $applyTheme
    if (-not $aiSaved.IbmKey -and -not $aiSaved.DeepSeekKey) {$tabs.SelectedTab=$aiTab}
    if (@((Get-InfrastructureSettings).Servers).Count) {$tabs.SelectedIndex=6}
    try {
        $savedPreferences=Read-SharedText $preferencesPath | ConvertFrom-Json
        if ($savedPreferences.PSObject.Properties['LastTab'] -and [int]$savedPreferences.LastTab -ge 0 -and [int]$savedPreferences.LastTab -lt $tabs.TabPages.Count) {$tabs.SelectedIndex=[int]$savedPreferences.LastTab}
    } catch {}
    $savePreferences={
        $theme='Dark'; if ($themeChoice.SelectedIndex -eq 1) {$theme='Light'}
        Write-AtomicText -Path $preferencesPath -Text (@{Theme=$theme;LastTab=$tabs.SelectedIndex} | ConvertTo-Json)
    }.GetNewClosure()
    $tabs.Add_SelectedIndexChanged({try {& $savePreferences} catch {$status.Text='화면 설정 저장 실패: '+$_.Exception.Message}}.GetNewClosure())
    $themeChoice.Add_SelectedIndexChanged({
        & $applyTheme
        try {& $savePreferences} catch {$status.Text='테마 설정 저장 실패: '+$_.Exception.Message}
    }.GetNewClosure())
    $form.Add_Shown({
        $log.SelectionStart=$log.TextLength; $log.ScrollToCaret()
        # Raise only at startup; do not stay above the analysis tools afterward.
        $form.WindowState='Normal'; $form.TopMost=$true; $form.BringToFront(); [void]$form.Activate(); $form.TopMost=$false
    }.GetNewClosure())
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); $connectionTip.Dispose() }.GetNewClosure())
    return $form
}

function Show-SetupGui {
    $form=New-SetupForm
    [Windows.Forms.Application]::Run($form)
    $form.Dispose()
}
