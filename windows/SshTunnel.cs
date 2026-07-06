using System.Diagnostics;
using System.Text;

namespace SpeedLane;

/// <summary>管理 ssh -N -D 动态端口转发进程(使用 Windows 自带的 OpenSSH 客户端)</summary>
public class SshTunnel
{
    /// <summary>隧道意外退出时的回调(参数为错误信息),在线程池线程触发</summary>
    public event Action<string>? Failed;

    private Process? _process;
    private readonly StringBuilder _stderr = new();
    private volatile bool _stopping;

    public bool Running => _process is { HasExited: false };

    public static string SshExecutable
    {
        get
        {
            var systemSsh = Path.Combine(Environment.SystemDirectory, "OpenSSH", "ssh.exe");
            return File.Exists(systemSsh) ? systemSsh : "ssh.exe";
        }
    }

    /// <summary>密码登录借助 SSH_ASKPASS:密码通过环境变量传给辅助脚本,不出现在命令行</summary>
    private static string EnsureAskPassScript()
    {
        Directory.CreateDirectory(AppSettings.Directory);
        var path = Path.Combine(AppSettings.Directory, "askpass.cmd");
        File.WriteAllText(path, "@echo %SPEEDLANE_SSH_PW%\r\n");
        return path;
    }

    public static ProcessStartInfo BuildStartInfo(
        ServerConfig server, string? password, string[] extraArguments, string[]? remoteCommand = null)
    {
        var psi = new ProcessStartInfo
        {
            FileName = SshExecutable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        var args = psi.ArgumentList;
        args.Add("-p"); args.Add(server.SshPort.ToString());
        args.Add("-o"); args.Add("ServerAliveInterval=30");
        args.Add("-o"); args.Add("ServerAliveCountMax=3");
        args.Add("-o"); args.Add("ConnectTimeout=10");
        args.Add("-o"); args.Add("StrictHostKeyChecking=accept-new");

        if (!string.IsNullOrEmpty(password))
        {
            args.Add("-o"); args.Add("NumberOfPasswordPrompts=1");
            args.Add("-o"); args.Add("PreferredAuthentications=publickey,password,keyboard-interactive");
            psi.Environment["SSH_ASKPASS"] = EnsureAskPassScript();
            psi.Environment["SSH_ASKPASS_REQUIRE"] = "force"; // OpenSSH 8.4+(Win11 自带版本支持)
            psi.Environment["DISPLAY"] = ":0";
            psi.Environment["SPEEDLANE_SSH_PW"] = password;
        }
        else
        {
            // 密钥登录:禁止交互,避免卡在密码输入
            args.Add("-o"); args.Add("BatchMode=yes");
        }

        foreach (var a in extraArguments) args.Add(a);
        args.Add($"{server.User}@{server.Host}");
        if (remoteCommand != null)
            foreach (var a in remoteCommand) args.Add(a);

        return psi;
    }

    public void Start(ServerConfig server, int localPort, string? password)
    {
        Stop();
        _stopping = false;
        _stderr.Clear();

        var psi = BuildStartInfo(server, password, new[]
        {
            "-N",
            "-D", $"127.0.0.1:{localPort}",
            "-o", "ExitOnForwardFailure=yes",
        });

        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data != null) lock (_stderr) _stderr.AppendLine(e.Data);
        };
        process.Exited += (_, _) =>
        {
            if (_stopping) return;
            string message;
            lock (_stderr) message = _stderr.ToString().Trim();
            if (message.Length == 0) message = $"SSH 连接已断开(退出码 {process.ExitCode})";
            Failed?.Invoke(message);
        };

        try
        {
            process.Start();
            process.BeginErrorReadLine();
            _process = process;
        }
        catch (Exception ex)
        {
            Failed?.Invoke($"无法启动 ssh:{ex.Message}(请确认已安装 OpenSSH 客户端)");
        }
    }

    public void Stop()
    {
        _stopping = true;
        try
        {
            if (_process is { HasExited: false }) _process.Kill();
        }
        catch
        {
        }
        _process = null;
    }

    /// <summary>在服务器上执行 echo ok 验证连通性;返回 null 表示成功,否则为错误信息</summary>
    public static string? Test(ServerConfig server, string? password)
    {
        try
        {
            var psi = BuildStartInfo(server, password, Array.Empty<string>(), new[] { "echo", "ok" });
            using var process = Process.Start(psi)!;
            var output = new StringBuilder();
            process.OutputDataReceived += (_, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
            process.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            if (!process.WaitForExit(15000))
            {
                try { process.Kill(); } catch { }
                return "连接超时";
            }
            string text;
            lock (output) text = output.ToString().Trim();
            if (process.ExitCode == 0 && text.Contains("ok")) return null;
            return text.Length == 0 ? $"连接失败(退出码 {process.ExitCode})" : text;
        }
        catch (Exception ex)
        {
            return $"无法启动 ssh:{ex.Message}";
        }
    }
}
