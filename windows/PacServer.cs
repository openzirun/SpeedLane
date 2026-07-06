using System.Net;
using System.Net.Sockets;
using System.Text;

namespace SpeedLane;

/// <summary>极简本地 HTTP 服务,只在 127.0.0.1 上向系统提供 PAC 文件(无需管理员权限)</summary>
public class PacServer
{
    public int Port { get; }
    private readonly Func<string> _pacProvider;
    private TcpListener? _listener;

    public PacServer(int port, Func<string> pacProvider)
    {
        Port = port;
        _pacProvider = pacProvider;
    }

    public string BaseUrl => $"http://127.0.0.1:{Port}/proxy.pac";

    public void Start()
    {
        if (_listener != null) return;
        _listener = new TcpListener(IPAddress.Loopback, Port);
        _listener.Start();
        _ = AcceptLoopAsync(_listener);
    }

    public void Stop()
    {
        try { _listener?.Stop(); } catch { }
        _listener = null;
    }

    private async Task AcceptLoopAsync(TcpListener listener)
    {
        while (true)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
            }
            catch
            {
                break; // listener 已停止
            }
            _ = HandleAsync(client);
        }
    }

    private async Task HandleAsync(TcpClient client)
    {
        try
        {
            using (client)
            {
                var stream = client.GetStream();
                var buffer = new byte[65536];
                await stream.ReadAsync(buffer).ConfigureAwait(false);

                var body = Encoding.UTF8.GetBytes(_pacProvider());
                var header =
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: application/x-ns-proxy-autoconfig\r\n" +
                    $"Content-Length: {body.Length}\r\n" +
                    "Cache-Control: no-cache\r\n" +
                    "Connection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.ASCII.GetBytes(header)).ConfigureAwait(false);
                await stream.WriteAsync(body).ConfigureAwait(false);
            }
        }
        catch
        {
            // 单个连接失败不影响服务
        }
    }
}
