function Add-InfrastructureTab {
    param($Tabs,$Gui,$Status,$Buttons,$Form)
    $infraRoot=$script:Root; $infraRuntime=$script:Runtime
    $page=New-Object Windows.Forms.TabPage; $page.Text='⑦ 인프라 점검'; $page.Name='InfrastructureTab'; $Tabs.TabPages.Add($page)
    $sub=New-Object Windows.Forms.TabControl; $sub.Dock='Fill'; $page.Controls.Add($sub)
    $serversPage=New-Object Windows.Forms.TabPage; $serversPage.Text='서버 등록 / 실행'; $sub.TabPages.Add($serversPage)
    $resultsPage=New-Object Windows.Forms.TabPage; $resultsPage.Text='점검 결과 / 재실행'; $sub.TabPages.Add($resultsPage)
    $bulkPage=New-Object Windows.Forms.TabPage; $bulkPage.Text='대량 등록 / 실행 설정'; $sub.TabPages.Add($bulkPage)
    $bulkHint=New-Object Windows.Forms.Label; $bulkHint.Text='1,000대 이상: CSV 일괄 등록 → 접속 확인 → 배치 점검 → 실패 서버 재실행'; $bulkHint.SetBounds(12,12,920,26); $bulkPage.Controls.Add($bulkHint)
    $forkLabel=New-Object Windows.Forms.Label; $forkLabel.Text='동시 작업 수'; $forkLabel.SetBounds(12,52,130,26); $bulkPage.Controls.Add($forkLabel)
    $forks=New-Object Windows.Forms.NumericUpDown; $forks.Name='InfraForks'; $forks.Minimum=1; $forks.Maximum=100; $forks.Value=20; $forks.SetBounds(145,48,100,26); $bulkPage.Controls.Add($forks)
    $batchLabel=New-Object Windows.Forms.Label; $batchLabel.Text='배치 서버 수'; $batchLabel.SetBounds(280,52,130,26); $bulkPage.Controls.Add($batchLabel)
    $batch=New-Object Windows.Forms.NumericUpDown; $batch.Name='InfraBatchSize'; $batch.Minimum=1; $batch.Maximum=1000; $batch.Value=100; $batch.SetBounds(415,48,100,26); $bulkPage.Controls.Add($batch)
    $bulkNote=New-Object Windows.Forms.Label; $bulkNote.Text="권장 시작값: 동시 20 / 배치 100. 10대 접속 확인 후 CPU·메모리·망 부하에 맞춰 조절하세요.`r`nWindows: WinRM/PSRP HTTPS 5986 · Linux: SSH 계정·암호 또는 키 22 · OS와 망별로 나눠 운영하세요.`r`nCSV 필수: Host / User / Connection / Platform / Port + 인증 정보. 이름 생략 시 IP 사용. 암호 CSV는 별도 보호하세요."; $bulkNote.SetBounds(12,90,920,82); $bulkPage.Controls.Add($bulkNote)
    $fields=@{}; $state=@{Loading=$false;SettingsStamp='';RunsStamp='';ConnectionSync=$false}
    $serverList=New-Object Windows.Forms.ListBox; $serverList.Name='InfrastructureServers'; $serverList.DisplayMember='Label'; $serverList.SelectionMode='MultiExtended'; $serverList.SetBounds(12,8,218,125); $serversPage.Controls.Add($serverList)
    $serverList.SetBounds(12,38,218,95)
    $search=New-Object Windows.Forms.TextBox; $search.Name='InfraSearch'; $search.SetBounds(12,8,218,26); $serversPage.Controls.Add($search)
    $makeLabel={param($text,$x,$y,$width) $label=New-Object Windows.Forms.Label; $label.Text=$text; $label.SetBounds($x,$y,$width,24); $serversPage.Controls.Add($label)}
    foreach ($row in @(@('Alias','이름/IP',250,8,320,210),@('Host','주소',550,8,610,330),@('User','계정',550,39,610,330),@('Password','접속 암호',250,101,320,210),@('BecomePassword','sudo 암호',550,101,650,290),@('KeyFile','키(선택)',250,132,320,430))) {
        & $makeLabel $row[1] $row[2] ($row[3]+3) ($row[4]-$row[2]-4)
        $box=New-Object Windows.Forms.TextBox; $box.Name=('Infra'+$row[0]); $box.SetBounds($row[4],$row[3],$row[5],26)
        if ($row[0] -in @('Password','BecomePassword')) {$box.UseSystemPasswordChar=$true}
        $fields[$row[0]]=$box; $serversPage.Controls.Add($box)
    }
    & $makeLabel '서버 종류' 250 42 68
    $kind=New-Object Windows.Forms.ComboBox; $kind.Name='InfraKind'; $kind.DropDownStyle='DropDownList'; $kind.SetBounds(320,39,210,26); [void]$kind.Items.AddRange(@('Linux · Debian (SSH)','Linux · RedHat (SSH)','Windows · WinRM','Windows · PSRP','Unix · AIX (SSH)','Unix · HP-UX (SSH)','Unix · Solaris (SSH)','SSH · OS 자동 감지')); $kind.SelectedIndex=7; $serversPage.Controls.Add($kind)
    & $makeLabel '포트' 250 73 68
    $port=New-Object Windows.Forms.NumericUpDown; $port.Name='InfraPort'; $port.Minimum=1; $port.Maximum=65535; $port.Value=22; $port.SetBounds(320,70,78,26); $serversPage.Controls.Add($port)
    $protocol=New-Object Windows.Forms.ComboBox; $protocol.Name='InfraProtocol'; $protocol.DropDownStyle='DropDownList'; $protocol.SetBounds(408,70,122,26); [void]$protocol.Items.AddRange(@('HTTPS','HTTP')); $protocol.SelectedIndex=0; $serversPage.Controls.Add($protocol)
    & $makeLabel '제한(초)' 550 73 97
    $timeout=New-Object Windows.Forms.NumericUpDown; $timeout.Name='InfraTimeout'; $timeout.Minimum=10; $timeout.Maximum=3600; $timeout.Value=90; $timeout.SetBounds(650,70,86,26); $serversPage.Controls.Add($timeout)
    $enabled=New-Object Windows.Forms.CheckBox; $enabled.Name='InfraEnabled'; $enabled.Text='전체 점검에 포함'; $enabled.Checked=$true; $enabled.SetBounds(754,70,186,26); $serversPage.Controls.Add($enabled)
    $trust=New-Object Windows.Forms.CheckBox; $trust.Name='InfraTrustNewHostKey'; $trust.Text='서버 지문 자동 저장'; $trust.Checked=$true; $trust.Enabled=$false; $trust.SetBounds(250,163,230,24); $serversPage.Controls.Add($trust)
    $hint=New-Object Windows.Forms.Label; $hint.Name='InfraCredentialHint'; $hint.Text='암호 빈칸 = 저장값 유지 · sudo 미등록 = 접속 암호'; $hint.SetBounds(490,165,260,23); $hint.AutoEllipsis=$true; $serversPage.Controls.Add($hint)
    $updateKind={
        $linux=$kind.SelectedIndex -notin @(2,3)
        $fields.KeyFile.Enabled=$linux; $fields.BecomePassword.Enabled=$linux; $trust.Enabled=$false; $protocol.Enabled=-not $linux
    }.GetNewClosure()
    $kind.Add_SelectedIndexChanged({if (-not $state.Loading) {if ($kind.SelectedIndex -notin @(2,3)) {$port.Value=22} else {$port.Value=5986}; & $updateKind}}.GetNewClosure())
    $protocol.Add_SelectedIndexChanged({if (-not $state.Loading -and -not $state.ConnectionSync -and $kind.SelectedIndex -in @(2,3)) {
        $state.ConnectionSync=$true
        try {if ($port.Value -in @(22,5985,5986)) {if ($protocol.SelectedIndex -eq 0) {$port.Value=5986} else {$port.Value=5985}}} finally {$state.ConnectionSync=$false}
    }}.GetNewClosure())
    $port.Add_ValueChanged({if (-not $state.Loading -and -not $state.ConnectionSync -and $kind.SelectedIndex -in @(2,3) -and $port.Value -in @(5985,5986)) {
        $state.ConnectionSync=$true
        try {if ($port.Value -eq 5985) {$protocol.SelectedIndex=1} else {$protocol.SelectedIndex=0}} finally {$state.ConnectionSync=$false}
    }}.GetNewClosure())
    $newServer={
        $state.Loading=$true
        $serverList.ClearSelected()
        foreach ($box in $fields.Values) {$box.Clear()}; $fields.Alias.ReadOnly=$false
        $kind.SelectedIndex=7; $port.Value=22; $protocol.SelectedIndex=0; $timeout.Value=90; $enabled.Checked=$true; $trust.Checked=$true
        $state.Loading=$false; & $updateKind
    }.GetNewClosure()
    $serverList.Add_SelectedIndexChanged({
        if ($state.Loading -or -not $serverList.SelectedItem) {return}
        $s=$serverList.SelectedItem.Server; $state.Loading=$true
        foreach ($name in @('Alias','Host','User','KeyFile')) {$fields[$name].Text=[string]$s.$name}
        $fields.Alias.ReadOnly=$true; $fields.Password.Clear(); $fields.BecomePassword.Clear()
        $kind.SelectedIndex=0
        if ($s.Connection -eq 'ssh' -and $s.Platform -eq 'Auto') {$kind.SelectedIndex=7}
        elseif ($s.Connection -eq 'ssh' -and $s.Platform -eq 'RedHat') {$kind.SelectedIndex=1}
        elseif ($s.Connection -eq 'ssh' -and $s.Platform -eq 'AIX') {$kind.SelectedIndex=4}
        elseif ($s.Connection -eq 'ssh' -and $s.Platform -eq 'HP-UX') {$kind.SelectedIndex=5}
        elseif ($s.Connection -eq 'ssh' -and $s.Platform -eq 'Solaris') {$kind.SelectedIndex=6}
        elseif ($s.Connection -eq 'winrm') {$kind.SelectedIndex=2} elseif ($s.Connection -eq 'psrp') {$kind.SelectedIndex=3}
        $protocol.SelectedIndex=0; if ($s.Protocol -eq 'http') {$protocol.SelectedIndex=1}
        $port.Value=[int]$s.Port; $timeout.Value=[int]$s.Timeout; $enabled.Checked=[bool]$s.Enabled; $trust.Checked=$true
        $saved='미등록'; if ($s.Password) {$saved='저장됨'}
        $hint.Text="접속 암호: $saved · 빈칸은 저장값 유지 / sudo 미등록=접속 암호"
        $state.Loading=$false; & $updateKind
    }.GetNewClosure())
    $refreshServers={
        $selected=@($serverList.SelectedItems | ForEach-Object {$_.Server.Alias})
        $state.Loading=$true; $serverList.BeginUpdate(); $serverList.Items.Clear()
        foreach ($s in @((Get-InfrastructureSettings).Servers)) {
            if ($search.Text -and ($s.Alias+' '+$s.Host).IndexOf($search.Text,[StringComparison]::OrdinalIgnoreCase) -lt 0) {continue}
            $label=$s.Alias+' · '+$s.Host; if (-not $s.Enabled) {$label+=' (제외)'}
            $index=$serverList.Items.Add([pscustomobject]@{Label=$label;Server=$s})
            if ($s.Alias -in $selected) {$serverList.SetSelected($index,$true)}
        }
        $serverList.EndUpdate(); $state.Loading=$false
        if (-not $serverList.SelectedItems.Count -and $serverList.Items.Count) {$serverList.SelectedIndex=0}
    }.GetNewClosure()
    $search.Add_TextChanged($refreshServers)
    $saveServer={
        $connection='ssh'; $platform='Debian'; if ($kind.SelectedIndex -eq 1) {$platform='RedHat'} elseif ($kind.SelectedIndex -eq 2) {$connection='winrm'} elseif ($kind.SelectedIndex -eq 3) {$connection='psrp'} elseif ($kind.SelectedIndex -eq 4) {$platform='AIX'} elseif ($kind.SelectedIndex -eq 5) {$platform='HP-UX'} elseif ($kind.SelectedIndex -eq 6) {$platform='Solaris'} elseif ($kind.SelectedIndex -eq 7) {$platform='Auto'}
        $scheme='https'; if ($protocol.SelectedIndex -eq 1) {$scheme='http'}
        $s=[pscustomobject]@{Alias=$fields.Alias.Text.Trim();Host=$fields.Host.Text.Trim();User=$fields.User.Text.Trim();Connection=$connection;Platform=$platform;Port=[int]$port.Value;Protocol=$scheme;Timeout=[int]$timeout.Value;Enabled=$enabled.Checked;TrustNewHostKey=$trust.Checked;KeyFile=$fields.KeyFile.Text.Trim();Password=$fields.Password.Text;BecomePassword=$fields.BecomePassword.Text}
        Save-InfrastructureServer $s
        $fields.Password.Clear(); $fields.BecomePassword.Clear(); & $refreshServers
        $serverList.ClearSelected()
        for ($index=0;$index -lt $serverList.Items.Count;$index++) {if ($serverList.Items[$index].Server.Alias -eq $s.Alias) {$serverList.SetSelected($index,$true);break}}
        $Status.Text='서버 설정 저장 완료 · 암호는 현재 Windows 계정으로 암호화됩니다.'
    }.GetNewClosure()
    $runs=New-Object Windows.Forms.ComboBox; $runs.Name='InfrastructureRunHistory'; $runs.DropDownStyle='DropDownList'; $runs.DisplayMember='Label'; $runs.SetBounds(12,8,366,27); $resultsPage.Controls.Add($runs)
    $textPath=New-Object Windows.Forms.TextBox; $textPath.Name='InfraTextPath'; $textPath.ReadOnly=$true; $textPath.SetBounds(12,42,930,24); $resultsPage.Controls.Add($textPath)
    $updateTextPath={
        $path=$null; if ($runs.SelectedItem) {$path=Get-InfrastructureTextPath $runs.SelectedItem.Id}
        if ($path -and (Test-Path -LiteralPath $path)) {$textPath.Text=$path}
        else {$textPath.Text='저장 폴더: '+(Get-InfrastructureTextDirectory)+' · 기존 결과는 「기존 결과 TXT 모으기」로 생성 (정상 실행 항목만 수록)'}
    }.GetNewClosure()
    $grid=New-Object Windows.Forms.DataGridView; $grid.Name='InfrastructureResults'; $grid.SetBounds(12,70,930,113); $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.RowHeadersVisible=$false; $grid.AutoSizeColumnsMode='Fill'; $grid.SelectionMode='FullRowSelect'
    $select=New-Object Windows.Forms.DataGridViewCheckBoxColumn; $select.Name='Retry'; $select.HeaderText='선택'; $select.FillWeight=35; [void]$grid.Columns.Add($select)
    foreach ($pair in @(@('Server','서버',105),@('State','실행 상태',85),@('Good','양호',45),@('Vulnerable','취약',45),@('Manual','수동',45),@('NA','해당 없음',60),@('Errors','실패 사유',280))) {$c=New-Object Windows.Forms.DataGridViewTextBoxColumn; $c.Name=$pair[0];$c.HeaderText=$pair[1];$c.FillWeight=$pair[2];$c.ReadOnly=$true;[void]$grid.Columns.Add($c)}
    $resultsPage.Controls.Add($grid)
    $showRun={
        $grid.Rows.Clear()
        & $updateTextPath
        if (-not $runs.SelectedItem) {return}
        foreach ($prop in $runs.SelectedItem.Summary.servers.PSObject.Properties) {
            $r=$prop.Value; $counts=@{}; foreach ($p in $r.counts.PSObject.Properties) {$counts[$p.Name]=[int]$p.Value}
            $label='완료'; if ($r.execution_failed) {
                $label='실행 실패'
                $rc=$runs.SelectedItem.Summary.PSObject.Properties['ansible_rc']
                if ($rc -and $rc.Value -eq 0) {$label='항목 미완전'}
            }
            $index=$grid.Rows.Add($false,$prop.Name,$label,[int]$counts['GOOD'],[int]$counts['VULNERABLE'],[int]$counts['MANUAL'],([int]$counts['N/A']+[int]$counts['NA']+[int]$counts['NOT_APPLICABLE']),($r.errors -join ' / '))
            $grid.Rows[$index].Tag=@{Alias=$prop.Name;Failed=[bool]$r.execution_failed}
            $grid.Rows[$index].Cells['Errors'].ToolTipText=($r.errors -join "`r`n")
        }
    }.GetNewClosure()
    $runs.Add_SelectedIndexChanged($showRun)
    $refreshRuns={
        $selected=''; if ($runs.SelectedItem) {$selected=$runs.SelectedItem.Id}
        $history=@(Get-InfrastructureRuns); $signature=($history.Id -join '|')
        if ($state.RunsStamp -eq $signature) {return}
        $state.RunsStamp=$signature; $runs.Items.Clear()
        foreach ($run in $history) {[void]$runs.Items.Add($run)}
        if ($runs.Items.Count) {$runs.SelectedIndex=0}
    }.GetNewClosure()
    $begin={
        param($tool,$request)
        if ($Gui.Process -and -not $Gui.Process.HasExited) {throw '현재 작업이 끝난 뒤 실행하세요.'}
        if($tool -eq 'InfraDiscover'){$cached=Join-Path $infraRuntime 'infra-runs\infra-discovery.json';if(Test-Path -LiteralPath $cached){Remove-Item -LiteralPath $cached -Force}}
        $request.Forks=[int]$forks.Value; $request.BatchSize=[int]$batch.Value
        $Gui.Started=Get-Date; $Gui.LastAction='Infrastructure'
        $Gui.Process=Start-Worker -Action Infrastructure -Tool $tool -Target ($request | ConvertTo-Json -Compress)
        $Status.Text='인프라 작업 진행 중 · 아래 로그와 점검 결과를 확인하세요.'
    }.GetNewClosure()
    $actions=@(
        @{Name='InfraProfiles';Text='OS / Web·WAS / DB 구성';X=760;Y=132;W=180;Page=$serversPage;Click={if(-not $serverList.SelectedItem){throw '서버를 먼저 저장하고 선택하세요.'};Show-InfrastructureProfileEditor -Owner $Form -Server $serverList.SelectedItem.Server; & $refreshServers}.GetNewClosure()},
        @{Name='InfraDiscover';Text='OS / 서비스 자동 감지';X=760;Y=163;W=180;Page=$serversPage;Click={if(-not $serverList.SelectedItems.Count){throw '서버를 저장하고 선택하세요.'};$state.DiscoveryPending=$true;& $begin 'InfraDiscover' @{Hosts=@($serverList.SelectedItems | ForEach-Object {$_.Server.Alias});RunId=''}}.GetNewClosure()},
        @{Name='InfraCsv';Text='CSV 일괄 등록';X=12;Y=180;W=180;Page=$bulkPage;Click={
            $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Filter='UTF-8 CSV (*.csv)|*.csv'
            try {if ($dialog.ShowDialog() -eq 'OK') {$count=Import-InfrastructureCsv $dialog.FileName; & $refreshServers; $Status.Text="CSV 서버 $count 대 등록 완료"}} finally {$dialog.Dispose()}
        }.GetNewClosure()},
        @{Name='InfraCsvTemplate';Text='CSV 양식 저장';X=204;Y=180;W=180;Page=$bulkPage;Click={
            $dialog=New-Object Windows.Forms.SaveFileDialog; $dialog.Filter='CSV (*.csv)|*.csv'; $dialog.FileName='servers.csv'
            try {if ($dialog.ShowDialog() -eq 'OK') {
                Copy-Item -LiteralPath (Join-Path $infraRoot 'infrastructure\inventory\servers.template.csv') -Destination $dialog.FileName
                Copy-Item -LiteralPath (Join-Path $infraRoot 'infrastructure\inventory\servers.csv-guide.ko.txt') -Destination ([IO.Path]::ChangeExtension($dialog.FileName,'.작성안내.txt'))
                $Status.Text='CSV 양식과 필수 항목 작성 안내 저장 완료. 두 파일을 고객에게 전달하세요.'
            }} finally {$dialog.Dispose()}
        }.GetNewClosure()},
        @{Name='InfraOfflineKit';Text='고객 실행본 저장';X=396;Y=180;W=180;Page=$bulkPage;Click={
            $dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.Filter='고객 자체 점검 배포 ZIP (*.zip)|*.zip';$dialog.FileName='TriGuard-Infrastructure-Offline.zip'
            try {if ($dialog.ShowDialog() -eq 'OK') {
                Copy-Item -LiteralPath (Join-Path $infraRoot 'offline-kit\TriGuard-Infrastructure-Offline.zip') -Destination $dialog.FileName
                $Status.Text='고객 실행본과 설명서 저장 완료. 고객에게 ZIP 전체를 전달하세요.'
            }} finally {$dialog.Dispose()}
        }.GetNewClosure()},
        @{Name='InfraOfflineImport';Text='고객 실행 결과 가져오기';X=588;Y=180;W=230;Page=$bulkPage;Click={
            $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='고객 자체 점검 결과 ZIP (*.zip)|*.zip';$dialog.Multiselect=$true
            try {if ($dialog.ShowDialog() -eq 'OK') {& $begin 'InfraOfflineImport' @{Files=@($dialog.FileNames)}}} finally {$dialog.Dispose()}
        }.GetNewClosure()},
        @{Name='InfraNew';Text='새 서버';X=12;Y=140;W=103;Page=$serversPage;Click=$newServer},
        @{Name='InfraSave';Text='서버 저장';X=124;Y=140;W=106;Page=$serversPage;Click=$saveServer},
        @{Name='InfraDelete';Text='서버 삭제';X=12;Y=177;W=103;Page=$serversPage;Click={if (-not $serverList.SelectedItem) {throw '삭제할 서버를 선택하세요.'}; Save-InfrastructureServer $serverList.SelectedItem.Server -Remove; & $refreshServers; & $newServer}.GetNewClosure()},
        @{Name='InfraImport';Text='기존 서버';X=124;Y=177;W=106;Page=$serversPage;Click={& $begin 'InfraImport' @{Hosts=@();RunId=''}}.GetNewClosure()},
        @{Name='InfraInstall';Text='Ansible 설치 / 확인';X=250;Y=193;W=155;Page=$serversPage;Click={& $begin 'InfraInstall' @{Hosts=@();RunId=''}}.GetNewClosure()},
        @{Name='InfraPreflight';Text='접속 / 권한 확인';X=413;Y=193;W=150;Page=$serversPage;Click={& $begin 'InfraPreflight' @{Hosts=@($serverList.SelectedItems | ForEach-Object {$_.Server.Alias});RunId=''}}.GetNewClosure()},
        @{Name='InfraRunSelected';Text='선택 서버 점검';X=571;Y=193;W=140;Page=$serversPage;Click={if (-not $serverList.SelectedItems.Count) {throw '점검할 서버를 선택하세요.'}; & $begin 'InfraRun' @{Hosts=@($serverList.SelectedItems | ForEach-Object {$_.Server.Alias});RunId=''}}.GetNewClosure()},
        @{Name='InfraRunAll';Text='전체 서버 점검';X=719;Y=193;W=125;Page=$serversPage;Click={& $begin 'InfraRun' @{Hosts=@();RunId=''}}.GetNewClosure()},
        @{Name='InfraGuide';Text='가이드';X=852;Y=193;W=90;Page=$serversPage;Click={Start-Process -FilePath (Join-Path $infraRoot 'docs\INFRASTRUCTURE.ko.html') | Out-Null}.GetNewClosure()},
        @{Name='InfraOpenText';Text='점검 결과 TXT 열기';X=386;Y=8;W=170;Page=$resultsPage;Click={
            if (-not $runs.SelectedItem) {throw '점검 이력을 선택하세요.'}
            $path=Get-InfrastructureTextPath $runs.SelectedItem.Id
            if (-not $path -or -not (Test-Path -LiteralPath $path)) {throw '이 회차의 TXT가 없습니다. 기존 결과 TXT 모으기를 누르세요. 접속 확인·스크립트 결과 없는 회차는 생성하지 않습니다.'}
            Start-Process -FilePath notepad.exe -ArgumentList ('"'+$path+'"') | Out-Null
        }.GetNewClosure()},
        @{Name='InfraOpenResults';Text='점검결과 폴더 열기';X=564;Y=8;W=174;Page=$resultsPage;Click={
            $path=Get-InfrastructureTextDirectory;New-Item -ItemType Directory -Path $path -Force | Out-Null
            Start-Process explorer.exe -ArgumentList ('"'+$path+'"') | Out-Null
        }.GetNewClosure()},
        @{Name='InfraTextExport';Text='기존 결과 TXT 모으기';X=746;Y=8;W=196;Page=$resultsPage;Click={& $begin 'InfraTextExport' @{}}.GetNewClosure()},
        @{Name='InfraRetryAll';Text='실패 서버 전체 재실행';X=12;Y=192;W=218;Page=$resultsPage;Click={if (-not $runs.SelectedItem -or -not @($runs.SelectedItem.Summary.failed_hosts).Count) {throw '이 이력에는 실행 실패 서버가 없습니다.'}; & $begin 'InfraRetry' @{Hosts=@();RunId=$runs.SelectedItem.Id}}.GetNewClosure()},
        @{Name='InfraRetrySelected';Text='선택 실패 서버 재실행';X=242;Y=192;W=218;Page=$resultsPage;Click={$grid.EndEdit();$hosts=@($grid.Rows | Where-Object {$_.Cells['Retry'].Value -and $_.Tag.Failed} | ForEach-Object {$_.Tag.Alias});if (-not $hosts.Count) {throw '실행 실패 서버의 선택 칸을 체크하세요.'}; & $begin 'InfraRetry' @{Hosts=$hosts;RunId=$runs.SelectedItem.Id}}.GetNewClosure()},
        @{Name='InfraRefreshResults';Text='결과 새로고침';X=472;Y=192;W=180;Page=$resultsPage;Click={$state.RunsStamp='';& $refreshRuns}.GetNewClosure()},
        @{Name='InfraFailureCsv';Text='담당자 확인용 실패 CSV';X=664;Y=192;W=278;Page=$resultsPage;Click={
            if (-not $runs.SelectedItem) {throw '점검 이력을 선택하세요.'}
            $path=Join-Path $runs.SelectedItem.Folder 'failures.csv'
            if (-not (Test-Path -LiteralPath $path)) {throw '이전 버전 점검에는 실패 CSV가 없습니다. 결과 표의 실패 사유를 확인하세요.'}
            Start-Process -FilePath $path | Out-Null
        }.GetNewClosure()}
    )
    $localButtons=@()
    foreach ($action in $actions) {
        $button=New-Object Windows.Forms.Button; $button.Name=$action.Name; $button.Text=$action.Text; $button.SetBounds($action.X,$action.Y,$action.W,30); $button.Tag=@{Action='Infrastructure';Click=$action.Click}; $button.FlatStyle='Flat'
        $button.Add_Click({try {& $this.Tag.Click} catch {[Windows.Forms.MessageBox]::Show($_.Exception.Message,'인프라 점검') | Out-Null}})
        $action.Page.Controls.Add($button); $localButtons+=,$button
    }
    & $refreshServers; & $refreshRuns; & $updateKind
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=1000
    $timer.Add_Tick({
        $busy=$Gui.Process -and -not $Gui.Process.HasExited
        foreach ($button in $localButtons) {$button.Enabled=-not $busy -or $button.Name -eq 'InfraGuide'}
        foreach ($control in @($serverList,$search,$forks,$batch,$kind,$port,$protocol,$timeout,$enabled,$trust)+@($fields.Values)) {$control.Enabled=-not $busy}
        if (-not $busy) {& $updateKind}
        $path=Join-Path $infraRuntime 'infra-settings.json'; $stamp=''
        if (Test-Path -LiteralPath $path) {$stamp=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks.ToString()}
        if ($stamp -ne $state.SettingsStamp) {$state.SettingsStamp=$stamp;& $refreshServers}
        & $refreshRuns
        & $updateTextPath
        if(-not $busy -and $state.DiscoveryPending){
            $state.DiscoveryPending=$false;$discoveryPath=Join-Path $infraRuntime 'infra-runs\infra-discovery.json'
            if(Test-Path -LiteralPath $discoveryPath){
                $detected=Get-Content -LiteralPath $discoveryPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach($prop in $detected.Servers.PSObject.Properties){$server=@((Get-InfrastructureSettings).Servers | Where-Object Alias -eq $prop.Name);if($server.Count){Show-InfrastructureDiscoverySelection -Owner $Form -Server $server[0] -Discovery $prop.Value}}
                & $refreshServers
            }
        }
    }.GetNewClosure())
    $timer.Start(); $Form.Add_FormClosed({$timer.Stop();$timer.Dispose()}.GetNewClosure())
}
