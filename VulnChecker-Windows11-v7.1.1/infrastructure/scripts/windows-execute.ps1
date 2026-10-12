param([Parameter(Mandatory)][string]$Root, [int]$ItemTimeout = 90)
$ErrorActionPreference = 'Stop'
# Keep the wrapper ASCII-safe when invoked by Windows PowerShell 5.1.
$folderName = '02.Windows' + [char]0xC11C + [char]0xBC84
$folder = Join-Path $Root $folderName
$logs = Join-Path $Root 'execution-logs'
New-Item -ItemType Directory -Path $logs | Out-Null
$records = @()
foreach ($n in 1..64) {
    $item = 'W-{0:D2}' -f $n
    $script = Join-Path $folder ('W{0:D2}_check.ps1' -f $n)
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
            & taskkill.exe /PID $proc.Id /T /F | Out-Null
            $rc = 124
        } else {
            $proc.WaitForExit()
            $rc = $proc.ExitCode
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $logs "$item.stdout.log"), $stdout.GetAwaiter().GetResult(), $utf8)
        [IO.File]::WriteAllText((Join-Path $logs "$item.stderr.log"), $stderr.GetAwaiter().GetResult(), $utf8)
        $proc.Dispose()
    } catch {
        $rc = 127
        $_ | Out-File (Join-Path $logs "$item.error.log") -Encoding UTF8
    }
    $records += @{item_id = $item; rc = $rc}
    ConvertTo-Json -InputObject @($records) | Set-Content (Join-Path $Root 'execution.json') -Encoding UTF8
}
