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
    'Start.cmd','VulnChecker.ps1','config.json','README.md','Build-Package.ps1',
    'lib\Core.psm1','lib\Install.ps1','lib\Launch.ps1','lib\Gui.ps1','lib\Integrations.ps1','lib\Mobile.ps1','lib\MobileTargets.ps1','lib\AppAcquisition.ps1',
    'scripts\ensure-frida.py','scripts\instrument-app.py','scripts\root-bypass.js','scripts\prepare-mobile-context.py','scripts\select-mobsf-app.py','scripts\check-mobile-mcp.py','scripts\app-diagnostics.py','scripts\configure-chain.py','scripts\stop-opencode.py','scripts\configure-mobsf-frida.py',
    'lib\Inventory.ps1','scripts\kali-bootstrap.sh','scripts\hexstrike-local.py','scripts\kali-inventory.py','scripts\configure-mcp.py','scripts\check-mcp.py','scripts\stop-hexstrike.py',
    'docs\GUIDE.ko.html','docs\SOURCES.md','docs\VALIDATION.md',
    'tests\SelfTest.ps1','tests\GuiSmoke.ps1','tests\AcquisitionSmoke.ps1','tests\MobSfFridaSmoke.py'
)
foreach ($relative in $files) {
    $dest=Join-Path $stage $relative
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $dest
}
$package=Join-Path $outDir 'VulnChecker-Windows11-v5.zip'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $package -Force
$hash=Get-FileHash -LiteralPath $package -Algorithm SHA256
("{0}  {1}" -f $hash.Hash,(Split-Path $package -Leaf)) | Set-Content -LiteralPath (Join-Path $outDir 'VulnChecker-Windows11-v5.sha256.txt') -Encoding ASCII
Write-Host "Package: $package"
Write-Host "SHA256: $($hash.Hash)"
