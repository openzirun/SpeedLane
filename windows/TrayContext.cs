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

    private bool _enabled;
    private ServerConfig? _activeServer;
    private int _pacVersion;
    private SettingsForm? _settingsForm;

    public TrayContext()
    {
        _invoker.CreateControl();

        _pacServer = new PacServer(17890, () =>
            PacBuilder.Build(_settings.ActiveDomains, ProxyLine()));

        _tunnel.Failed += message => _invoker.BeginInvoke(() =>
        {
            if (!_enabled) return;
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

        var connect = new ToolStripMenuItem(_enabled ? "断开连接" : "连接选中站点");
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

    private string StatusText()
    {
        if (!_enabled) return "未启用,所有流量直连";
        var name = _activeServer?.Name ?? "";
        return $"已连接 {name},仅所选站点走加速";
    }

    private void UpdateUi()
    {
        _tray.Icon = IconFactory.Bolt(_enabled);
        _tray.Text = $"SpeedLane - {(_enabled ? $"已连接 {_activeServer?.Name}" : "未启用")}";
    }

    // MARK: 开关

    public void Toggle()
    {
        if (_enabled) Disable();
        else Enable();
    }

    public void Enable()
    {
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

        _activeServer = server;

        if (server.Mode == ProxyMode.SshTunnel)
            _tunnel.Start(server, _settings.LocalPort, password);

        try
        {
            _pacServer.Start();
        }
        catch (Exception ex)
        {
            _tunnel.Stop();
            _activeServer = null;
            _tray.ShowBalloonTip(4000, "SpeedLane", $"本地 PAC 服务启动失败:{ex.Message}", ToolTipIcon.Error);
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
            _activeServer = null;
            _tray.ShowBalloonTip(4000, "SpeedLane", $"设置系统代理失败:{ex.Message}", ToolTipIcon.Error);
            return;
        }

        // git 命令行加速始终开启,仅对所选域名生效
        GitProxy.Apply(_settings, GitProxyUrl());

        _enabled = true;
        UpdateUi();
    }

    public void Disable()
    {
        SystemProxy.DisablePac();
        _pacServer.Stop();
        _tunnel.Stop();
        GitProxy.Clear(_settings);
        _activeServer = null;
        _enabled = false;
        UpdateUi();
    }

    /// <summary>站点勾选变化:已启用时刷新 PAC 与 git 配置</summary>
    public void SettingsChanged()
    {
        if (!_enabled) return;
        _pacVersion++;
        SystemProxy.EnablePac($"{_pacServer.BaseUrl}?v={_pacVersion}");
        GitProxy.Apply(_settings, GitProxyUrl());
    }

    /// <summary>服务器信息或默认服务器变化:已启用时重建整个链路</summary>
    public void ConnectionSettingsChanged()
    {
        if (!_enabled) return;
        Disable();
        Enable();
    }

    // MARK: 代理地址

    private string ProxyLine()
    {
        var server = _activeServer;
        if (server == null) return "DIRECT";
        return server.Mode switch
        {
            ProxyMode.SshTunnel =>
                $"SOCKS5 127.0.0.1:{_settings.LocalPort}; SOCKS 127.0.0.1:{_settings.LocalPort}",
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
            ProxyMode.SshTunnel => $"socks5h://127.0.0.1:{_settings.LocalPort}",
            ProxyMode.RemoteSocks5 => $"socks5h://{server.Host}:{server.RemotePort}",
            _ => $"http://{server.Host}:{server.RemotePort}",
        };
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
        if (_enabled) Disable(); // 退出时务必还原系统代理,避免断网
        _tray.Visible = false;
        _tray.Dispose();
        ExitThread();
    }
}

/// <summary>运行时绘制托盘/窗口图标(蓝色圆角矩形 + 白色闪电)</summary>
public static class IconFactory
{
    public static Icon Bolt(bool active)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var background = new SolidBrush(
                active ? Color.FromArgb(0, 105, 255) : Color.FromArgb(120, 120, 128));
            using var path = RoundedRect(new Rectangle(1, 1, 30, 30), 8);
            g.FillPath(background, path);

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
