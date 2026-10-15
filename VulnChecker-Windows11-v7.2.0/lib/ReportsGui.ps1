function Add-ReportsTab {
    param($Tabs,$Gui,$Status,$Buttons,$Form)
    $page=New-Object Windows.Forms.TabPage; $page.Text='⑧ 레포트';$page.Name='ReportsTab';$Tabs.TabPages.Add($page)
    $settings=Get-ReportSettings
    $customerLabel=New-Object Windows.Forms.Label;$customerLabel.Text='고객사명';$customerLabel.SetBounds(12,14,70,24);$page.Controls.Add($customerLabel)
    $customer=New-Object Windows.Forms.TextBox;$customer.Name='ReportCustomer';$customer.SetBounds(85,11,275,26);$customer.Text=$settings.Customer;$page.Controls.Add($customer)
    $authorLabel=New-Object Windows.Forms.Label;$authorLabel.Text='작성 담당';$authorLabel.SetBounds(380,14,80,24);$page.Controls.Add($authorLabel)
    $author=New-Object Windows.Forms.TextBox;$author.Name='ReportAuthor';$author.SetBounds(463,11,170,26);$author.Text=$settings.Author;$page.Controls.Add($author)
    $periodLabel=New-Object Windows.Forms.Label;$periodLabel.Text='점검 기간';$periodLabel.SetBounds(650,14,80,24);$page.Controls.Add($periodLabel)
    $period=New-Object Windows.Forms.TextBox;$period.Name='ReportPeriod';$period.SetBounds(733,11,217,26);$period.Text=$settings.Period;$page.Controls.Add($period)
    $scopeLabel=New-Object Windows.Forms.Label;$scopeLabel.Text='대상 범위';$scopeLabel.SetBounds(12,48,70,24);$page.Controls.Add($scopeLabel)
    $scope=New-Object Windows.Forms.TextBox;$scope.Name='ReportScope';$scope.SetBounds(85,45,548,26);$scope.Text=$settings.Scope;$page.Controls.Add($scope)
    $limitLabel=New-Object Windows.Forms.Label;$limitLabel.Text='본문 상세';$limitLabel.SetBounds(650,48,80,24);$page.Controls.Add($limitLabel)
    $limit=New-Object Windows.Forms.NumericUpDown;$limit.Name='ReportDetailLimit';$limit.SetBounds(733,45,70,26);$limit.Minimum=1;$limit.Maximum=200;$limit.Value=$settings.DetailLimit;$page.Controls.Add($limit)
    $images=New-Object Windows.Forms.CheckBox;$images.Name='ReportIncludeImages';$images.Text='증적 이미지 포함';$images.SetBounds(816,44,145,26);$images.Checked=$settings.IncludeImages;$page.Controls.Add($images)
    $kind=New-Object Windows.Forms.ComboBox;$kind.Name='ReportKind';$kind.DropDownStyle='DropDownList';$kind.SetBounds(12,80,210,28)
    [void]$kind.Items.AddRange(@('모바일 앱','웹서버','인프라 서버 / 네트워크'));$page.Controls.Add($kind)
    $kind.SelectedIndex=@{mobile=0;web=1;infra=2}[[string]$settings.Kind]
    $source=New-Object Windows.Forms.ComboBox;$source.Name='ReportSource';$source.DropDownStyle='DropDownList';$source.DisplayMember='Label';$source.SetBounds(235,80,715,28);$page.Controls.Add($source)
    $grid=New-Object Windows.Forms.DataGridView;$grid.Name='ReportResults';$grid.SetBounds(12,155,938,65);$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.RowHeadersVisible=$false;$grid.AutoSizeColumnsMode='Fill'
    foreach ($column in @(@('asset','자산'),@('item_id','항목'),@('title','점검 항목명'),@('status','판정'),@('severity','위험도'))) {[void]$grid.Columns.Add($column[0],$column[1])}
    $page.Controls.Add($grid)
    $hint=New-Object Windows.Forms.Label;$hint.Name='ReportSummary';$hint.Text='RAW ZIP에는 원본 증적이 포함됩니다. 고객 전달 전 민감정보를 확인하세요.';$hint.SetBounds(12,225,628,30);$hint.AutoEllipsis=$true;$page.Controls.Add($hint)
    $state=@{Catalog='';Preview='';Sources=@();Offset=0;Selected=''}
    $currentKind={@('mobile','web','infra')[$kind.SelectedIndex]}.GetNewClosure()
    $begin={
        param($tool,$request)
        if ($Gui.Process -and -not $Gui.Process.HasExited) {throw '진행 중인 작업이 끝난 뒤 실행하세요.'}
        $Gui.Started=Get-Date;$Gui.LastAction='Report'
        $Gui.Process=Start-Worker -Action Report -Tool $tool -Target ($request | ConvertTo-Json -Depth 8 -Compress)
        $Status.Text='보고서 작업 진행 중 · 결과 집계와 문서 생성을 준비합니다.'
    }.GetNewClosure()
    $refreshSources={
        $old='';if ($source.SelectedItem) {$old=$source.SelectedItem.Id}
        $source.Items.Clear()
        foreach ($row in @($state.Sources | Where-Object {$_.kind -eq (& $currentKind)})) {
            $vulnerable=0;if ($row.counts.PSObject.Properties['VULNERABLE']) {$vulnerable=$row.counts.VULNERABLE}
            $units='자산 '+$row.assets;if($row.kind -eq 'infra' -and $row.PSObject.Properties['physical_assets']){$units='서버 '+$row.physical_assets+'대 / 점검 대상 '+$row.assets+'개'}
            $label=$row.name+' · '+$units+' · 취약 '+$vulnerable
            $entry=[pscustomobject]@{Id=$row.id;Label=$label;Stats=$row};[void]$source.Items.Add($entry)
            if ($entry.Id -eq $old) {$source.SelectedItem=$entry}
        }
        if ($source.SelectedIndex -lt 0 -and $source.Items.Count) {$source.SelectedIndex=0}
    }.GetNewClosure()
    $updateKind={
        $infra=$kind.SelectedIndex -eq 2;$limit.Enabled=-not $infra;$images.Enabled=-not $infra
    }.GetNewClosure()
    & $updateKind
    $kind.Add_SelectedIndexChanged({$state.Offset=0;$grid.Rows.Clear();& $updateKind;& $refreshSources}.GetNewClosure())
    $source.Add_SelectedIndexChanged({
        $state.Offset=0;$state.Selected='';$state.Preview='';$grid.Rows.Clear()
        if ($source.SelectedItem) {
            $row=$source.SelectedItem.Stats;$state.Selected=$source.SelectedItem.Id
            $manual=0;if ($row.counts.PSObject.Properties['MANUAL']) {$manual=$row.counts.MANUAL}
            $format='DOCX 상세와 전체 CSV';if ($kind.SelectedIndex -eq 2) {$format='DOCX 현황표 + 서버×항목 Excel 결과표'}
            $units='자산 '+$row.assets;if($kind.SelectedIndex -eq 2 -and $row.PSObject.Properties['physical_assets']){$units='서버 '+$row.physical_assets+'대 / 대상 '+$row.assets+'개'}
            $hint.Text=$units+' · 수행 실패 '+$row.failed_assets+' · 결과 합계 '+$row.total_checks+' · 수동 확인 '+$manual+' · '+$format
        }
    }.GetNewClosure())
    $actions=@(
        @{Name='ReportSync';Text='결과 동기화';X=12;W=116;Click={& $begin 'ReportSync' @{}}.GetNewClosure()},
        @{Name='ReportImport';Text='JSON 가져오기';X=136;W=120;Click={
            $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='점검 결과 JSON (*.json)|*.json'
            try {if ($dialog.ShowDialog() -eq 'OK') {& $begin 'ReportImport' @{Kind=(& $currentKind);File=$dialog.FileName}}} finally {$dialog.Dispose()}
        }.GetNewClosure()},
        @{Name='ReportPreview';Text='항목 조회';X=264;W=100;Click={if (-not $source.SelectedItem) {throw '결과를 먼저 선택하세요.'};& $begin 'ReportPreview' @{SourceId=$source.SelectedItem.Id;Offset=$state.Offset}}.GetNewClosure()},
        @{Name='ReportNext';Text='다음 100건';X=372;W=104;Click={if (-not $source.SelectedItem) {throw '결과를 먼저 선택하세요.'};if ($grid.Rows.Count -lt 100) {$state.Offset=0} else {$state.Offset+=100};& $begin 'ReportPreview' @{SourceId=$source.SelectedItem.Id;Offset=$state.Offset}}.GetNewClosure()},
        @{Name='ReportExport';Text='DOCX 추출';X=484;W=110;Click={
            if (-not $customer.Text.Trim()) {throw '고객사명을 입력하세요.'};if (-not $source.SelectedItem) {throw '점검 결과를 선택하세요.'}
            & $begin 'ReportExport' @{Customer=$customer.Text.Trim();Author=$author.Text.Trim();Period=$period.Text.Trim();Scope=$scope.Text.Trim();Kind=(& $currentKind);SourceId=$source.SelectedItem.Id;DetailLimit=[int]$limit.Value;IncludeImages=$images.Checked}
        }.GetNewClosure()},
        @{Name='ReportTemplates';Text='3종 서식 추출';X=602;W=120;Click={& $begin 'ReportTemplates' @{Customer=$customer.Text.Trim();Author=$author.Text.Trim();Period=$period.Text.Trim();Scope=$scope.Text.Trim();Kind=(& $currentKind);DetailLimit=[int]$limit.Value;IncludeImages=$false}}.GetNewClosure()},
        @{Name='ReportFolder';Text='보고서 폴더';X=730;W=115;Click={
            $path=Join-Path (Split-Path $Gui.Connections) 'reports';New-Item -ItemType Directory -Path $path -Force | Out-Null
            Start-Process explorer.exe -ArgumentList ('"'+$path+'"') | Out-Null
        }.GetNewClosure()},
        @{Name='ReportRefresh';Text='목록 갱신';X=853;W=97;Click={& $begin 'ReportRefresh' @{}}.GetNewClosure()},
        @{Name='ReportRawExport';Text='선택 RAW ZIP 저장';X=650;Y=225;W=150;Click={
            if (-not $source.SelectedItem) {throw '점검 결과를 먼저 선택하세요.'}
            & $begin 'ReportRawExport' @{SourceId=$source.SelectedItem.Id}
        }.GetNewClosure()},
        @{Name='ReportRawFolder';Text='RAW 보관함';X=810;Y=225;W=140;Click={
            $path=Join-Path (Split-Path $Gui.Connections) 'raw-data';New-Item -ItemType Directory -Path $path -Force | Out-Null
            Start-Process explorer.exe -ArgumentList ('"'+$path+'"') | Out-Null
            $exports=Join-Path (Split-Path $Gui.Connections) 'raw-exports'
            if (Test-Path -LiteralPath $exports) {Start-Process explorer.exe -ArgumentList ('"'+$exports+'"') | Out-Null}
        }.GetNewClosure()}
    )
    foreach ($action in $actions) {
        $y=117;if ($action.ContainsKey('Y')) {$y=$action.Y}
        $button=New-Object Windows.Forms.Button;$button.Name=$action.Name;$button.Text=$action.Text;$button.SetBounds($action.X,$y,$action.W,30);$button.FlatStyle='Flat';$button.Tag=@{Action='Report';Click=$action.Click}
        $button.Add_Click({try {& $this.Tag.Click} catch {[Windows.Forms.MessageBox]::Show($_.Exception.Message,'레포트') | Out-Null}})
        $page.Controls.Add($button);$Buttons.Add($button)
    }
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=1000
    $timer.Add_Tick({
        $root=Split-Path $Gui.Connections
        $catalog=Join-Path $root 'report-catalog.json'
        try {
            if (Test-Path -LiteralPath $catalog) {
                $raw=Read-SharedText $catalog
                if ($raw -ne $state.Catalog) {$state.Catalog=$raw;$parsed=$raw | ConvertFrom-Json;$state.Sources=@($parsed);& $refreshSources}
            }
            $preview=Join-Path $root 'report-preview.json'
            if (Test-Path -LiteralPath $preview) {
                $raw=Read-SharedText $preview
                if ($raw -ne $state.Preview) {
                    $data=$raw | ConvertFrom-Json
                    if ($data.source_id -eq $state.Selected -and $data.offset -eq $state.Offset) {
                        $state.Preview=$raw;$grid.Rows.Clear()
                        foreach ($row in $data.rows) {[void]$grid.Rows.Add($row.asset,$row.item_id,$row.title,$row.status,$row.severity)}
                    }
                }
            }
        } catch {}
    }.GetNewClosure())
    $timer.Start();$Form.Add_FormClosed({$timer.Stop();$timer.Dispose()}.GetNewClosure())
}
