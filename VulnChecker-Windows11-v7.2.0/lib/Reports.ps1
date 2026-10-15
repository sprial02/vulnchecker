function Get-ReportPython {
    $python=Join-Path $script:Runtime 'report-runtime\.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $python -PathType Leaf) {return $python}
    return $null
}

function Invoke-ReportPython {
    param([string]$File,[string[]]$Arguments=@(),[switch]$Quiet,[int]$TimeoutSeconds=0)
    $previous=$env:PYTHONIOENCODING
    try {
        $env:PYTHONIOENCODING='utf-8'
        return (Invoke-Native $File $Arguments -Quiet:$Quiet -TimeoutSeconds $TimeoutSeconds -NativeEncoding (New-Object Text.UTF8Encoding($false)))
    } finally {$env:PYTHONIOENCODING=$previous}
}

function Ensure-ReportRuntime {
    $python=Get-ReportPython
    if ($python) {
        try {Invoke-ReportPython $python @('-c','import docx,PIL,sqlite3') -Quiet -TimeoutSeconds 15 | Out-Null;return $python} catch {}
    }
    if (-not [Environment]::Is64BitOperatingSystem) {throw 'DOCX 보고서 런타임은 Windows x64를 지원합니다.'}
    $policy=Get-Content -LiteralPath (Join-Path $script:Root 'scripts\report-runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $runtime=[IO.Path]::GetFullPath((Join-Path $script:Runtime 'report-runtime'))
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $uv=Join-Path $runtime 'uv.exe'
    if (-not (Test-Path -LiteralPath $uv -PathType Leaf)) {
        Write-Log 'DOCX 보고서 전용 Python 도구를 자동 다운로드합니다. WSL이나 Word 설치는 필요하지 않습니다.'
        $wheel=Join-Path $runtime 'uv.whl'
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $policy.uvWheel -OutFile $wheel -UseBasicParsing
        if ((Get-FileHash -LiteralPath $wheel -Algorithm SHA256).Hash.ToLowerInvariant() -ne $policy.uvSha256) {throw '보고서 런타임 다운로드 SHA256이 일치하지 않습니다.'}
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::OpenRead($wheel)
        try {
            $entry=@($archive.Entries | Where-Object {$_.FullName -like '*.data/scripts/uv.exe'})
            if ($entry.Count -ne 1) {throw '보고서 런타임 압축 구조가 예상과 다릅니다.'}
            $temporary=$uv+'.tmp'
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry[0],$temporary,$true)
            Move-Item -LiteralPath $temporary -Destination $uv -Force
        } finally {$archive.Dispose()}
    }
    $oldInstall=$env:UV_PYTHON_INSTALL_DIR; $oldCache=$env:UV_CACHE_DIR; $oldConfig=$env:UV_NO_CONFIG
    try {
        $env:UV_PYTHON_INSTALL_DIR=Join-Path $runtime 'python'; $env:UV_CACHE_DIR=Join-Path $runtime 'cache';$env:UV_NO_CONFIG='1'
        Invoke-Native $uv @('python','install',$policy.python,'--no-bin','--no-config') | Out-Null
        $venv=[IO.Path]::GetFullPath((Join-Path $runtime '.venv'))
        if (Test-Path -LiteralPath $venv) {
            if ((Split-Path $venv) -ne $runtime -or (Split-Path $venv -Leaf) -ne '.venv') {throw '보고서 Python 복구 경로 확인 실패'}
            $backup=Join-Path $runtime ('.venv.before-repair-'+[guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $venv -Destination $backup
        }
        Invoke-Native $uv @('venv','--managed-python','--python',$policy.python,'--no-config',$venv) | Out-Null
        $python=Join-Path $venv 'Scripts\python.exe'
        Invoke-Native $uv (@('pip','install','--python',$python,'--only-binary',':all:')+@($policy.requirements)) | Out-Null
        Invoke-Native $uv @('pip','check','--python',$python) | Out-Null
        Invoke-ReportPython $python @('-c','import docx,PIL,sqlite3') -Quiet | Out-Null
        return $python
    } finally {$env:UV_PYTHON_INSTALL_DIR=$oldInstall;$env:UV_CACHE_DIR=$oldCache;$env:UV_NO_CONFIG=$oldConfig}
}

function Get-ReportSettings {
    $path=Join-Path $script:Runtime 'report-settings.json'
    $settings=[ordered]@{Customer='';Author='';Project='';Scope='';Period='';Kind='infra';IncludeImages=$false;DetailLimit=30}
    if (Test-Path -LiteralPath $path) {
        $saved=Read-SharedText $path | ConvertFrom-Json
        foreach ($key in @($settings.Keys)) {if ($saved.PSObject.Properties[$key]) {$settings[$key]=$saved.$key}}
    }
    return [pscustomobject]$settings
}

function Register-ReportWorkspace {
    param([ValidateSet('mobile','web','infra')][string]$Kind,[string]$Work)
    $rt=Get-KaliRuntime
    $path=Join-Path $script:Runtime 'report-workspaces.json'
    $entries=@();if (Test-Path -LiteralPath $path) {$parsed=Read-SharedText $path | ConvertFrom-Json;$entries=@($parsed)}
    $entries=@($entries | Where-Object {$_.Work -ne $Work})
    $entries+=[pscustomobject]@{Kind=$Kind;Work=$Work;Distro=$script:Config.kaliDistro;User=$rt.User}
    Write-AtomicText -Path $path -Text (ConvertTo-Json -InputObject @($entries) -Depth 5)
}

function Copy-ReportWorkspaceResults {
    $path=Join-Path $script:Runtime 'report-workspaces.json'
    if (-not (Test-Path -LiteralPath $path)) {return}
    $parsed=Read-SharedText $path | ConvertFrom-Json
    $sources=Join-Path $script:Runtime 'report-sources';New-Item -ItemType Directory -Path $sources -Force | Out-Null
    $wsl=Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {Write-Log 'WSL 작업 결과 동기화를 건너뜁니다. 저장된 JSON은 계속 사용할 수 있습니다.';return}
    foreach ($entry in @($parsed)) {
        if ($entry.Kind -notin @('mobile','web','infra') -or $entry.Work -notmatch '^/[^\r\n]+$') {continue}
        try {
            # Read existing results only. No scanning, installation, or analysis commands.
            $file=$entry.Work.TrimEnd('/')+'/findings.json'
            $prefix=@('-d',[string]$entry.Distro,'-u',[string]$entry.User,'--')
            $size=Invoke-Native $wsl.Source ($prefix+@('stat','-c','%s','--',$file)) -Quiet -TimeoutSeconds 15
            if ([long]$size.Trim() -gt 67108864) {throw 'findings.json은 64MB 이하로 분할하세요.'}
            $raw=Invoke-Native $wsl.Source ($prefix+@('cat','--',$file)) -Quiet -TimeoutSeconds 30
            $result=$raw | ConvertFrom-Json
            if ($result.PSObject.Properties['kind'] -and $result.kind -ne $entry.Kind) {Write-Log ('결과 종류가 달라 해당 작업의 동기화를 건너뜁니다: '+$entry.Work);continue}
            $digest=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($entry.Distro+'|'+$entry.Work))).Replace('-','').Substring(0,24)
            Write-AtomicText -Path (Join-Path $sources ($entry.Kind+'-'+$digest+'.json')) -Text $raw
        } catch {Write-Log ('구조화된 분석 결과를 읽지 못했습니다: '+$entry.Work+' / '+$_.Exception.Message)}
    }
}

function Update-ReportCatalog {
    param([string]$Python)
    Invoke-ReportPython $Python @((Join-Path $script:Root 'scripts\report-store.py'),'--db',(Join-Path $script:Runtime 'report-results.sqlite3'),'--out',(Join-Path $script:Runtime 'report-catalog.json'),'catalog') -Quiet | Out-Null
}

function Sync-InfrastructureReportDatabase {
    # Index automatically after scans once the report runtime has been prepared.
    $python=Get-ReportPython
    if (-not $python) {return}
    try {
        Invoke-ReportPython $python @((Join-Path $script:Root 'scripts\report-store.py'),'--db',(Join-Path $script:Runtime 'report-results.sqlite3'),'--out',(Join-Path $script:Runtime 'report-catalog.json'),'sync-infra','--root',(Join-Path $script:Runtime 'infra-runs')) -Quiet | Out-Null
        Sync-ReportRawLibrary $python
    } catch {Write-Log ('보고서 결과 색인 동기화 오류: '+$_.Exception.Message)}
}

function Invoke-ReportAction {
    param([string]$Tool,[string]$Target='')
    $name='보고서 준비'
    try {
        $request=@{}
        if ($Target) {$obj=$Target | ConvertFrom-Json;foreach ($p in $obj.PSObject.Properties) {$request[$p.Name]=$p.Value}}
        if ($Tool -in @('ReportExport','ReportTemplates')) {
            if ($Tool -eq 'ReportTemplates' -and -not $request.Customer) {$request.Customer='고객사명'}
            if (-not ([string]$request.Customer).Trim()) {throw '고객사명을 입력하세요.'}
            if ($request.Kind -notin @('mobile','web','infra')) {throw '보고서 종류를 선택하세요.'}
            Write-AtomicText -Path (Join-Path $script:Runtime 'report-settings.json') -Text ($request | ConvertTo-Json -Depth 8)
        }
        Set-ConnectionResult $name '진행 중' '점검 결과 집계 및 고객 보고서 준비'
        $python=Ensure-ReportRuntime
        $store=Join-Path $script:Root 'scripts\report-store.py';$db=Join-Path $script:Runtime 'report-results.sqlite3';$catalog=Join-Path $script:Runtime 'report-catalog.json'
        switch ($Tool) {
            'ReportSync' {
                Copy-ReportWorkspaceResults
                Invoke-ReportPython $python @($store,'--db',$db,'--out',$catalog,'sync-infra','--root',(Join-Path $script:Runtime 'infra-runs')) | Out-Null
                foreach ($source in @(Get-ChildItem -LiteralPath (Join-Path $script:Runtime 'report-sources') -Filter *.json -File -ErrorAction SilentlyContinue)) {
                    $kind='mobile'; if ($source.Name -like 'web-*') {$kind='web'} elseif ($source.Name -like 'infra-*') {$kind='infra'}
                    Invoke-ReportPython $python @($store,'--db',$db,'--out',$catalog,'import-json','--file',$source.FullName,'--kind',$kind) | Out-Null
                }
            }
            'ReportImport' {
                Invoke-ReportPython $python @($store,'--db',$db,'--out',$catalog,'import-json','--file',[string]$request.File,'--kind',[string]$request.Kind) | Out-Null
            }
            'ReportRefresh' {Update-ReportCatalog $python}
            'ReportRawExport' {
                if (-not $request.SourceId) {throw '점검 결과를 선택하세요.'}
                $output=Join-Path $script:Runtime 'raw-exports'
                Invoke-ReportPython $python @((Join-Path $script:Root 'scripts\report-archive.py'),'--db',$db,'--library',(Join-Path $script:Runtime 'raw-data'),'--source',[string]$request.SourceId,'--output',$output) | Out-Null
                Set-ConnectionResult $name '완료' ('선택 회차 RAW ZIP 저장 완료: '+$output+' · 원본 증적의 민감정보를 확인한 뒤 전달하세요.')
                return
            }
            'ReportPreview' {
                Invoke-ReportPython $python @($store,'--db',$db,'--out',(Join-Path $script:Runtime 'report-preview.json'),'preview','--source',[string]$request.SourceId,'--offset',[string]$request.Offset) -Quiet | Out-Null
            }
            {$_ -in @('ReportExport','ReportTemplates')} {
                $requestFile=Join-Path $script:Runtime ('report-request-'+[guid]::NewGuid().ToString('N')+'.json')
                Write-AtomicText -Path $requestFile -Text ($request | ConvertTo-Json -Depth 8)
                $output=Join-Path $script:Runtime 'reports';New-Item -ItemType Directory -Path $output -Force | Out-Null
                $args=@((Join-Path $script:Root 'scripts\report-docx.py'),'--db',$db,'--request',$requestFile,'--output',$output,'--manifest',(Join-Path $script:Runtime 'report-export.json'))
                if ($Tool -eq 'ReportTemplates') {$args+='--templates'}
                try {Invoke-ReportPython $python $args | Out-Null} finally {Remove-Item -LiteralPath $requestFile -ErrorAction SilentlyContinue}
                Set-ConnectionResult $name '완료' ('DOCX 보고서 및 부록 생성 완료: '+$output)
                return
            }
            default {throw '지원하지 않는 보고서 작업입니다.'}
        }
        if ($Tool -in @('ReportSync','ReportImport')) {Sync-ReportRawLibrary $python}
        Set-ConnectionResult $name '완료' '레포트 탭에서 결과를 선택하고 DOCX 또는 RAW ZIP으로 추출하세요.'
    } catch {Set-ConnectionResult $name '실패' $_.Exception.Message;throw}
}

function Sync-ReportRawLibrary {
    param([string]$Python)
    Invoke-ReportPython $Python @((Join-Path $script:Root 'scripts\report-archive.py'),'--db',(Join-Path $script:Runtime 'report-results.sqlite3'),'--library',(Join-Path $script:Runtime 'raw-data')) -Quiet | Out-Null
}
