#Requires -Version 5.1
# TriGuard customer offline runner. Bundled KISA source/license: -ExtractOnly.
param(
    [string]$Output=(Join-Path $PSScriptRoot 'results'),
    [string]$TargetId='',
    [string]$Profiles='auto',
    [ValidateRange(10,3600)][int]$ItemTimeout=90,
    [switch]$ExtractOnly
)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {throw 'Use Windows PowerShell 5.1: powershell.exe -File Windows-Infrastructure.ps1'}
foreach ($moduleName in @('Microsoft.PowerShell.Security','Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','CimCmdlets')) {
    Import-Module (Join-Path $PSHOME ('Modules\'+$moduleName+'\'+$moduleName+'.psd1')) -ErrorAction Stop
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$utf8=New-Object Text.UTF8Encoding($false)
function Write-JsonFile($Path,$Value) {[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 16),$utf8)}
function Write-ZipFiles($Path,$Base,[object[]]$Files) {
    $archive=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $Files) {
            $name=$file.FullName.Substring($Base.Length+1).Replace('\','/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.FullName,$name,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {$archive.Dispose()}
}
function Csv-Text($Value) {
    $text=[string]$Value
    if ($text.TrimStart() -match '^[=+@-]') {return "'"+$text}
    return $text
}
$Output=[IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$runId=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ-')+[guid]::NewGuid().ToString('N').Substring(0,8)
$run=Join-Path $Output $runId
New-Item -ItemType Directory -Path $run | Out-Null
# All source, logs and results are private to the running account/admins/SYSTEM.
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
foreach ($sid in @($identity.User.Value,'S-1-5-18','S-1-5-32-544')) {
    $account=New-Object Security.Principal.SecurityIdentifier($sid)
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($account,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $run -AclObject $acl
$payload=[Convert]::FromBase64String('__PAYLOAD_BASE64__')
$digest=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload)).Replace('-','').ToLowerInvariant()
if ($digest -ne '__PAYLOAD_SHA256__') {throw 'Embedded source integrity check failed.'}
$source=Join-Path $run 'source'
New-Item -ItemType Directory -Path $source | Out-Null
$memory=New-Object IO.MemoryStream(,$payload)
$archive=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Read)
try {
    foreach ($entry in $archive.Entries) {
        $path=[IO.Path]::GetFullPath((Join-Path $source $entry.FullName))
        if (-not $path.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Invalid embedded source path.'}
        if (-not $entry.Name) {continue}
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)
    }
} finally {$archive.Dispose();$memory.Dispose()}
if ($ExtractOnly) {Write-Host ('Source and license extracted: '+$source);exit 0}
$parsedCatalog=Get-Content -LiteralPath (Join-Path $source 'profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$catalog=@($parsedCatalog)
$compat=Get-Content -LiteralPath (Join-Path $source 'source-compatibility.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Copy-Item -LiteralPath (Join-Path $source 'source-compatibility.json') -Destination $run
$name=$TargetId;if (-not $name) {$name=[Net.Dns]::GetHostName()}
$requested=$name
if ($name.Contains(':')) {$name='ip6-'+$name.Replace(':','-')}
if ($name -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,180}$') {throw 'TargetId must be a server name or IP.'}
$ips=@()
try {$ips=@(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object {$_.IPAddress} | Where-Object {$_ -and $_ -ne '127.0.0.1' -and $_ -ne '::1'})} catch {}
$address=$requested;if ($ips.Count) {$address=[string]$ips[0]}
$summary=[ordered]@{run_id=$runId;revision=$compat.source_revision;collection_method='customer-offline';preflight=$false;physical_servers=1;hosts=@();targets=@{};servers=@{};failed_hosts=@();vulnerable_hosts=@();manual_hosts=@();ansible_rc=0;limitations='Local collection. Unavailable tools, incomplete results and manual verdicts require review. IIS checks cover the entire server. Bash-only DB/Web profiles are not converted to PowerShell.'}
Write-JsonFile (Join-Path $run 'metadata.json') @{schema_version=1;run_id=$runId;hostname=[Net.Dns]::GetHostName();target_id=$requested;addresses=$ips;source_revision=$compat.source_revision;powershell=$PSVersionTable.PSVersion.ToString()}
$preparationError=''
$jobs=@()
try {
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run from an approved administrator PowerShell session.'}
    if ($Profiles -eq 'auto') {
        $os=Get-CimInstance Win32_OperatingSystem
        if ($os.ProductType -eq 1) {$jobs=@('pc')} else {$jobs=@('windows')}
        if (Get-Service -Name W3SVC -ErrorAction SilentlyContinue) {$jobs+= 'iis'}
    } else {
        $jobs=@($Profiles.Split(',') | ForEach-Object {$_.Trim().ToLowerInvariant()} | Select-Object -Unique)
        foreach ($profile in $jobs) {if ($profile -notin @('windows','pc','iis')) {throw 'Windows profiles: windows, pc, iis. DB and other Web/WAS require the Unix runner.'}}
        if ('windows' -in $jobs -and 'pc' -in $jobs) {throw 'Select one OS profile per run: windows or pc.'}
    }
} catch {$preparationError=$_.Exception.Message;$jobs=@('unresolved')}
$failureRows=New-Object 'System.Collections.Generic.List[object]'
foreach ($profileId in $jobs) {
    $instance='os';if ($profileId -eq 'iis') {$instance='iis-1'}
    $alias=$name;if ($instance -ne 'os') {$alias+='--'+$instance}
    if ($summary.targets.ContainsKey($alias)) {throw 'Select only one OS profile per run.'}
    $summary.hosts+= $alias
    $summary.targets[$alias]=@{server=$name;host=$address;port='';connection='local';instance=$instance;profile=$profileId}
    $errors=New-Object 'System.Collections.Generic.List[string]'
    $counts=@{}
    if ($preparationError) {$errors.Add($preparationError)} else {
        $profile=@($catalog | Where-Object Id -eq $profileId)[0]
        $workspace=Join-Path (Join-Path $run 'workspaces') $alias
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source 'lib') -Destination (Join-Path $workspace 'lib') -Recurse
        $destination=Join-Path $workspace $profile.Folder
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source $profile.Folder) -Destination $destination -Recurse
        Write-Host ('Checking '+$alias+' / '+$profileId+' ('+$profile.Count+' items)')
        try {
            # The existing isolated item runner bounds each script and stops after 3 consecutive timeouts.
            & (Join-Path $source 'scripts\windows-execute.ps1') -Root $workspace -ItemTimeout $ItemTimeout -Profile $profileId -ShowProgress
        } catch {$errors.Add('Local execution wrapper failed; check the execution logs.')}
        $executions=@()
        try {$parsed=Get-Content -LiteralPath (Join-Path $workspace 'execution.json') -Raw -Encoding UTF8 | ConvertFrom-Json;$executions=@($parsed)} catch {$errors.Add('Missing or invalid execution manifest.')}
        $seen=@{}
        foreach ($execution in $executions) {
            if ($execution.rc -ne 0) {
                $reason='exit '+$execution.rc
                if ($execution.rc -eq 124) {$reason='item response timeout'}
                if ($execution.rc -eq 125) {$reason='skipped after 3 consecutive item timeouts'}
                $errors.Add(([string]$execution.item_id+': '+$reason))
            }
        }
        if ($executions.Count -ne $profile.Count) {$errors.Add('Incomplete execution manifest.')}
        foreach ($file in @(Get-ChildItem -LiteralPath $destination -Filter '*.json' -File -Recurse)) {
            try {
                $record=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $record.item_id) {continue}
                if ($record.item_id -notmatch ('^'+[regex]::Escape($profile.Prefix)+'-\d{2}$')) {continue}
                if ($seen.ContainsKey([string]$record.item_id)) {$errors.Add('Duplicate result: '+$record.item_id);continue}
                $seen[[string]$record.item_id]=$true
                $status=[string]$record.final_result;if (-not $status) {$status=[string]$record.diagnosis_result}
                if ($status -notin @('GOOD','VULNERABLE','MANUAL','N/A','NA','NOT_APPLICABLE')) {$errors.Add('Invalid verdict: '+$record.item_id);continue}
                if (-not $counts.ContainsKey($status)) {$counts[$status]=0};$counts[$status]++
            } catch {$errors.Add('Invalid JSON evidence: '+$file.Name)}
        }
        foreach ($number in 1..$profile.Count) {
            $item=$profile.Prefix+('-{0:D2}' -f $number)
            if (-not $seen.ContainsKey($item)) {$errors.Add('Missing JSON: '+$item)}
        }
        $hostDir=Join-Path $run $alias;New-Item -ItemType Directory -Path $hostDir | Out-Null
        $files=@(Get-ChildItem -LiteralPath $workspace -Recurse -File | Where-Object {($_.Extension -ne '.ps1') -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
        Write-ZipFiles (Join-Path $hostDir 'evidence.zip') $workspace $files
    }
    $outcome=@{execution_failed=($errors.Count -gt 0);errors=@($errors.ToArray());counts=$counts;vulnerable=([int]$counts['VULNERABLE'] -gt 0);manual=([int]$counts['MANUAL'] -gt 0)}
    $summary.servers[$alias]=$outcome
    if ($outcome.execution_failed) {$summary.failed_hosts+=$alias}
    if ($outcome.vulnerable) {$summary.vulnerable_hosts+=$alias}
    if ($outcome.manual) {$summary.manual_hosts+=$alias}
    foreach ($errorText in $errors) {
        $failureRows.Add([pscustomobject]@{run_id=$runId;server=(Csv-Text $name);ip=(Csv-Text $address);port='';connection='local';instance=$instance;profile=$profileId;stage='Local item/evidence verification';reason_code='LOCAL_EXECUTION';reason=(Csv-Text $errorText);requested_action='Check local prerequisites, privileges and execution logs; re-run the affected profile.'})
    }
}
if ($summary.failed_hosts.Count) {$summary.ansible_rc=1}
Write-JsonFile (Join-Path $run 'summary.json') $summary
$failurePath=Join-Path $run 'failures.csv'
if ($failureRows.Count) {$failureRows | Export-Csv -LiteralPath $failurePath -NoTypeInformation -Encoding UTF8} else {[IO.File]::WriteAllText($failurePath,'run_id,server,ip,port,connection,instance,profile,stage,reason_code,reason,requested_action'+"`r`n",(New-Object Text.UTF8Encoding($true)))}
$files=@(foreach ($file in @('summary.json','failures.csv','metadata.json','source-compatibility.json')) {Get-Item -LiteralPath (Join-Path $run $file)})
$files+=@(foreach ($alias in $summary.hosts) {$path=Join-Path (Join-Path $run $alias) 'evidence.zip';if (Test-Path -LiteralPath $path) {Get-Item -LiteralPath $path}})
$entries=@(foreach ($file in $files) {@{path=$file.FullName.Substring($run.Length+1).Replace('\','/');bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
Write-JsonFile (Join-Path $run 'manifest.json') @{schema_version=1;type='triguard-offline-result';run_id=$runId;files=$entries}
$files+=Get-Item -LiteralPath (Join-Path $run 'manifest.json')
$result=Join-Path $Output ($runId+'.zip')
Write-ZipFiles ($result+'.tmp') $run $files
Move-Item -LiteralPath ($result+'.tmp') -Destination $result
# Apply the same private ACL to the deliverable file before returning its path.
$resultAcl=Get-Acl -LiteralPath $result
$resultAcl.SetAccessRuleProtection($true,$false)
foreach ($sid in @($identity.User.Value,'S-1-5-18','S-1-5-32-544')) {
    $account=New-Object Security.Principal.SecurityIdentifier($sid)
    $resultAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($account,'FullControl','Allow')))
}
Set-Acl -LiteralPath $result -AclObject $resultAcl
Write-Host ('RETURN THIS RESULT ZIP: '+$result)
Write-Host ('Failed/incomplete targets: '+$summary.failed_hosts.Count)
if ($summary.failed_hosts.Count) {exit 2}
exit 0
