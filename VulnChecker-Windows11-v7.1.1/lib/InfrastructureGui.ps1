function Add-InfrastructureTab {
    param($Tabs,$Gui,$Status,$Buttons,$Form)
    $infraRoot=$script:Root; $infraRuntime=$script:Runtime
    $page=New-Object Windows.Forms.TabPage; $page.Text='⑦ 인프라 점검'; $page.Name='InfrastructureTab'; $Tabs.TabPages.Add($page)
    $sub=New-Object Windows.Forms.TabControl; $sub.Dock='Fill'; $page.Controls.Add($sub)
    $serversPage=New-Object Windows.Forms.TabPage; $serversPage.Text='서버 등록 / 실행'; $sub.TabPages.Add($serversPage)
    $resultsPage=New-Object Windows.Forms.TabPage; $resultsPage.Text='점검 결과 / 재실행'; $sub.TabPages.Add($resultsPage)
    $fields=@{}; $state=@{Loading=$false;SettingsStamp='';RunsStamp=''}
    $serverList=New-Object Windows.Forms.ListBox; $serverList.Name='InfrastructureServers'; $serverList.DisplayMember='Label'; $serverList.SelectionMode='MultiExtended'; $serverList.SetBounds(12,8,218,125); $serversPage.Controls.Add($serverList)
    $makeLabel={param($text,$x,$y,$width) $label=New-Object Windows.Forms.Label; $label.Text=$text; $label.SetBounds($x,$y,$width,24); $serversPage.Controls.Add($label)}
    foreach ($row in @(@('Alias','서버 이름',250,8,320,210),@('Host','주소',550,8,610,330),@('User','계정',550,39,610,330),@('Password','접속 암호',250,101,320,210),@('BecomePassword','sudo 암호',550,101,650,290),@('KeyFile','SSH 키',250,132,320,620))) {
        & $makeLabel $row[1] $row[2] ($row[3]+3) ($row[4]-$row[2]-4)
        $box=New-Object Windows.Forms.TextBox; $box.Name=('Infra'+$row[0]); $box.SetBounds($row[4],$row[3],$row[5],26)
        if ($row[0] -in @('Password','BecomePassword')) {$box.UseSystemPasswordChar=$true}
        $fields[$row[0]]=$box; $serversPage.Controls.Add($box)
    }
    & $makeLabel '서버 종류' 250 42 68
    $kind=New-Object Windows.Forms.ComboBox; $kind.Name='InfraKind'; $kind.DropDownStyle='DropDownList'; $kind.SetBounds(320,39,210,26); [void]$kind.Items.AddRange(@('Linux · Debian (SSH)','Linux · RedHat (SSH)','Windows · WinRM','Windows · PSRP')); $kind.SelectedIndex=0; $serversPage.Controls.Add($kind)
    & $makeLabel '포트' 250 73 68
    $port=New-Object Windows.Forms.NumericUpDown; $port.Name='InfraPort'; $port.Minimum=1; $port.Maximum=65535; $port.Value=22; $port.SetBounds(320,70,78,26); $serversPage.Controls.Add($port)
    $protocol=New-Object Windows.Forms.ComboBox; $protocol.Name='InfraProtocol'; $protocol.DropDownStyle='DropDownList'; $protocol.SetBounds(408,70,122,26); [void]$protocol.Items.AddRange(@('HTTPS','HTTP')); $protocol.SelectedIndex=0; $serversPage.Controls.Add($protocol)
    & $makeLabel '제한(초)' 550 73 97
    $timeout=New-Object Windows.Forms.NumericUpDown; $timeout.Name='InfraTimeout'; $timeout.Minimum=10; $timeout.Maximum=3600; $timeout.Value=90; $timeout.SetBounds(650,70,86,26); $serversPage.Controls.Add($timeout)
    $enabled=New-Object Windows.Forms.CheckBox; $enabled.Name='InfraEnabled'; $enabled.Text='전체 점검에 포함'; $enabled.Checked=$true; $enabled.SetBounds(754,70,186,26); $serversPage.Controls.Add($enabled)
    $trust=New-Object Windows.Forms.CheckBox; $trust.Name='InfraTrustNewHostKey'; $trust.Text='최초 SSH 키 등록'; $trust.SetBounds(250,163,230,24); $serversPage.Controls.Add($trust)
    $hint=New-Object Windows.Forms.Label; $hint.Name='InfraCredentialHint'; $hint.Text='암호 빈칸 = 저장값 유지 · sudo 미등록 = 접속 암호'; $hint.SetBounds(490,165,450,23); $hint.AutoEllipsis=$true; $serversPage.Controls.Add($hint)
    $updateKind={
        $linux=$kind.SelectedIndex -lt 2
        $fields.KeyFile.Enabled=$linux; $fields.BecomePassword.Enabled=$linux; $trust.Enabled=$linux; $protocol.Enabled=-not $linux
    }.GetNewClosure()
    $kind.Add_SelectedIndexChanged({if (-not $state.Loading) {if ($kind.SelectedIndex -lt 2) {$port.Value=22} else {$port.Value=5986}; & $updateKind}}.GetNewClosure())
    $protocol.Add_SelectedIndexChanged({if (-not $state.Loading -and $kind.SelectedIndex -ge 2) {if ($protocol.SelectedIndex -eq 0) {$port.Value=5986} else {$port.Value=5985}}}.GetNewClosure())
    $newServer={
        $state.Loading=$true
        $serverList.ClearSelected()
        foreach ($box in $fields.Values) {$box.Clear()}; $fields.Alias.ReadOnly=$false
        $kind.SelectedIndex=0; $port.Value=22; $protocol.SelectedIndex=0; $timeout.Value=90; $enabled.Checked=$true; $trust.Checked=$false
        $state.Loading=$false; & $updateKind
    }.GetNewClosure()
    $serverList.Add_SelectedIndexChanged({
        if ($state.Loading -or -not $serverList.SelectedItem) {return}
        $s=$serverList.SelectedItem.Server; $state.Loading=$true
        foreach ($name in @('Alias','Host','User','KeyFile')) {$fields[$name].Text=[string]$s.$name}
        $fields.Alias.ReadOnly=$true; $fields.Password.Clear(); $fields.BecomePassword.Clear()
        $kind.SelectedIndex=0
        if ($s.Connection -eq 'ssh' -and $s.Platform -eq 'RedHat') {$kind.SelectedIndex=1}
        elseif ($s.Connection -eq 'winrm') {$kind.SelectedIndex=2} elseif ($s.Connection -eq 'psrp') {$kind.SelectedIndex=3}
        $protocol.SelectedIndex=0; if ($s.Protocol -eq 'http') {$protocol.SelectedIndex=1}
        $port.Value=[int]$s.Port; $timeout.Value=[int]$s.Timeout; $enabled.Checked=[bool]$s.Enabled; $trust.Checked=[bool]$s.TrustNewHostKey
        $saved='미등록'; if ($s.Password) {$saved='저장됨'}
        $hint.Text="접속 암호: $saved · 빈칸은 저장값 유지 / sudo 미등록=접속 암호"
        $state.Loading=$false; & $updateKind
    }.GetNewClosure())
    $refreshServers={
        $selected=@($serverList.SelectedItems | ForEach-Object {$_.Server.Alias})
        $state.Loading=$true; $serverList.Items.Clear()
        foreach ($s in @((Get-InfrastructureSettings).Servers)) {
            $label=$s.Alias+' · '+$s.Host; if (-not $s.Enabled) {$label+=' (제외)'}
            $index=$serverList.Items.Add([pscustomobject]@{Label=$label;Server=$s})
            if ($s.Alias -in $selected) {$serverList.SetSelected($index,$true)}
        }
        $state.Loading=$false
        if (-not $serverList.SelectedItems.Count -and $serverList.Items.Count) {$serverList.SelectedIndex=0}
    }.GetNewClosure()
    $saveServer={
        $connection='ssh'; $platform='Debian'; if ($kind.SelectedIndex -eq 1) {$platform='RedHat'} elseif ($kind.SelectedIndex -eq 2) {$connection='winrm'} elseif ($kind.SelectedIndex -eq 3) {$connection='psrp'}
        $scheme='https'; if ($protocol.SelectedIndex -eq 1) {$scheme='http'}
        $s=[pscustomobject]@{Alias=$fields.Alias.Text.Trim();Host=$fields.Host.Text.Trim();User=$fields.User.Text.Trim();Connection=$connection;Platform=$platform;Port=[int]$port.Value;Protocol=$scheme;Timeout=[int]$timeout.Value;Enabled=$enabled.Checked;TrustNewHostKey=$trust.Checked;KeyFile=$fields.KeyFile.Text.Trim();Password=$fields.Password.Text;BecomePassword=$fields.BecomePassword.Text}
        Save-InfrastructureServer $s
        $fields.Password.Clear(); $fields.BecomePassword.Clear(); & $refreshServers
        $serverList.ClearSelected()
        for ($index=0;$index -lt $serverList.Items.Count;$index++) {if ($serverList.Items[$index].Server.Alias -eq $s.Alias) {$serverList.SetSelected($index,$true);break}}
        $Status.Text='서버 설정 저장 완료 · 암호는 현재 Windows 계정으로 암호화됩니다.'
    }.GetNewClosure()
    $runs=New-Object Windows.Forms.ComboBox; $runs.Name='InfrastructureRunHistory'; $runs.DropDownStyle='DropDownList'; $runs.DisplayMember='Label'; $runs.SetBounds(12,8,716,27); $resultsPage.Controls.Add($runs)
    $grid=New-Object Windows.Forms.DataGridView; $grid.Name='InfrastructureResults'; $grid.SetBounds(12,43,930,140); $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.RowHeadersVisible=$false; $grid.AutoSizeColumnsMode='Fill'; $grid.SelectionMode='FullRowSelect'
    $select=New-Object Windows.Forms.DataGridViewCheckBoxColumn; $select.Name='Retry'; $select.HeaderText='선택'; $select.FillWeight=35; [void]$grid.Columns.Add($select)
    foreach ($pair in @(@('Server','서버',105),@('State','실행 상태',85),@('Good','양호',45),@('Vulnerable','취약',45),@('Manual','수동',45),@('NA','해당 없음',60),@('Errors','실패 사유',280))) {$c=New-Object Windows.Forms.DataGridViewTextBoxColumn; $c.Name=$pair[0];$c.HeaderText=$pair[1];$c.FillWeight=$pair[2];$c.ReadOnly=$true;[void]$grid.Columns.Add($c)}
    $resultsPage.Controls.Add($grid)
    $showRun={
        $grid.Rows.Clear()
        if (-not $runs.SelectedItem) {return}
        foreach ($prop in $runs.SelectedItem.Summary.servers.PSObject.Properties) {
            $r=$prop.Value; $counts=@{}; foreach ($p in $r.counts.PSObject.Properties) {$counts[$p.Name]=[int]$p.Value}
            $label='완료'; if ($r.execution_failed) {$label='실행 실패'}
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
        $Gui.Started=Get-Date; $Gui.LastAction='Infrastructure'
        $Gui.Process=Start-Worker -Action Infrastructure -Tool $tool -Target ($request | ConvertTo-Json -Compress)
        $Status.Text='인프라 작업 진행 중 · 아래 로그와 점검 결과를 확인하세요.'
    }.GetNewClosure()
    $actions=@(
        @{Name='InfraNew';Text='새 서버';X=12;Y=140;W=103;Page=$serversPage;Click=$newServer},
        @{Name='InfraSave';Text='서버 저장';X=124;Y=140;W=106;Page=$serversPage;Click=$saveServer},
        @{Name='InfraDelete';Text='서버 삭제';X=12;Y=177;W=103;Page=$serversPage;Click={if (-not $serverList.SelectedItem) {throw '삭제할 서버를 선택하세요.'}; Save-InfrastructureServer $serverList.SelectedItem.Server -Remove; & $refreshServers; & $newServer}.GetNewClosure()},
        @{Name='InfraImport';Text='기존 서버';X=124;Y=177;W=106;Page=$serversPage;Click={& $begin 'InfraImport' @{Hosts=@();RunId=''}}.GetNewClosure()},
        @{Name='InfraInstall';Text='Ansible 설치 / 확인';X=250;Y=193;W=155;Page=$serversPage;Click={& $begin 'InfraInstall' @{Hosts=@();RunId=''}}.GetNewClosure()},
        @{Name='InfraPreflight';Text='접속 / 권한 확인';X=413;Y=193;W=150;Page=$serversPage;Click={& $begin 'InfraPreflight' @{Hosts=@($serverList.SelectedItems | ForEach-Object {$_.Server.Alias});RunId=''}}.GetNewClosure()},
        @{Name='InfraRunSelected';Text='선택 서버 점검';X=571;Y=193;W=140;Page=$serversPage;Click={if (-not $serverList.SelectedItems.Count) {throw '점검할 서버를 선택하세요.'}; & $begin 'InfraRun' @{Hosts=@($serverList.SelectedItems | ForEach-Object {$_.Server.Alias});RunId=''}}.GetNewClosure()},
        @{Name='InfraRunAll';Text='전체 서버 점검';X=719;Y=193;W=125;Page=$serversPage;Click={& $begin 'InfraRun' @{Hosts=@();RunId=''}}.GetNewClosure()},
        @{Name='InfraGuide';Text='가이드';X=852;Y=193;W=90;Page=$serversPage;Click={Start-Process -FilePath (Join-Path $infraRoot 'docs\INFRASTRUCTURE.ko.html') | Out-Null}.GetNewClosure()},
        @{Name='InfraOpenResults';Text='결과 폴더 열기';X=740;Y=8;W=202;Page=$resultsPage;Click={if (-not $runs.SelectedItem) {throw '점검 이력이 없습니다.'}; Start-Process explorer.exe -ArgumentList ('"'+$runs.SelectedItem.Folder+'"') | Out-Null}.GetNewClosure()},
        @{Name='InfraRetryAll';Text='실패 서버 전체 재실행';X=12;Y=192;W=218;Page=$resultsPage;Click={if (-not $runs.SelectedItem -or -not @($runs.SelectedItem.Summary.failed_hosts).Count) {throw '이 이력에는 실행 실패 서버가 없습니다.'}; & $begin 'InfraRetry' @{Hosts=@();RunId=$runs.SelectedItem.Id}}.GetNewClosure()},
        @{Name='InfraRetrySelected';Text='선택 실패 서버 재실행';X=242;Y=192;W=218;Page=$resultsPage;Click={$grid.EndEdit();$hosts=@($grid.Rows | Where-Object {$_.Cells['Retry'].Value -and $_.Tag.Failed} | ForEach-Object {$_.Tag.Alias});if (-not $hosts.Count) {throw '실행 실패 서버의 선택 칸을 체크하세요.'}; & $begin 'InfraRetry' @{Hosts=$hosts;RunId=$runs.SelectedItem.Id}}.GetNewClosure()},
        @{Name='InfraRefreshResults';Text='결과 새로고침';X=472;Y=192;W=180;Page=$resultsPage;Click={$state.RunsStamp='';& $refreshRuns}.GetNewClosure()}
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
        foreach ($control in @($serverList,$kind,$port,$protocol,$timeout,$enabled,$trust)+@($fields.Values)) {$control.Enabled=-not $busy}
        if (-not $busy) {& $updateKind}
        $path=Join-Path $infraRuntime 'infra-settings.json'; $stamp=''
        if (Test-Path -LiteralPath $path) {$stamp=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks.ToString()}
        if ($stamp -ne $state.SettingsStamp) {$state.SettingsStamp=$stamp;& $refreshServers}
        & $refreshRuns
    }.GetNewClosure())
    $timer.Start(); $Form.Add_FormClosed({$timer.Stop();$timer.Dispose()}.GetNewClosure())
}
