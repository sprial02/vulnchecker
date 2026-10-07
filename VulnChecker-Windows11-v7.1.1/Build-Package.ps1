#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$outDir=Join-Path $root 'dist'
$stage=Join-Path $root ('runtime\package-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage,$outDir -Force | Out-Null
# An explicit allowlist prevents customer data, credentials, runtime logs and caches
# from being included in a transferable package.
$files=@(
    'tests\TerminalSmoke.ps1','tests\RelaySmoke.ps1',
    'scripts\opencode-terminal.ps1','docs\DEPLOY.ko.md',
    'tests\WebRoutingSmoke.py',
    'scripts\web-relay.py',
    'tests\McpReliabilitySmoke.py',
    'scripts\hexstrike-mcp-local.py','scripts\web-tools.py','scripts\prepare-system-context.py','scripts\burp-relay.ps1',
    'Start.cmd','VulnChecker.ps1','config.json','version.json','README.md','Build-Package.ps1',
    'lib\Core.psm1','lib\Install.ps1','lib\Launch.ps1','lib\Gui.ps1','lib\Integrations.ps1','lib\Mobile.ps1','lib\MobileTargets.ps1','lib\AppAcquisition.ps1',
    'scripts\ensure-frida.py','scripts\instrument-app.py','scripts\root-bypass.js','scripts\prepare-mobile-context.py','scripts\select-mobsf-app.py','scripts\check-mobile-mcp.py','scripts\app-diagnostics.py','scripts\configure-chain.py','scripts\stop-opencode.py','scripts\configure-mobsf-frida.py',
    'lib\Inventory.ps1','scripts\kali-bootstrap.sh','scripts\kali-tools.json','scripts\hexstrike-local.py','scripts\kali-inventory.py','scripts\configure-mcp.py','scripts\check-mcp.py','scripts\stop-hexstrike.py',
    'docs\GUIDE.ko.html','docs\SOURCES.md','docs\VALIDATION.md','docs\INSTALL-FIX-20261005.md',
    'tests\SelfTest.ps1','tests\GuiSmoke.ps1','tests\AcquisitionSmoke.ps1','tests\MobSfFridaSmoke.py','tests\KaliBootstrapSmoke.py'
)
foreach ($relative in $files) {
    $dest=Join-Path $stage $relative
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    $source=Join-Path $root $relative
    if ([IO.Path]::GetExtension($relative) -in @('.ps1','.psm1')) {
        # Windows PowerShell 5.1 otherwise interprets BOM-less UTF-8 as ANSI.
        $strictUtf8=New-Object Text.UTF8Encoding($false,$true)
        $text=[IO.File]::ReadAllText($source,$strictUtf8)
        [IO.File]::WriteAllText($dest,$text,(New-Object Text.UTF8Encoding($true)))
    } else {Copy-Item -LiteralPath $source -Destination $dest}
}
$release=Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$packageName="VulnChecker-Windows11-v$($release.version).zip"
$package=Join-Path $outDir $packageName
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $package -Force
$hash=Get-FileHash -LiteralPath $package -Algorithm SHA256
("{0}  {1}" -f $hash.Hash,(Split-Path $package -Leaf)) | Set-Content -LiteralPath (Join-Path $outDir "$packageName.sha256.txt") -Encoding ASCII
Write-Host "Package: $package"
Write-Host "SHA256: $($hash.Hash)"
