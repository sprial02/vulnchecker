param([Parameter(Mandatory)][string]$Root, [int]$ItemTimeout = 90,[ValidateSet('windows','pc','iis')][string]$Profile='windows',[switch]$ShowProgress)
$ErrorActionPreference = 'Stop'
if (-not (Get-Variable Profile -ErrorAction SilentlyContinue)) {$Profile='windows'}
# Keep the wrapper ASCII-safe when invoked by Windows PowerShell 5.1.
$folderName = '02.Windows' + [char]0xC11C + [char]0xBC84
$folder = Join-Path $Root $folderName
$prefix='W';$count=64
if ($Profile -eq 'pc') {$folder=Join-Path $Root '07.PC';$prefix='P';$count=18}
if ($Profile -eq 'iis') {$folder=Join-Path $Root ('03.'+[char]0xC6F9+[char]0xC11C+[char]0xBC84+'\IIS');$prefix='WEB';$count=26}
$logs = Join-Path $Root 'execution-logs'
New-Item -ItemType Directory -Path $logs | Out-Null
$records = @()
$consecutiveTimeouts = 0
foreach ($n in 1..$count) {
    $item = $prefix+('-{0:D2}' -f $n)
    if ($consecutiveTimeouts -ge 3) {
        $records += @{item_id=$item;rc=125;reason='Skipped after 3 consecutive item timeouts'}
        ConvertTo-Json -InputObject @($records) | Set-Content (Join-Path $Root 'execution.json') -Encoding UTF8
        continue
    }
    $script = Join-Path $folder ($prefix+('{0:D2}_check.ps1' -f $n))
    if ($ShowProgress) {Write-Host ('['+$n+'/'+$count+'] '+$item+' (limit '+$ItemTimeout+'s)')}
    $rc = 127
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script + '"'
        $info.WorkingDirectory = $folder
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.WindowStyle = 'Hidden'
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $info
        [void]$proc.Start()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($ItemTimeout * 1000)) {
            $rc = 124
            $killInfo=New-Object System.Diagnostics.ProcessStartInfo
            $killInfo.FileName=Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $killInfo.Arguments='/PID '+$proc.Id+' /T /F'
            $killInfo.UseShellExecute=$false;$killInfo.CreateNoWindow=$true
            $killer=[Diagnostics.Process]::Start($killInfo)
            try {if (-not $killer.WaitForExit(5000)) {$killer.Kill()}} finally {$killer.Dispose()}
            if (-not $proc.WaitForExit(3000)) {$proc.Kill()}
        } else {
            $proc.WaitForExit()
            $rc = $proc.ExitCode
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $outText='[Output pipe did not close; remaining output unavailable]'
        $errText=$outText
        if ($stdout.Wait(3000)) {$outText=$stdout.GetAwaiter().GetResult()}
        if ($stderr.Wait(3000)) {$errText=$stderr.GetAwaiter().GetResult()}
        [IO.File]::WriteAllText((Join-Path $logs "$item.stdout.log"), $outText, $utf8)
        [IO.File]::WriteAllText((Join-Path $logs "$item.stderr.log"), $errText, $utf8)
        $proc.Dispose()
    } catch {
        if ($ShowProgress) {Write-Host ('['+$n+'/'+$count+'] '+$item+' (limit '+$ItemTimeout+'s)')}
        if ($rc -ne 124) {$rc = 127}
        $_ | Out-File (Join-Path $logs "$item.error.log") -Encoding UTF8
    }
    $records += @{item_id = $item; rc = $rc}
    if ($ShowProgress) {Write-Host ($item+': exit '+$rc)}
    if ($rc -eq 124) {$consecutiveTimeouts++} else {$consecutiveTimeouts=0}
    ConvertTo-Json -InputObject @($records) | Set-Content (Join-Path $Root 'execution.json') -Encoding UTF8
}
