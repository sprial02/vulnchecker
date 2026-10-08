#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
Initialize-Context -Root $root -ConfigPath (Join-Path $root 'config.json') | Out-Null
$rt=Get-KaliRuntime
$id=[guid]::NewGuid().ToString('N')
$folder=Join-Path $root ('runtime\relay-smoke-'+$id)
New-Item -ItemType Directory -Path $folder | Out-Null
$linuxScript="/tmp/vc-relay-$id.py"; $identity="/tmp/vc-relay-$id.json"
$source=Get-Content (Join-Path $root 'scripts\web-relay.py') -Raw -Encoding UTF8
Invoke-Kali -Arguments @('tee',$linuxScript) -InputText $source -Quiet | Out-Null
$fixture=@'
Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public static class BinaryFixture {
 public static void Run() {
  var server = new TcpListener(IPAddress.Loopback, 28882); server.Start();
  try { for (int request=0; request<4; request++) {
   using(var client=server.AcceptTcpClient()) {
    var stream=client.GetStream(); var header="";
    while(!header.EndsWith("\r\n\r\n")) {int b=stream.ReadByte(); if(b<0) throw new Exception("EOF"); header+=(char)b;}
    int length=2*1024*1024;
    var prefix=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: "+length+"\r\nConnection: close\r\n\r\n");
    stream.Write(prefix,0,prefix.Length);
    var buffer=new byte[8192]; for(int i=0;i<buffer.Length;i++) buffer[i]=(byte)(i%256);
    for(int i=0;i<length/buffer.Length;i++) {stream.Write(buffer,0,buffer.Length); Thread.Sleep(1);}
   }
  }} finally {server.Stop();}
 }
}
"@
[BinaryFixture]::Run()
'@
$fixtureFile=Join-Path $folder 'fixture.ps1'
[IO.File]::WriteAllText($fixtureFile,$fixture,(New-Object Text.UTF8Encoding($true)))
$linux=$null; $bridge=$null; $backend=$null
try {
    $backend=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$fixtureFile+'"')) -PassThru -RedirectStandardError (Join-Path $folder 'fixture-error.log')
    $linux=Start-Process wsl.exe -WindowStyle Hidden -ArgumentList @('-d',(Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json).kaliDistro,'-u',$rt.User,'--',$rt.HexPython,$linuxScript,'--token',$id,'--identity',$identity,'--proxy-port','28880','--tunnel-port','28881') -PassThru -RedirectStandardError (Join-Path $folder 'linux-error.log')
    $code='& '+(Quote-PsLiteral (Join-Path $root 'scripts\burp-relay.ps1'))+' -Token '+(Quote-PsLiteral $id)+' -TunnelPort 28881 -BurpPort 28882'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $bridge=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -PassThru -RedirectStandardError (Join-Path $folder 'windows-error.log')
    Start-Sleep -Seconds 3
    $probe=@'
import socket
for half_close in (False,True,False,True):
    with socket.create_connection(('127.0.0.1',28880),timeout=15) as connection:
        connection.sendall(b'GET http://fixture.invalid/cert HTTP/1.1\r\nHost: fixture.invalid\r\nConnection: close\r\n\r\n'.replace(b'\\r',b'\r').replace(b'\\n',b'\n'))
        if half_close: connection.shutdown(socket.SHUT_WR)
        chunks=[]
        while data:=connection.recv(65536):
            chunks.append(data)
            received=b''.join(chunks)
            if b'\r\n\r\n' in received and len(received.split(b'\r\n\r\n',1)[1]) >= 2*1024*1024: break
        response=b''.join(chunks)
        body=response.split(b'\r\n\r\n',1)[1]
        assert body==bytes(range(256))*8192, (half_close,len(body))
        print('PASS binary response, half_close='+str(half_close),flush=True)
print('PASS four 2 MiB fragmented binary responses, including client half-close, through Windows/WSL relay')
'@
    Invoke-Kali -Arguments @($rt.HexPython,'-') -InputText $probe -Quiet
} finally {
    if ($bridge -and -not $bridge.HasExited) {$bridge.Kill(); [void]$bridge.WaitForExit(5000)}
    try {Invoke-Kali -Arguments @($rt.HexPython,$linuxScript,'--identity',$identity,'--stop') -Quiet | Out-Null} catch {}
    foreach ($process in @($linux,$backend)) {if ($process -and -not $process.HasExited) {$process.Kill(); [void]$process.WaitForExit(5000)}}
}
