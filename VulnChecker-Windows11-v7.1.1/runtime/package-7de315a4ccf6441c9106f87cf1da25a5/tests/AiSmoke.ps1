#Requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Core.psm1') -Force -DisableNameChecking
$module=Get-Module Core
& $module {
    $script:Runtime=Join-Path ([IO.Path]::GetTempPath()) ('vulnchecker-ai-test-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Runtime | Out-Null
    try {
        if ((Get-AiSettings).Model -ne 'ibm-ica/gemini-3.1-pro-preview') {throw 'Wrong default model'}
        Save-AiSettings -Model (Get-AiModelIds)[0] -IbmKey 'fixture-ibm-key' -DeepSeekKey 'fixture-deepseek-key'
        $saved=Get-AiSettings
        if ((Get-AiPlainKey $saved.IbmKey) -ne 'fixture-ibm-key') {throw 'Key decryption failed'}
        if ((Get-Content (Join-Path $script:Runtime 'ai-settings.json') -Raw).Contains('fixture-')) {throw 'Plaintext key persisted'}
        Save-AiSettings -Model 'deepseek/deepseek-flash'
        if ((Get-AiSettings).IbmKey -ne $saved.IbmKey) {throw 'Blank input erased saved key'}
        Save-AiSettings -Model 'deepseek/deepseek-flash' -RemoveIbm
        if ((Get-AiSettings).IbmKey) {throw 'Delete key failed'}
        $failed=$false
        try {Save-AiSettings -Model 'ibm-ica/claude-sonnet-5'} catch {$failed=$true}
        if (-not $failed) {throw 'Missing key accepted'}
        Write-Host 'PASS default model, encrypted keys, preserve blanks, removal and model switching'
    } finally {Remove-Item -LiteralPath $script:Runtime -Recurse -Force}
}
