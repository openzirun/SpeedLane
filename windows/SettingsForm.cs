namespace SpeedLane;

/// <summary>设置窗口:服务器 / 加速站点 / 通用 三个标签页</summary>
public class SettingsForm : Form
{
    private readonly AppSettings _settings;
    private readonly TrayContext _tray;
    private bool _loading; // 加载字段时抑制变更事件

    // 服务器页控件
    private readonly ListBox _serverList = new() { Dock = DockStyle.Fill };
    private readonly TextBox _name = new();
    private readonly TextBox _host = new();
    private readonly ComboBox _mode = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox _sshPort = new();
    private readonly TextBox _user = new();
    private readonly ComboBox _auth = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox _password = new() { UseSystemPasswordChar = true };
    private readonly TextBox _remotePort = new();
    private readonly Button _setDefault = new() { Text = "设为默认连接", AutoSize = true };
    private readonly Button _test = new() { Text = "测试连接", AutoSize = true };
    private readonly Label _testResult = new() { AutoSize = true, MaximumSize = new Size(300, 0) };

    // 站点页控件
    private readonly CheckedListBox _sites = new() { Dock = DockStyle.Fill, CheckOnClick = true };
    private readonly TextBox _newDomain = new() { PlaceholderText = "如 example.com", Width = 200 };

    // 通用页控件
    private readonly CheckBox _launchAtLogin = new() { Text = "开机自动运行", AutoSize = true };
    private readonly CheckBox _autoConnect = new() { Text = "启动后自动连接默认服务器", AutoSize = true };
    private readonly TextBox _localPort = new() { Width = 80 };

    public SettingsForm(AppSettings settings, TrayContext tray)
    {
        _settings = settings;
        _tray = tray;

        Text = "SpeedLane 设置";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(620, 440);
        MinimizeBox = true;
        MaximizeBox = false;
        FormBorderStyle = FormBorderStyle.FixedSingle;

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildServersTab());
        tabs.TabPages.Add(BuildSitesTab());
        tabs.TabPages.Add(BuildGeneralTab());
        tabs.TabPages.Add(BuildAboutTab());
        Controls.Add(tabs);

        ReloadServerList();
        ReloadSitesList();
        LoadGeneral();
    }

    // MARK: 服务器标签页

    private TabPage BuildServersTab()
    {
        var page = new TabPage("服务器");
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(8) };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 200));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        // 左侧:列表 + 增删按钮
        var left = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2 };
        left.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        left.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        left.Controls.Add(_serverList, 0, 0);
        var listButtons = new FlowLayoutPanel { AutoSize = true };
        var add = new Button { Text = "＋", Width = 36 };
        var remove = new Button { Text = "－", Width = 36 };
        add.Click += (_, _) => AddServer();
        remove.Click += (_, _) => RemoveServer();
        listButtons.Controls.Add(add);
        listButtons.Controls.Add(remove);
        left.Controls.Add(listButtons, 0, 1);
        layout.Controls.Add(left, 0, 0);

        // 右侧:表单
        var form = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12, 4, 4, 4), AutoScroll = true,
        };
        form.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        form.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        void AddRow(string label, Control control)
        {
            var l = new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Padding = new Padding(0, 6, 0, 0) };
            control.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            form.Controls.Add(l);
            form.Controls.Add(control);
        }

        _mode.Items.AddRange(new object[]
        {
            "SSH 隧道(推荐,服务器无需配置)", "服务器上的 SOCKS5 代理", "服务器上的 HTTP 代理",
        });
        _auth.Items.AddRange(new object[] { "SSH 密钥(免密登录)", "密码" });

        AddRow("名称", _name);
        AddRow("地址(IP/域名)", _host);
        AddRow("连接方式", _mode);
        AddRow("SSH 端口", _sshPort);
        AddRow("用户名", _user);
        AddRow("认证方式", _auth);
        AddRow("密码", _password);
        AddRow("代理端口", _remotePort);

        var buttons = new FlowLayoutPanel { AutoSize = true };
        buttons.Controls.Add(_setDefault);
        buttons.Controls.Add(_test);
        form.Controls.Add(new Label());
        form.Controls.Add(buttons);
        form.Controls.Add(new Label());
        form.Controls.Add(_testResult);

        layout.Controls.Add(form, 1, 0);
        page.Controls.Add(layout);

        // 事件
        _serverList.SelectedIndexChanged += (_, _) => LoadServerFields();
        _name.TextChanged += (_, _) => SaveServerFields();
        _host.TextChanged += (_, _) => SaveServerFields();
        _sshPort.TextChanged += (_, _) => SaveServerFields();
        _user.TextChanged += (_, _) => SaveServerFields();
        _remotePort.TextChanged += (_, _) => SaveServerFields();
        _password.TextChanged += (_, _) => SaveServerFields();
        _mode.SelectedIndexChanged += (_, _) => { SaveServerFields(); UpdateFieldVisibility(); };
        _auth.SelectedIndexChanged += (_, _) => { SaveServerFields(); UpdateFieldVisibility(); };
        _setDefault.Click += (_, _) =>
        {
            if (SelectedServer() is { } server)
            {
                _settings.DefaultServerId = server.Id;
                _settings.Save();
                ReloadServerList(server.Id);
                _tray.ConnectionSettingsChanged();
            }
        };
        _test.Click += async (_, _) =>
        {
            if (SelectedServer() is not { } server) return;
            _test.Enabled = false;
            _testResult.Text = "测试中…";
            var password = server.Auth == AuthMethod.Password ? server.PlainPassword : null;
            var error = await Task.Run(() => SshTunnel.Test(server, password));
            _testResult.Text = error == null ? "✓ 连接成功" : $"失败:{error}";
            _testResult.ForeColor = error == null ? Color.Green : Color.Firebrick;
            _test.Enabled = true;
        };

        return page;
    }

    private ServerConfig? SelectedServer() => _serverList.SelectedItem as ServerConfig;

    private void ReloadServerList(Guid? select = null)
    {
        var target = select ?? SelectedServer()?.Id ?? _settings.DefaultServer?.Id;
        _serverList.Items.Clear();
        foreach (var server in _settings.Servers) _serverList.Items.Add(server);
        var index = _settings.Servers.FindIndex(s => s.Id == target);
        _serverList.SelectedIndex = index >= 0 ? index : (_serverList.Items.Count > 0 ? 0 : -1);
        LoadServerFields();
    }

    private void LoadServerFields()
    {
        _loading = true;
        var server = SelectedServer();
        var has = server != null;
        foreach (var control in new Control[] { _name, _host, _mode, _sshPort, _user, _auth, _password, _remotePort, _setDefault, _test })
            control.Enabled = has;
        if (server != null)
        {
            _name.Text = server.Name;
            _host.Text = server.Host;
            _mode.SelectedIndex = (int)server.Mode;
            _sshPort.Text = server.SshPort.ToString();
            _user.Text = server.User;
            _auth.SelectedIndex = (int)server.Auth;
            _password.Text = server.PlainPassword;
            _remotePort.Text = server.RemotePort.ToString();
        }
        _testResult.Text = "";
        _loading = false;
        UpdateFieldVisibility();
    }

    private void UpdateFieldVisibility()
    {
        var isTunnel = _mode.SelectedIndex == (int)ProxyMode.SshTunnel;
        _sshPort.Enabled = isTunnel;
        _user.Enabled = isTunnel;
        _auth.Enabled = isTunnel;
        _password.Enabled = isTunnel && _auth.SelectedIndex == (int)AuthMethod.Password;
        _remotePort.Enabled = !isTunnel;
    }

    private void SaveServerFields()
    {
        if (_loading || SelectedServer() is not { } server) return;
        server.Name = _name.Text;
        server.Host = _host.Text.Trim();
        if (_mode.SelectedIndex >= 0) server.Mode = (ProxyMode)_mode.SelectedIndex;
        if (int.TryParse(_sshPort.Text, out var sp)) server.SshPort = sp;
        server.User = _user.Text.Trim();
        if (_auth.SelectedIndex >= 0) server.Auth = (AuthMethod)_auth.SelectedIndex;
        server.PlainPassword = _password.Text;
        if (int.TryParse(_remotePort.Text, out var rp)) server.RemotePort = rp;
        _settings.Save();

        // 刷新列表显示的名称/地址
        var index = _serverList.SelectedIndex;
        if (index >= 0)
        {
            _loading = true;
            _serverList.Items[index] = server;
            _serverList.SelectedIndex = index;
            _loading = false;
        }
    }

    private void AddServer()
    {
        var server = new ServerConfig { Name = $"服务器 {_settings.Servers.Count + 1}" };
        _settings.Servers.Add(server);
        _settings.DefaultServerId ??= server.Id;
        _settings.Save();
        ReloadServerList(server.Id);
    }

    private void RemoveServer()
    {
        if (SelectedServer() is not { } server) return;
        _settings.Servers.Remove(server);
        if (_settings.DefaultServerId == server.Id)
            _settings.DefaultServerId = _settings.Servers.FirstOrDefault()?.Id;
        _settings.Save();
        ReloadServerList();
        _tray.ConnectionSettingsChanged();
    }

    // MARK: 加速站点标签页

    private TabPage BuildSitesTab()
    {
        var page = new TabPage("加速站点");
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, Padding = new Padding(8) };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        layout.Controls.Add(_sites, 0, 0);

        var addRow = new FlowLayoutPanel { AutoSize = true };
        var addButton = new Button { Text = "添加自定义域名", AutoSize = true };
        var removeButton = new Button { Text = "删除选中的自定义域名", AutoSize = true };
        addButton.Click += (_, _) => AddCustomDomain();
        removeButton.Click += (_, _) => RemoveCustomDomain();
        addRow.Controls.Add(_newDomain);
        addRow.Controls.Add(addButton);
        addRow.Controls.Add(removeButton);
        layout.Controls.Add(addRow, 0, 1);

        layout.Controls.Add(new Label
        {
            Text = "未勾选的站点一律直连;git 命令行加速默认开启,仅对勾选域名的 clone/push 生效",
            AutoSize = true,
            ForeColor = Color.Gray,
        }, 0, 2);

        page.Controls.Add(layout);

        _sites.ItemCheck += (_, e) =>
        {
            if (_loading) return;
            // ItemCheck 在状态改变前触发,延迟到改变后再保存
            BeginInvoke(() =>
            {
                SaveSitesFromList();
                _tray.SettingsChanged();
            });
        };
        return page;
    }

    private void ReloadSitesList()
    {
        _loading = true;
        _sites.Items.Clear();
        foreach (var preset in Presets.All)
            _sites.Items.Add($"{preset.Name}({preset.Domains.Length} 个域名)",
                _settings.EnabledPresets.Contains(preset.Id));
        foreach (var site in _settings.CustomSites)
            _sites.Items.Add($"{site.Domain}(自定义)", site.Enabled);
        _loading = false;
    }

    private void SaveSitesFromList()
    {
        for (var i = 0; i < Presets.All.Length; i++)
        {
            var id = Presets.All[i].Id;
            if (_sites.GetItemChecked(i)) _settings.EnabledPresets.Add(id);
            else _settings.EnabledPresets.Remove(id);
        }
        for (var i = 0; i < _settings.CustomSites.Count; i++)
            _settings.CustomSites[i].Enabled = _sites.GetItemChecked(Presets.All.Length + i);
        _settings.Save();
    }

    private void AddCustomDomain()
    {
        var domain = _newDomain.Text.Trim().ToLowerInvariant()
            .Replace("https://", "").Replace("http://", "").Split('/')[0];
        if (domain.Length == 0 || !domain.Contains('.')) return;
        if (_settings.CustomSites.Any(s => s.Domain == domain)) return;
        _settings.CustomSites.Add(new CustomSite { Domain = domain });
        _settings.Save();
        _newDomain.Text = "";
        ReloadSitesList();
        _tray.SettingsChanged();
    }

    private void RemoveCustomDomain()
    {
        var index = _sites.SelectedIndex - Presets.All.Length;
        if (index < 0 || index >= _settings.CustomSites.Count) return;
        _settings.CustomSites.RemoveAt(index);
        _settings.Save();
        ReloadSitesList();
        _tray.SettingsChanged();
    }

    // MARK: 通用标签页

    private TabPage BuildGeneralTab()
    {
        var page = new TabPage("通用");
        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(12),
        };

        layout.Controls.Add(_launchAtLogin);
        layout.Controls.Add(_autoConnect);

        var portRow = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 12, 0, 0) };
        portRow.Controls.Add(new Label
        {
            Text = "本地 SOCKS5 端口(修改后需重新连接)", AutoSize = true, Padding = new Padding(0, 6, 0, 0),
        });
        portRow.Controls.Add(_localPort);
        layout.Controls.Add(portRow);

        page.Controls.Add(layout);

        _launchAtLogin.CheckedChanged += (_, _) => { if (!_loading) LaunchAtLogin.Set(_launchAtLogin.Checked); };
        _autoConnect.CheckedChanged += (_, _) =>
        {
            if (_loading) return;
            _settings.AutoConnect = _autoConnect.Checked;
            _settings.Save();
        };
        _localPort.TextChanged += (_, _) =>
        {
            if (_loading) return;
            if (int.TryParse(_localPort.Text, out var port) && port is > 0 and < 65536)
            {
                _settings.LocalPort = port;
                _settings.Save();
            }
        };
        return page;
    }

    private void LoadGeneral()
    {
        _loading = true;
        _launchAtLogin.Checked = LaunchAtLogin.IsEnabled;
        _autoConnect.Checked = _settings.AutoConnect;
        _localPort.Text = _settings.LocalPort.ToString();
        _loading = false;
    }

    // MARK: 关于标签页

    private const string RepoUrl = "https://github.com/openzirun/SpeedLane";
    private const string ReleasesUrl = RepoUrl + "/releases";

    private TabPage BuildAboutTab()
    {
        var page = new TabPage("关于");
        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(24),
        };

        var icon = new PictureBox
        {
            Image = IconFactory.Bolt(active: true).ToBitmap(),
            Size = new Size(64, 64),
            SizeMode = PictureBoxSizeMode.Zoom,
            Margin = new Padding(0, 0, 0, 8),
        };

        var title = new Label
        {
            Text = "SpeedLane",
            Font = new Font(Font.FontFamily, 16, FontStyle.Bold),
            AutoSize = true,
        };

        // 版本号运行时取自程序集元数据(csproj 的 <Version>),与发布版本单一来源
        var version = new Label
        {
            Text = $"版本 {Application.ProductVersion.Split('+')[0]}",
            AutoSize = true,
            ForeColor = Color.Gray,
        };

        var tagline = new Label
        {
            Text = "只给选中的网站开一条快车道",
            AutoSize = true,
            ForeColor = Color.Gray,
            Margin = new Padding(3, 0, 3, 12),
        };

        var repoLink = MakeLink("GitHub 项目主页", RepoUrl);
        var releasesLink = MakeLink("下载最新版本(Releases)", ReleasesUrl);

        var license = new Label
        {
            Text = "MIT License © 2026 SpeedLane Contributors",
            AutoSize = true,
            ForeColor = Color.Gray,
            Margin = new Padding(3, 12, 3, 0),
        };

        layout.Controls.AddRange(new Control[] { icon, title, version, tagline, repoLink, releasesLink, license });
        page.Controls.Add(layout);
        return page;
    }

    private static LinkLabel MakeLink(string text, string url)
    {
        var link = new LinkLabel { Text = text, AutoSize = true, Margin = new Padding(3, 3, 3, 3) };
        link.LinkClicked += (_, _) =>
        {
            try
            {
                System.Diagnostics.Process.Start(
                    new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
            }
            catch
            {
            }
        };
        return link;
    }
}
