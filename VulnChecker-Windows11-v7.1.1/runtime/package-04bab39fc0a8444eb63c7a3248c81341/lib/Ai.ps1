function Get-AiModelIds {
    return @('ibm-ica/gemini-3.1-pro-preview','ibm-ica/claude-sonnet-4-6','ibm-ica/claude-sonnet-5','deepseek/deepseek-flash','deepseek/deepseek-v4-pro')
}

function Get-AiSettings {
    $path=Join-Path $script:Runtime 'ai-settings.json'
    if (Test-Path -LiteralPath $path) {return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)}
    return [pscustomobject]@{Model=(Get-AiModelIds)[0];IbmKey='';DeepSeekKey=''}
}

function Save-AiSettings {
    param([string]$Model,[string]$IbmKey,[string]$DeepSeekKey,[switch]$RemoveIbm,[switch]$RemoveDeepSeek)
    if ($Model -notin (Get-AiModelIds)) {throw '지원하는 AI 모델을 선택하세요.'}
    $saved=Get-AiSettings
    $data=@{Model=$Model;IbmKey=[string]$saved.IbmKey;DeepSeekKey=[string]$saved.DeepSeekKey}
    foreach ($pair in @(@('IbmKey',$IbmKey),@('DeepSeekKey',$DeepSeekKey))) {
        $value=$pair[1].Trim()
        if ($value -match '[\r\n\x00]') {throw 'API 키에 줄바꿈을 넣을 수 없습니다.'}
        if ($value) {$data[$pair[0]]=ConvertFrom-SecureString (ConvertTo-SecureString $value -AsPlainText -Force)}
    }
    if ($RemoveIbm) {$data.IbmKey=''}
    if ($RemoveDeepSeek) {$data.DeepSeekKey=''}
    if ($Model.StartsWith('ibm-ica/') -and -not $data.IbmKey) {throw 'IBM ICA API KEY를 입력하세요.'}
    if ($Model.StartsWith('deepseek/') -and -not $data.DeepSeekKey) {throw 'DEEPSEEK API KEY를 입력하세요.'}
    Write-AtomicText -Path (Join-Path $script:Runtime 'ai-settings.json') -Text ($data | ConvertTo-Json)
}

function Get-AiPlainKey {
    param([string]$Encrypted)
    if (-not $Encrypted) {return ''}
    $secure=ConvertTo-SecureString $Encrypted
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}
    finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $secure.Dispose()}
}

function Set-OpenCodeAi {
    param($Runtime)
    $saved=Get-AiSettings
    if (-not $saved.IbmKey -and -not $saved.DeepSeekKey) {throw 'AI 설정 탭에서 IBM ICA API KEY를 먼저 저장하세요.'}
    $payload=@{model=$saved.Model;ibmKey=(Get-AiPlainKey $saved.IbmKey);deepseekKey=(Get-AiPlainKey $saved.DeepSeekKey)} | ConvertTo-Json
    $helper=Get-Content -LiteralPath (Join-Path $script:Root 'scripts\configure-ai.py') -Raw -Encoding UTF8
    Invoke-Kali -Arguments @('tee',"$($Runtime.Home)/tools/vulnchecker/configure-ai.py") -InputText $helper -Quiet | Out-Null
    try {
        Invoke-Kali -Arguments @($Runtime.HexPython,"$($Runtime.Home)/tools/vulnchecker/configure-ai.py","$($Runtime.Work)/opencode.json","$($Runtime.Home)/.config/vulnchecker/credentials") -InputText $payload -Quiet | Out-Null
    } finally {$payload=$null}
    Set-ConnectionResult 'OpenCode AI 설정' '설정됨' ("기본 모델: $($saved.Model). 실제 API 응답은 첫 요청에서 확인합니다. 토큰 소진 시 /models에서 DeepSeek 선택.")
}
