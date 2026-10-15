#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Token,[int]$TunnelPort=18881,[int]$BurpPort=8080)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
public static class VulnCheckerBurpRelay {
    static async Task Pump(NetworkStream input, TcpClient destination) {
        try {await input.CopyToAsync(destination.GetStream());}
        finally {try {destination.Client.Shutdown(SocketShutdown.Send);} catch { }}
    }
    static async Task Worker(string token, int tunnelPort, int burpPort) {
        while (true) {
            using (var tunnel = new TcpClient()) using (var burp = new TcpClient()) {
                try {
                    await tunnel.ConnectAsync(IPAddress.Loopback, tunnelPort);
                    var a = tunnel.GetStream();
                    var key = Encoding.ASCII.GetBytes(token + "\n");
                    await a.WriteAsync(key, 0, key.Length);
                    var hello = new byte[3]; int offset = 0;
                    while (offset < hello.Length) {int n = await a.ReadAsync(hello, offset, hello.Length-offset); if (n == 0) throw new Exception("EOF"); offset += n;}
                    if (Encoding.ASCII.GetString(hello) != "OK\n") throw new Exception("Handshake");
                    await burp.ConnectAsync(IPAddress.Loopback, burpPort);
                    var b = burp.GetStream();
                    await Task.WhenAll(Pump(a, burp), Pump(b, tunnel));
                } catch { }
            }
            await Task.Delay(1000);
        }
    }
    public static void Run(string token, int tunnelPort, int burpPort) {
        var tasks = new Task[16];
        for (int i=0; i<tasks.Length; i++) tasks[i] = Worker(token, tunnelPort, burpPort);
        Task.WaitAll(tasks);
    }
}
'@
# Both ends listen/connect only on loopback. No firewall or system proxy change.
[VulnCheckerBurpRelay]::Run($Token,$TunnelPort,$BurpPort)
