param([int]$Result=0)
$utf8=New-Object Text.UTF8Encoding($false)
$stdout=[Console]::OpenStandardOutput(); $stderr=[Console]::OpenStandardError()
$bytes=$utf8.GetBytes("정상 한국어 출력`n"); $stdout.Write($bytes,0,$bytes.Length); $stdout.Flush()
$bytes=$utf8.GetBytes("오류 한국어 연결 거부`n"); $stderr.Write($bytes,0,$bytes.Length); $stderr.Flush()
exit $Result