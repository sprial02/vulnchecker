#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$csvTemplate=Join-Path $root 'infrastructure\inventory\servers.template.csv'
if (@(Import-Csv -LiteralPath $csvTemplate -Encoding UTF8).Count -gt 0) {
    throw 'CSV template contains server rows. Keep the template empty and store customer CSV files outside the source tree.'
}
$outDir=Join-Path $root 'dist'
$stage=Join-Path $root ('runtime\package-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage,$outDir -Force | Out-Null
# An explicit allowlist prevents customer data, credentials, runtime logs and caches
# from being included in a transferable package.
$files=@(
    'scripts\infra-text.py','tests\InfraTextSmoke.py','docs\UI-GUIDE.ko.md',
    'tests\InfrastructureProfilesSmoke.ps1','lib\InfrastructureProfiles.ps1','infrastructure\profiles.json',
    'offline-kit\TriGuard-Infrastructure-Offline.zip','docs\CUSTOMER-OFFLINE.ko.md','infrastructure\licenses\AGPL-3.0.txt','scripts\import-offline.py','tests\OfflineSmoke.py','tests\OfflineGuiSmoke.ps1',
    'scripts\report-matrix.py','scripts\report-archive.py','tests\RawArchiveSmoke.py',
    'tests\InfrastructurePasswordSmoke.ps1',
    'reports\templates\mobile-vulnerability-report.docx','reports\templates\web-vulnerability-report.docx','reports\templates\infra-vulnerability-report.docx',
    'lib\Reports.ps1','lib\ReportsGui.ps1','scripts\report-store.py','scripts\report-docx.py','scripts\report-runtime.json','tests\ReportSmoke.py','tests\ReportsGuiSmoke.ps1','docs\REPORTS.ko.md',
    'scripts\ensure-hexstrike-python.py','scripts\hexstrike-python.json','tests\HexStrikePythonSmoke.py',
    'scripts\hexstrike-python-routing.py',
    'tests\HexStrikeLiveSmoke.py',
    'lib\OnDemand.ps1','tests\OnDemandSmoke.ps1',
    'tests\KaliInventorySmoke.py',
    'tests\WslBootstrapSmoke.ps1',
    'lib\Infrastructure.ps1','lib\InfrastructureGui.ps1','tests\InfrastructureSmoke.ps1','docs\INFRASTRUCTURE.ko.html',
    'infrastructure\ansible.cfg','infrastructure\requirements.txt','infrastructure\collections.yml','infrastructure\README.ko.md','infrastructure\VALIDATION.ko.md',
    'infrastructure\inventory\hosts.example.yml','infrastructure\inventory\servers.example.csv','infrastructure\inventory\servers.template.csv','infrastructure\inventory\servers.csv-guide.ko.txt','infrastructure\inventory\group_vars\all\settings.yml','tests\InfrastructureScaleSmoke.ps1','tests\InfrastructureTimeoutSmoke.ps1',
    'scripts\launch-opencode.py','tests\AiLaunchSmoke.py',
    'lib\Ai.ps1','scripts\configure-ai.py','tests\AiSmoke.ps1','tests\AiConfigSmoke.py',
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
foreach ($folder in @('scripts','playbooks','plugins','tests')) {
    $base=Join-Path $root ('infrastructure\'+$folder)
    $files+=Get-ChildItem -LiteralPath $base -Recurse -File | Where-Object {$_.Extension -in @('.py','.ps1','.sh','.yml')} | ForEach-Object {$_.FullName.Substring($root.Length+1)}
}
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
