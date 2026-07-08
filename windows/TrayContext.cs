using System.Drawing.Drawing2D;
using System.Reflection;

namespace SpeedLane;

/// <summary>托盘图标与总控制:串联 SSH 隧道、PAC 服务和系统代理设置</summary>
public class TrayContext : ApplicationContext
{
    private readonly AppSettings _settings = AppSettings.Load();
    private readonly NotifyIcon _tray;
    private readonly PacServer _pacServer;
    private readonly SshTunnel _tunnel = new();
    private readonly Control _invoker = new(); // 用于把后台事件切回 UI 线程

    private enum Phase { Disconnected, Connecting, Connected, Disconnecting }

    private Phase _phase = Phase.Disconnected;
    private ServerConfig? _activeServer;
    private int _pacVersion;
    private int _activeLocalPort = 1080; // 首选端口被占用时自动换用空闲端口
    private SettingsForm? _settingsForm;

    private readonly System.Windows.Forms.Timer _pulseTimer;
    private int _pulseFrame;
    private Icon? _currentIcon;

    private bool Enabled => _phase == Phase.Connected;
    private bool Busy => _phase is Phase.Connecting or Phase.Disconnecting;

    public TrayContext()
    {
        _invoker.CreateControl();

        _pacServer = new PacServer(17890, () =>
            PacBuilder.Build(_settings.ActiveDomains, ProxyLine()));

        _tunnel.Failed += message => _invoker.BeginInvoke(() =>
        {
            if (!Enabled) return;
            Disable();
            _tray.ShowBalloonTip(5000, "SpeedLane 连接失败", message, ToolTipIcon.Error);
        });

        _tray = new NotifyIcon
        {
            Icon = IconFactory.Bolt(active: false),
            Text = "SpeedLane - 未启用",
            Visible = true,
            ContextMenuStrip = new ContextMenuStrip(),
        };
        _currentIcon = _tray.Icon;

        // “连接中/断开中”时驱动托盘图标呼吸脉冲,作为进度动画
        _pulseTimer = new System.Windows.Forms.Timer { Interval = 350 };
        _pulseTimer.Tick += (_, _) =>
        {
            _pulseFrame++;
            SetIcon(IconFactory.BoltConnecting(_pulseFrame));
        };

        _tray.ContextMenuStrip.Opening += (_, _) => RebuildMenu();
        _tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowMenu();
        };
        _tray.DoubleClick += (_, _) => OpenSettings();

        RebuildMenu();

        if (_settings.AutoConnect) Enable();
    }

    // MARK: 菜单

    private void RebuildMenu()
    {
        var menu = _tray.ContextMenuStrip!;
        menu.Items.Clear();

        var status = new ToolStripMenuItem(StatusText()) { Enabled = false };
        menu.Items.Add(status);
        menu.Items.Add(new ToolStripSeparator());

        // 服务器选择
        if (_settings.Servers.Count > 0)
        {
            var serverMenu = new ToolStripMenuItem("连接服务器");
            foreach (var server in _settings.Servers)
            {
                var item = new ToolStripMenuItem(server.ToString())
                {
                    Checked = _settings.DefaultServer?.Id == server.Id,
                };
                var captured = server;
                item.Click += (_, _) =>
                {
                    _settings.DefaultServerId = captured.Id;
                    _settings.Save();
                    ConnectionSettingsChanged();
                };
                serverMenu.DropDownItems.Add(item);
            }
            menu.Items.Add(serverMenu);
        }

        // 站点开关
        var sitesMenu = new ToolStripMenuItem("加速站点");
        foreach (var preset in Presets.All)
        {
            var item = new ToolStripMenuItem($"{preset.Name} ({preset.Domains.Length} 个域名)")
            {
                Checked = _settings.EnabledPresets.Contains(preset.Id),
                CheckOnClick = true,
            };
            var captured = preset;
            item.CheckedChanged += (_, _) =>
            {
                if (item.Checked) _settings.EnabledPresets.Add(captured.Id);
                else _settings.EnabledPresets.Remove(captured.Id);
                _settings.Save();
                SettingsChanged();
            };
            sitesMenu.DropDownItems.Add(item);
        }
        foreach (var site in _settings.CustomSites)
        {
            var item = new ToolStripMenuItem($"{site.Domain} (自定义)")
            {
                Checked = site.Enabled,
                CheckOnClick = true,
            };
            var captured = site;
            item.CheckedChanged += (_, _) =>
            {
                captured.Enabled = item.Checked;
                _settings.Save();
                SettingsChanged();
            };
            sitesMenu.DropDownItems.Add(item);
        }
        menu.Items.Add(sitesMenu);
        menu.Items.Add(new ToolStripSeparator());

        var connectText = _phase switch
        {
            Phase.Connecting => "连接中…",
            Phase.Disconnecting => "断开中…",
            Phase.Connected => "断开连接",
            _ => "连接选中站点",
        };
        var connect = new ToolStripMenuItem(connectText) { Enabled = !Busy };
        connect.Font = new Font(connect.Font, FontStyle.Bold);
        connect.Click += (_, _) => Toggle();
        menu.Items.Add(connect);

        var settings = new ToolStripMenuItem("设置…");
        settings.Click += (_, _) => OpenSettings();
        menu.Items.Add(settings);

        var login = new ToolStripMenuItem("开机自动运行") { Checked = LaunchAtLogin.IsEnabled };
        login.Click += (_, _) => LaunchAtLogin.Set(!LaunchAtLogin.IsEnabled);
        menu.Items.Add(login);

        menu.Items.Add(new ToolStripSeparator());
        var quit = new ToolStripMenuItem("退出 SpeedLane");
        quit.Click += (_, _) => ExitApp();
        menu.Items.Add(quit);
    }

    private void ShowMenu()
    {
        // NotifyIcon 只在右键时自动弹菜单,左键需通过内部方法触发
        typeof(NotifyIcon)
            .GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?
            .Invoke(_tray, null);
    }

    private string StatusText() => _phase switch
    {
        Phase.Connecting => "正在连接…",
        Phase.Disconnecting => "正在断开…",
        Phase.Connected => $"已连接 {_activeServer?.Name},仅所选站点走加速",
        _ => "未启用,所有流量直连",
    };

    /// <summary>切换连接状态并刷新界面;连接/断开过程中启动图标脉冲动画</summary>
    private void SetPhase(Phase phase)
    {
        _phase = phase;
        if (phase is Phase.Connecting or Phase.Disconnecting)
        {
            _pulseFrame = 0;
            if (!_pulseTimer.Enabled) _pulseTimer.Start();
        }
        else
        {
            _pulseTimer.Stop();
        }
        UpdateUi();
    }

    private void UpdateUi()
    {
        switch (_phase)
        {
            case Phase.Connecting:
                _tray.Text = "SpeedLane - 正在连接…"; // 图标由脉冲动画负责
                break;
            case Phase.Disconnecting:
                _tray.Text = "SpeedLane - 正在断开…";
                break;
            case Phase.Connected:
                SetIcon(IconFactory.Bolt(active: true));
                _tray.Text = $"SpeedLane - 已连接 {_activeServer?.Name}";
                break;
            default:
                SetIcon(IconFactory.Bolt(active: false));
                _tray.Text = "SpeedLane - 未启用";
                break;
        }
    }

    /// <summary>更换托盘图标并释放上一枚,避免脉冲动画期间 GDI 句柄泄漏</summary>
    private void SetIcon(Icon icon)
    {
        _tray.Icon = icon;
        _currentIcon?.Dispose();
        _currentIcon = icon;
    }

    // MARK: 开关

    public void Toggle()
    {
        if (Busy) return; // 连接/断开进行中,忽略重复点击
        if (Enabled) Disable();
        else Enable();
    }

    public void Enable()
    {
        if (_phase != Phase.Disconnected) return;

        if (_settings.ActiveDomains.Count == 0)
        {
            _tray.ShowBalloonTip(4000, "SpeedLane", "请先勾选至少一个要加速的站点", ToolTipIcon.Warning);
            return;
        }
        var server = _settings.DefaultServer;
        if (server == null || string.IsNullOrWhiteSpace(server.Host))
        {
            _tray.ShowBalloonTip(4000, "SpeedLane", "请先在“设置”中添加服务器", ToolTipIcon.Warning);
            OpenSettings();
            return;
        }

        string? password = null;
        if (server.Mode == ProxyMode.SshTunnel && server.Auth == AuthMethod.Password)
        {
            password = server.PlainPassword;
            if (string.IsNullOrEmpty(password))
            {
                _tray.ShowBalloonTip(4000, "SpeedLane",
                    $"服务器「{server.Name}」使用密码登录,请先在设置中填写密码", ToolTipIcon.Warning);
                OpenSettings();
                return;
            }
        }

        // 立刻进入“连接中”,托盘图标开始脉冲动画;阻塞操作全部放后台线程,UI 不卡顿
        _activeServer = server;
        SetPhase(Phase.Connecting);

        var preferredPort = _settings.LocalPort;
        Task.Run(() =>
        {
            if (server.Mode == ProxyMode.SshTunnel)
            {
                // 回收上次异常退出遗留的隧道进程,再找可用端口
                SshTunnel.ReapOrphan();
                var port = FindFreeLocalPort(preferredPort);
                if (port == null)
                {
                    Fail($"本地端口 {preferredPort} 起的 20 个端口都被占用,请在设置中修改本地 SOCKS5 端口");
                    return;
                }
                _activeLocalPort = port.Value;
                _tunnel.Start(server, _activeLocalPort, password);
            }

            try
            {
                _pacServer.Start();
            }
            catch (Exception ex)
            {
                _tunnel.Stop();
                Fail($"本地 PAC 服务启动失败:{ex.Message}");
                return;
            }

            _pacVersion++;
            try
            {
                SystemProxy.EnablePac($"{_pacServer.BaseUrl}?v={_pacVersion}");
            }
            catch (Exception ex)
            {
                _pacServer.Stop();
                _tunnel.Stop();
                Fail($"设置系统代理失败:{ex.Message}");
                return;
            }

            // git 命令行加速始终开启,仅对所选域名生效
            GitProxy.Apply(_settings, GitProxyUrl());

            _invoker.BeginInvoke(() => SetPhase(Phase.Connected));
        });
    }

    /// <summary>连接过程中出错:回到 UI 线程还原状态并提示</summary>
    private void Fail(string message)
    {
        _invoker.BeginInvoke(() =>
        {
            _activeServer = null;
            SetPhase(Phase.Disconnected);
            _tray.ShowBalloonTip(4000, "SpeedLane", message, ToolTipIcon.Error);
        });
    }

    public void Disable()
    {
        if (_phase != Phase.Connected && _phase != Phase.Connecting) return;
        SetPhase(Phase.Disconnecting);
        Task.Run(() =>
        {
            SystemProxy.DisablePac();
            _pacServer.Stop();
            _tunnel.Stop();
            GitProxy.Clear(_settings);
            _invoker.BeginInvoke(() =>
            {
                _activeServer = null;
                SetPhase(Phase.Disconnected);
            });
        });
    }

    /// <summary>退出时的同步拆除:必须在进程结束前还原系统代理,避免断网</summary>
    private void TeardownSync()
    {
        _pulseTimer.Stop();
        SystemProxy.DisablePac();
        _pacServer.Stop();
        _tunnel.Stop();
        GitProxy.Clear(_settings);
        _activeServer = null;
        _phase = Phase.Disconnected;
    }

    /// <summary>站点勾选变化:已启用时刷新 PAC 与 git 配置(阻塞命令放后台,勾选不卡顿)</summary>
    public void SettingsChanged()
    {
        if (!Enabled) return;
        _pacVersion++;
        var url = $"{_pacServer.BaseUrl}?v={_pacVersion}";
        var gitUrl = GitProxyUrl();
        Task.Run(() =>
        {
            try
            {
                SystemProxy.EnablePac(url);
                GitProxy.Apply(_settings, gitUrl);
            }
            catch
            {
            }
        });
    }

    /// <summary>服务器信息或默认服务器变化:已启用时重建整个链路</summary>
    public void ConnectionSettingsChanged()
    {
        if (_phase != Phase.Connected) return;
        // 先异步断开,完成后立即重连
        SetPhase(Phase.Disconnecting);
        Task.Run(() =>
        {
            SystemProxy.DisablePac();
            _pacServer.Stop();
            _tunnel.Stop();
            GitProxy.Clear(_settings);
            _invoker.BeginInvoke(() =>
            {
                _activeServer = null;
                SetPhase(Phase.Disconnected);
                Enable();
            });
        });
    }

    // MARK: 代理地址

    private string ProxyLine()
    {
        var server = _activeServer;
        if (server == null) return "DIRECT";
        return server.Mode switch
        {
            ProxyMode.SshTunnel =>
                $"SOCKS5 127.0.0.1:{_activeLocalPort}; SOCKS 127.0.0.1:{_activeLocalPort}",
            ProxyMode.RemoteSocks5 =>
                $"SOCKS5 {server.Host}:{server.RemotePort}; SOCKS {server.Host}:{server.RemotePort}",
            _ => $"PROXY {server.Host}:{server.RemotePort}",
        };
    }

    private string GitProxyUrl()
    {
        var server = _activeServer;
        if (server == null) return "";
        return server.Mode switch
        {
            ProxyMode.SshTunnel => $"socks5h://127.0.0.1:{_activeLocalPort}",
            ProxyMode.RemoteSocks5 => $"socks5h://{server.Host}:{server.RemotePort}",
            _ => $"http://{server.Host}:{server.RemotePort}",
        };
    }

    /// <summary>从首选端口起找一个空闲的本地端口(bind 探测,最多尝试 20 个)</summary>
    private static int? FindFreeLocalPort(int preferred)
    {
        for (var port = preferred; port < Math.Min(preferred + 20, 65536); port++)
        {
            try
            {
                var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
                listener.Start();
                listener.Stop();
                return port;
            }
            catch
            {
                // 被占用,试下一个
            }
        }
        return null;
    }

    // MARK: 窗口与退出

    private void OpenSettings()
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            return;
        }
        _settingsForm = new SettingsForm(_settings, this);
        _settingsForm.Show();
    }

    private void ExitApp()
    {
        if (Enabled || Busy) TeardownSync(); // 退出时务必还原系统代理,避免断网
        _tray.Visible = false;
        _tray.Dispose();
        ExitThread();
    }
}

/// <summary>运行时绘制托盘/窗口图标(蓝色圆角矩形 + 白色闪电)</summary>
public static class IconFactory
{
    public static Icon Bolt(bool active) =>
        Draw(active ? Color.FromArgb(0, 105, 255) : Color.FromArgb(120, 120, 128));

    /// <summary>“连接中”脉冲动画的一帧:蓝色在暗↔亮之间呼吸</summary>
    public static Icon BoltConnecting(int frame)
    {
        const int steps = 6;
        // 三角波 0→1→0,形成呼吸效果
        double t = 1.0 - Math.Abs((frame % steps) - (steps - 1) / 2.0) / ((steps - 1) / 2.0);
        int g = (int)(70 + t * 90);   // 70..160
        int b = (int)(150 + t * 105); // 150..255
        return Draw(Color.FromArgb(0, g, Math.Min(255, b)));
    }

    private static Icon Draw(Color background)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var brush = new SolidBrush(background);
            using var path = RoundedRect(new Rectangle(1, 1, 30, 30), 8);
            g.FillPath(brush, path);

            var bolt = new[]
            {
                new PointF(18, 3), new PointF(8, 18), new PointF(14.5f, 18),
                new PointF(13, 29), new PointF(24, 13.5f), new PointF(17, 13.5f),
            };
            g.FillPolygon(Brushes.White, bolt);
        }
        var handle = bmp.GetHicon();
        using var temp = Icon.FromHandle(handle);
        var icon = (Icon)temp.Clone();
        DestroyIcon(handle);
        return icon;
    }

    private static GraphicsPath RoundedRect(Rectangle rect, int radius)
    {
        var path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);
}
