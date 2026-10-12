#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$output = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$stage = Join-Path ([IO.Path]::GetTempPath()) ('infra-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$files = @('README.ko.md','VALIDATION.ko.md','ansible.cfg','requirements.txt','collections.yml',
    'Start-Infrastructure.ps1','Start-Infrastructure.cmd','Build-Package.ps1',
    'inventory/hosts.example.yml','inventory/group_vars/all/settings.yml')
foreach ($folder in @('scripts','playbooks','plugins','tests')) {
    $files += Get-ChildItem -LiteralPath (Join-Path $root $folder) -Recurse -File |
        Where-Object { $_.Extension -in @('.py','.ps1','.sh','.yml') } |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) }
}
foreach ($relative in $files) {
    $target = Join-Path $stage $relative
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    $source = Join-Path $root $relative
    if ([IO.Path]::GetExtension($relative) -eq '.ps1') {
        $content = [IO.File]::ReadAllText($source, (New-Object Text.UTF8Encoding($false,$true)))
        [IO.File]::WriteAllText($target,$content,(New-Object Text.UTF8Encoding($true)))
    } else { Copy-Item -LiteralPath $source -Destination $target }
}
$package = Join-Path $output 'VulnChecker-Infrastructure-Ansible.zip'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $package -Force
$hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
"$hash  VulnChecker-Infrastructure-Ansible.zip" | Set-Content ("$package.sha256.txt") -Encoding ASCII
# Only remove the exact task-created staging directory beneath the OS temp folder.
$resolved = [IO.Path]::GetFullPath($stage)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
    -not (Split-Path $resolved -Leaf).StartsWith('infra-package-')) { throw 'Unexpected staging path' }
Remove-Item -LiteralPath $resolved -Recurse -Force
Write-Host "Package: $package"
