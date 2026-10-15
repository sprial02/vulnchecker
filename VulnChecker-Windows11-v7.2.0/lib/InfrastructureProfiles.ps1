function Get-InfrastructureProfileCatalog {
    $parsed=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\infrastructure\profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($parsed)
}

function Get-InfrastructureServerProfiles {
    param($Server)
    if ($Server.PSObject.Properties['Profiles']) {return @($Server.Profiles)}
    $profile='windows';if ($Server.Connection -eq 'ssh') {$profile=@{Auto='unix-debian';Debian='unix-debian';RedHat='unix-redhat';AIX='unix-aix';'HP-UX'='unix-hpux';Solaris='unix-solaris'}[[string]$Server.Platform]}
    return @([pscustomobject]@{Id='os';Profile=$profile;Root='';RunAs='';Bash='/bin/bash';Python='/usr/bin/python3';DbHost='localhost';DbPort=3306;DbName='';DbUser='';DbPassword=''})
}

function Save-InfrastructureServerProfiles {
    param([string]$Alias,[object[]]$Profiles)
    $settings=Get-InfrastructureSettings;$server=@($settings.Servers | Where-Object Alias -eq $Alias)[0]
    if (-not $Profiles.Count) {throw '점검 구성을 하나 이상 등록하세요.'}
    $old=@(Get-InfrastructureServerProfiles $server);$catalog=@(Get-InfrastructureProfileCatalog);$saved=@();$ids=@{};$scopes=@{}
    foreach ($row in $Profiles) {
        if ($row.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' -or $ids.ContainsKey($row.Id)) {throw '인스턴스 ID는 중복 없는 영문·숫자·점·하이픈으로 입력하세요.'};$ids[$row.Id]=$true
        $spec=@($catalog | Where-Object Id -eq $row.Profile)
        if ($spec.Count -ne 1 -or (($server.Connection -eq 'ssh') -ne ($spec[0].Family -eq 'posix'))) {throw '점검 종류와 서버 접속 방식이 다릅니다. MSSQL 원본은 Bash/SSH 실행 환경이 필요합니다.'}
        $data=@{}
        if($row.Id -eq 'os' -and $spec[0].Category -notin @('Unix OS','Windows OS','PC')) {throw 'os ID는 운영체제 점검에만 사용할 수 있습니다.'}
        foreach ($key in @('Id','Profile','Root','RunAs','Bash','Python','DbHost','DbPort','DbName','DbUser')) {$data[$key]=$row.$key}
        if ($spec[0].Family -eq 'posix') {
            foreach ($key in @('Root','Bash','Python')) {if ($data[$key] -and $data[$key] -notmatch '^/[A-Za-z0-9_./-]+$') {throw "$key 값은 공백 없는 Unix 절대 경로로 입력하세요."}}
            if ($data.RunAs -and $data.RunAs -notmatch '^[A-Za-z_][A-Za-z0-9_.-]*$') {throw 'Unix 실행 계정을 확인하세요.'}
        }
        $before=@($old | Where-Object Id -eq $row.Id)
        $password=[string]$row.DbPassword
        if ($password -match '[\r\n\x00]') {throw 'DB 암호에 줄바꿈을 넣을 수 없습니다.'}
        $data.DbPassword=''
        if ($password) {$data.DbPassword=ConvertFrom-SecureString (ConvertTo-SecureString $password -AsPlainText -Force)}
        elseif ($before.Count -and $before[0].Profile -eq $row.Profile) {$data.DbPassword=[string]$before[0].DbPassword}
        if ($spec[0].Category -eq 'DBMS' -and (-not $data.DbUser -or -not $data.DbPassword -or $data.DbHost -notmatch '^[A-Za-z0-9:_.-]+$' -or [int]$data.DbPort -lt 1 -or [int]$data.DbPort -gt 65535)) {throw 'DB 주소·포트·점검 계정·암호를 저장하세요.'}
        $scope=$row.Profile+'|'+$row.Root
        if ($spec[0].Category -eq 'DBMS') {$scope=$row.Profile+'|'+$row.DbHost+'|'+$row.DbPort+'|'+$row.DbName}
        if ($scopes.ContainsKey($scope)) {throw '동일한 점검 범위를 중복 등록할 수 없습니다. 여러 WAS는 서로 다른 설치 경로를 지정하세요.'};$scopes[$scope]=$true
        if ($row.Profile -eq 'iis' -and $row.Root) {throw 'IIS 원본은 서버 전체 IIS 구성을 점검합니다. 설치 경로는 비워 두세요.'}
        $saved+=[pscustomobject]$data
    }
    $server | Add-Member -MemberType NoteProperty -Name Profiles -Value @($saved) -Force
    $unix=@($saved | Where-Object Profile -like 'unix-*')
    if($unix.Count -gt 1){throw '하나의 서버에는 Unix OS 점검 종류를 하나만 등록하세요.'}
    if($unix.Count){$server.Platform=@{'unix-debian'='Debian';'unix-redhat'='RedHat';'unix-aix'='AIX';'unix-hpux'='HP-UX';'unix-solaris'='Solaris'}[$unix[0].Profile]}
    Write-AtomicText -Path (Join-Path $script:Runtime 'infra-settings.json') -Text ($settings | ConvertTo-Json -Depth 12)
}

function Show-InfrastructureProfileEditor {
    param($Owner,$Server,[object[]]$InitialProfiles)
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='InfraProfileEditor';$dialog.Text='점검 구성 · '+$Server.Alias;$dialog.ClientSize=New-Object Drawing.Size(960,580);$dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.Font=$Owner.Font
    $listBox=New-Object Windows.Forms.ListBox;$listBox.Name='ProfileInstances';$listBox.SetBounds(12,12,270,470);$listBox.DisplayMember='Display';$dialog.Controls.Add($listBox)
    $state=@{Loading=$false;Rows=@(Get-InfrastructureServerProfiles $Server);Current=-1}
    if($PSBoundParameters.ContainsKey('InitialProfiles')){$state.Rows=@($InitialProfiles)}
    $state.Rows=@(foreach($r in $state.Rows){$copy=@{};foreach($p in $r.PSObject.Properties){$copy[$p.Name]=$p.Value};$copy.DbPassword='';[pscustomobject]$copy})
    $catalog=@(Get-InfrastructureProfileCatalog | Where-Object {($_.Family -eq 'posix') -eq ($Server.Connection -eq 'ssh')})
    $groups=@{}
    foreach ($layout in @(@('target','점검 종류와 인스턴스',300,12,645,110),@('web','웹 / WAS 설치 범위',300,134,645,84),@('db','DBMS 접속 정보 · SSH 계정과 별도',300,230,645,145),@('exec','Unix 실행 환경 · 대상 서버에 Bash / Python 3 필요',300,387,645,120))) {
        $group=New-Object Windows.Forms.GroupBox;$group.Text=$layout[1];$group.SetBounds($layout[2],$layout[3],$layout[4],$layout[5]);$dialog.Controls.Add($group);$groups[$layout[0]]=$group
    }
    $fields=@{}
    $make={param($parent,$name,$label,$x,$y,$width)
        $l=New-Object Windows.Forms.Label;$l.Text=$label;$l.SetBounds($x,$y+3,100,24);$parent.Controls.Add($l)
        $box=New-Object Windows.Forms.TextBox;$box.Name=$name;$box.SetBounds($x+105,$y,$width,26);$parent.Controls.Add($box);$fields[$name]=$box
    }.GetNewClosure()
    & $make $groups.target 'Id' '인스턴스 ID' 12 70 200
    $combo=New-Object Windows.Forms.ComboBox;$combo.Name='ProfileChoice';$combo.DropDownStyle='DropDownList';$combo.DisplayMember='Label';$combo.SetBounds(117,28,505,28);$groups.target.Controls.Add($combo);[void]$combo.Items.AddRange([object[]]$catalog);$combo.SelectedIndex=0
    $note=New-Object Windows.Forms.Label;$note.SetBounds(345,72,280,25);$note.Text='예: os / tomcat-prod / mysql-prod';$groups.target.Controls.Add($note)
    & $make $groups.web 'Root' '설치 루트' 12 30 505
    foreach ($row in @(@('DbHost','DB 주소',12,28,200),@('DbPort','DB 포트',335,28,175),@('DbUser','DB 계정',12,64,200),@('DbPassword','DB 암호',335,64,175),@('DbName','DB명 / SID',12,100,200))) {& $make $groups.db $row[0] $row[1] $row[2] $row[3] $row[4]}
    $fields.DbPassword.UseSystemPasswordChar=$true
    foreach ($row in @(@('RunAs','실행 계정',12,28,200),@('Bash','Bash 경로',335,28,175),@('Python','Python 3 경로',12,64,505))) {& $make $groups.exec $row[0] $row[1] $row[2] $row[3] $row[4]}
    $update={
        if (-not $combo.SelectedItem) {return}
        $spec=$combo.SelectedItem;$groups.db.Enabled=$spec.Category -eq 'DBMS';$groups.web.Enabled=$spec.Category -in @('Web','DBMS') -and $spec.Family -eq 'posix';$groups.exec.Enabled=$spec.Family -eq 'posix'
        $groups.web.Text='설치 범위 / Oracle Home · 비우면 원본의 기본 경로 검색'
        if (-not $state.Loading -and $spec.PSObject.Properties['DbPort']) {$fields.DbPort.Text=[string]$spec.DbPort}
    }.GetNewClosure();$combo.Add_SelectedIndexChanged($update)
    $refresh={
        $listBox.Items.Clear()
        foreach ($row in $state.Rows) {$match=@($catalog | Where-Object Id -eq $row.Profile);$label=$row.Profile;if($match.Count){$label=$match[0].Label};[void]$listBox.Items.Add([pscustomobject]@{Display=$row.Id+' · '+$label;Data=$row})}
    }.GetNewClosure()
    $clear={
        $state.Current=-1;$state.Loading=$true;foreach ($f in $fields.Values) {$f.Clear()};$fields.Id.Text='instance-'+($state.Rows.Count+1);$fields.DbHost.Text='localhost';$fields.DbPort.Text='3306';$fields.Bash.Text='/bin/bash';$fields.Python.Text='/usr/bin/python3';$state.Loading=$false;& $update
    }.GetNewClosure()
    $listBox.Add_SelectedIndexChanged({
        if (-not $listBox.SelectedItem) {return}
        $state.Loading=$true;$state.Current=$listBox.SelectedIndex;$row=$listBox.SelectedItem.Data
        foreach ($key in $fields.Keys) {$fields[$key].Text=[string]$row.$key};$fields.DbPassword.Clear()
        foreach ($spec in $catalog) {if ($spec.Id -eq $row.Profile) {$combo.SelectedItem=$spec;break}}
        $state.Loading=$false;& $update
    }.GetNewClosure())
    $actions=@(
      @{Text='새 구성';X=12;W=85;Click=$clear},
      @{Text='구성 삭제';X=105;W=100;Click={if ($state.Current -ge 0) {$i=$state.Current;$state.Rows=@(for($n=0;$n -lt $state.Rows.Count;$n++){if($n-ne$i){$state.Rows[$n]}});& $refresh;& $clear}}.GetNewClosure()},
      @{Text='구성 적용';X=300;W=125;Click={
        $data=@{Profile=$combo.SelectedItem.Id};foreach($key in $fields.Keys){$data[$key]=$fields[$key].Text.Trim()};$data.DbPassword=$fields.DbPassword.Text
        if ($state.Current -ge 0) {if (-not $data.DbPassword) {$data.DbPassword=$state.Rows[$state.Current].DbPassword};$state.Rows[$state.Current]=[pscustomobject]$data}
        else {$state.Rows+=,[pscustomobject]$data}
        & $refresh;& $clear
      }.GetNewClosure()},
      @{Text='전체 저장';X=750;W=100;Click={
        # Existing encrypted secrets are restored through the save function, not displayed.
        if($state.Current -ge 0){
          $data=@{Profile=$combo.SelectedItem.Id};foreach($key in $fields.Keys){$data[$key]=$fields[$key].Text.Trim()};$data.DbPassword=$fields.DbPassword.Text
          if(-not $data.DbPassword){$data.DbPassword=$state.Rows[$state.Current].DbPassword};$state.Rows[$state.Current]=[pscustomobject]$data
        }
        $rows=$state.Rows
        Save-InfrastructureServerProfiles -Alias $Server.Alias -Profiles $rows;$dialog.DialogResult='OK';$dialog.Close()
      }.GetNewClosure()},
      @{Text='닫기';X=860;W=85;Click={$dialog.Close()}.GetNewClosure()}
    )
    foreach ($action in $actions){$button=New-Object Windows.Forms.Button;$button.Text=$action.Text;$button.SetBounds($action.X,530,$action.W,32);$button.Tag=$action.Click;$button.Add_Click({try{& $this.Tag}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'점검 구성')|Out-Null}});$dialog.Controls.Add($button)}
    & $refresh;& $clear;if($listBox.Items.Count){$listBox.SelectedIndex=0}
    try{return $dialog.ShowDialog($Owner)}finally{$dialog.Dispose()}
}

function Show-InfrastructureDiscoverySelection {
    param($Owner,$Server,$Discovery)
    $catalog=@(Get-InfrastructureProfileCatalog)
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='InfraDiscoverySelection';$dialog.Text='자동 감지 · 점검 대상 선택 · '+$Server.Alias;$dialog.ClientSize=New-Object Drawing.Size(830,480);$dialog.StartPosition='CenterParent';$dialog.Font=$Owner.Font
    $hint=New-Object Windows.Forms.Label;$hint.Text='실행할 대상을 선택하세요. DBMS는 다음 창에서 별도 DB 계정·암호를 입력합니다.';$hint.SetBounds(12,12,806,40);$dialog.Controls.Add($hint)
    $list=New-Object Windows.Forms.CheckedListBox;$list.Name='DetectedTargets';$list.CheckOnClick=$true;$list.HorizontalScrollbar=$true;$list.DisplayMember='Label';$list.SetBounds(12,58,806,260);$dialog.Controls.Add($list)
    foreach($candidate in @($Discovery.Candidates)){$spec=@($catalog | Where-Object Id -eq $candidate.Profile);$label=$candidate.Profile;if($spec.Count){$label=$spec[0].Label};$index=$list.Items.Add([pscustomobject]@{Label=$label+' · '+$candidate.Id+' · '+$candidate.Evidence;Data=$candidate});$list.SetItemChecked($index,[bool]$candidate.Ready)}
    $notes=New-Object Windows.Forms.TextBox;$notes.Multiline=$true;$notes.ReadOnly=$true;$notes.ScrollBars='Vertical';$notes.Text=@($Discovery.Notes)-join "`r`n";$notes.SetBounds(12,330,806,90);$dialog.Controls.Add($notes)
    $next=New-Object Windows.Forms.Button;$next.Text='선택 대상 구성 / 저장';$next.SetBounds(570,436,248,32);$next.Add_Click({if(-not $list.CheckedItems.Count){[void][Windows.Forms.MessageBox]::Show('하나 이상 선택하세요.');return};$dialog.DialogResult='OK';$dialog.Close()}.GetNewClosure());$dialog.Controls.Add($next)
    try{if($dialog.ShowDialog($Owner) -eq 'OK'){$rows=@($list.CheckedItems | ForEach-Object {$_.Data});[void](Show-InfrastructureProfileEditor -Owner $Owner -Server $Server -InitialProfiles $rows)}}finally{$dialog.Dispose()}
}
