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
        $script:AiStartupCalls=New-Object 'System.Collections.Generic.List[string]'
        $script:Config=[pscustomobject]@{hexstrikePort=8888}
        function script:Start-HexStrike {$script:AiStartupCalls.Add('server')}
        function script:Get-KaliRuntime {return [pscustomobject]@{HexPython='python';Home='/home/fixture';HexRepo='/repo';Work='/work';OpenCode='opencode'}}
        function script:Ensure-KaliIntegration {param($Runtime);$script:AiStartupCalls.Add('config')}
        function script:Set-OpenCodeAi {param($Runtime);$script:AiStartupCalls.Add('keys')}
        function script:Set-ConnectionResult {param($Name,$Status,$Detail)}
        function script:Write-Log {param($Message)}
        function script:Open-AnalysisTerminal {param($Kind);$script:AiStartupCalls.Add('terminal')}
        function script:Invoke-Kali {
            param($Arguments,[switch]$Quiet)
            if ($Arguments[1] -like '*/check-mcp.py') {
                $script:AiStartupCalls.Add('handshake')
                return '{"connected":true,"tools":1,"execution":true}'
            }
            $script:AiStartupCalls.Add('mcp-list')
            return 'hexstrike connected'
        }
        Start-OpenCodeIntegration
        if (($script:AiStartupCalls -join ',') -ne 'server,config,keys,handshake,mcp-list,terminal') {throw 'API keys not applied before regular OpenCode launch'}
        $script:AiStartupCalls.Clear()
        Start-OpenCodeIntegration -CheckOnly
        if (($script:AiStartupCalls -join ',') -ne 'server,config,keys,handshake,mcp-list') {throw 'API keys not applied in system/mobile preparation'}
        Write-Host 'PASS keys applied before MCP validation and terminal launch in both startup paths'
    } finally {Remove-Item -LiteralPath $script:Runtime -Recurse -Force}
}
