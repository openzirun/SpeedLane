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
    // 三层结构:分组节点 → 站点节点 → 域名节点;勾选分组即批量开关组内站点,域名节点不带复选框
    private readonly TreeView _sites = new()
    {
        Dock = DockStyle.Fill,
        CheckBoxes = true,
        ShowLines = false,
        ShowPlusMinus = true,
        ShowRootLines = false,
        FullRowSelect = true,
        HideSelection = false,
        LabelEdit = true,
    };
    private readonly TextBox _newSiteName = new() { PlaceholderText = "站点名称", Width = 110 };
    private readonly TextBox _newSiteDomains = new() { PlaceholderText = "域名,多个用逗号或空格分隔", Width = 260 };
    private readonly TextBox _newDomain = new() { PlaceholderText = "如 example.com", Width = 200 };
    private readonly Button _addDomainButton = new() { Text = "添加到选中站点", AutoSize = true };
    private readonly Button _removeButton = new() { Text = "删除选中项", AutoSize = true };
    private readonly Button _resetButton = new() { Text = "恢复默认", AutoSize = true };

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
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 4, Padding = new Padding(8) };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        layout.Controls.Add(_sites, 0, 0);

        // 第一行:添加自定义站点(名称 + 多域名)
        var addSiteRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        var addSiteButton = new Button { Text = "添加自定义站点", AutoSize = true };
        addSiteButton.Click += (_, _) => AddCustomSite();
        addSiteRow.Controls.Add(new Label { Text = "自定义站点:", AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
        addSiteRow.Controls.Add(_newSiteName);
        addSiteRow.Controls.Add(_newSiteDomains);
        addSiteRow.Controls.Add(addSiteButton);
        layout.Controls.Add(addSiteRow, 0, 1);

        // 第二行:对选中站点/域名的操作
        var domainRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        _addDomainButton.Click += (_, _) => AddDomainToSelected();
        _removeButton.Click += (_, _) => RemoveSelected();
        _resetButton.Click += (_, _) => ResetSelectedPreset();
        domainRow.Controls.Add(new Label { Text = "域名:", AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
        domainRow.Controls.Add(_newDomain);
        domainRow.Controls.Add(_addDomainButton);
        domainRow.Controls.Add(_removeButton);
        domainRow.Controls.Add(_resetButton);
        layout.Controls.Add(domainRow, 0, 2);

        layout.Controls.Add(new Label
        {
            Text = "展开站点可查看域名;预设域名可增删,改过的预设可恢复默认;双击自定义站点名可改名。未勾选的站点一律直连",
            AutoSize = true,
            ForeColor = Color.Gray,
        }, 0, 3);

        page.Controls.Add(layout);

        // 分组节点始终展开,站点节点可折叠
        _sites.BeforeCollapse += (_, e) => e.Cancel = e.Node?.Parent is null;
        // 控件句柄重建时 WinForms 会重新添加所有节点,状态图标会丢,重新隐藏一次
        _sites.HandleCreated += (_, _) => BeginInvoke(() =>
        {
            foreach (TreeNode groupNode in _sites.Nodes)
                foreach (TreeNode node in groupNode.Nodes)
                    foreach (TreeNode domainNode in node.Nodes) HideCheckBox(domainNode);
        });
        _sites.AfterSelect += (_, _) => UpdateSiteButtons();
        _sites.AfterCheck += (_, e) =>
        {
            // 程序内部设置 Checked 时 Action 为 Unknown,只响应用户操作,避免递归
            if (_loading || e.Action == TreeViewAction.Unknown || e.Node is null) return;
            switch (e.Node.Level)
            {
                case 0:
                    // 勾选分组:同步组内所有站点
                    foreach (TreeNode child in e.Node.Nodes) child.Checked = e.Node.Checked;
                    break;
                case 1:
                    // 勾选站点:组节点只在全部开启时显示为勾选
                    var parent = e.Node.Parent!;
                    parent.Checked = parent.Nodes.Cast<TreeNode>().All(n => n.Checked);
                    break;
                default:
                    // 域名节点没有复选框,键盘空格触发的勾选直接撤销
                    e.Node.Checked = false;
                    return;
            }
            SaveSitesFromList();
            _tray.SettingsChanged();
        };
        // 只允许给自定义站点改名;编辑时把节点文字换成纯名称
        _sites.BeforeLabelEdit += (_, e) =>
        {
            if (e.Node?.Tag is CustomSite site) e.Node.Text = site.Name;
            else e.CancelEdit = true;
        };
        _sites.AfterLabelEdit += (_, e) =>
        {
            if (e.Node?.Tag is CustomSite site && !string.IsNullOrWhiteSpace(e.Label))
            {
                site.Name = e.Label.Trim();
                _settings.Save();
            }
            e.CancelEdit = true;
            BeginInvoke(ReloadSitesList);
        };
        return page;
    }

    private void ReloadSitesList()
    {
        _loading = true;
        // 记住已展开的站点,重建后恢复
        var expandedKeys = new HashSet<string>();
        foreach (TreeNode groupNode in _sites.Nodes)
            foreach (TreeNode node in groupNode.Nodes)
                if (node.IsExpanded) expandedKeys.Add(SiteKey(node));
        var selectedKey = _sites.SelectedNode is { } sel ? SiteKey(sel) : null;

        _sites.BeginUpdate();
        _sites.Nodes.Clear();
        foreach (var group in Presets.Groups)
        {
            var groupNode = new TreeNode(group.Name) { Tag = group };
            foreach (var preset in group.Presets)
            {
                var domains = _settings.EffectiveDomains(preset);
                var suffix = _settings.IsPresetModified(preset) ? " · 已修改" : "";
                var node = new TreeNode($"{preset.Name}({domains.Count} 个域名{suffix})")
                {
                    Tag = preset,
                    Checked = _settings.EnabledPresets.Contains(preset.Id),
                };
                foreach (var d in domains) node.Nodes.Add(DomainNode(d));
                groupNode.Nodes.Add(node);
            }
            groupNode.Checked = groupNode.Nodes.Cast<TreeNode>().All(n => n.Checked);
            _sites.Nodes.Add(groupNode);
        }
        if (_settings.CustomSites.Count > 0)
        {
            var customNode = new TreeNode("自定义站点");
            foreach (var site in _settings.CustomSites)
            {
                var node = new TreeNode($"{site.Name}({site.Domains.Count} 个域名)") { Tag = site, Checked = site.Enabled };
                foreach (var d in site.Domains) node.Nodes.Add(DomainNode(d));
                customNode.Nodes.Add(node);
            }
            customNode.Checked = _settings.CustomSites.All(s => s.Enabled);
            _sites.Nodes.Add(customNode);
        }

        // 分组展开、站点默认折叠(恢复之前展开的),域名节点去掉复选框
        foreach (TreeNode groupNode in _sites.Nodes)
        {
            groupNode.Expand();
            foreach (TreeNode node in groupNode.Nodes)
            {
                var key = SiteKey(node);
                if (expandedKeys.Contains(key)) node.Expand();
                if (key == selectedKey) _sites.SelectedNode = node;
                foreach (TreeNode domainNode in node.Nodes) HideCheckBox(domainNode);
            }
        }
        _sites.EndUpdate();
        _loading = false;
        UpdateSiteButtons();
    }

    private static TreeNode DomainNode(string domain) =>
        new(domain) { Tag = domain, ForeColor = Color.DimGray };

    private static string SiteKey(TreeNode node) => node.Tag switch
    {
        SitePreset p => p.Id,
        CustomSite c => c.Id.ToString(),
        string => node.Parent is { } parent ? SiteKey(parent) : "",
        _ => node.Text,
    };

    /// <summary>选中的站点节点(选中域名时取其父节点)</summary>
    private TreeNode? SelectedSiteNode()
    {
        var node = _sites.SelectedNode;
        if (node?.Tag is string) node = node.Parent;
        return node?.Tag is SitePreset or CustomSite ? node : null;
    }

    private void UpdateSiteButtons()
    {
        var siteNode = SelectedSiteNode();
        _addDomainButton.Enabled = siteNode != null;
        _removeButton.Enabled = _sites.SelectedNode?.Tag is string or CustomSite;
        _removeButton.Text = _sites.SelectedNode?.Tag is CustomSite ? "删除选中站点" : "删除选中域名";
        _resetButton.Enabled = siteNode?.Tag is SitePreset preset && _settings.IsPresetModified(preset);
    }

    private void SaveSitesFromList()
    {
        foreach (TreeNode groupNode in _sites.Nodes)
        {
            foreach (TreeNode node in groupNode.Nodes)
            {
                switch (node.Tag)
                {
                    case SitePreset preset:
                        if (node.Checked) _settings.EnabledPresets.Add(preset.Id);
                        else _settings.EnabledPresets.Remove(preset.Id);
                        break;
                    case CustomSite site:
                        site.Enabled = node.Checked;
                        break;
                }
            }
        }
        _settings.Save();
    }

    private void AddCustomSite()
    {
        var domains = DomainParser.ParseList(_newSiteDomains.Text);
        if (domains.Count == 0) return;
        var name = _newSiteName.Text.Trim();
        _settings.CustomSites.Add(new CustomSite
        {
            Name = name.Length > 0 ? name : domains[0],
            Domains = domains,
        });
        _settings.Save();
        _newSiteName.Text = "";
        _newSiteDomains.Text = "";
        ReloadSitesList();
        _tray.SettingsChanged();
    }

    private void AddDomainToSelected()
    {
        var domain = DomainParser.Clean(_newDomain.Text);
        if (domain.Length == 0 || !domain.Contains('.')) return;
        switch (SelectedSiteNode()?.Tag)
        {
            case SitePreset preset:
                _settings.AddDomain(preset, domain);
                break;
            case CustomSite site:
                if (!site.Domains.Contains(domain)) site.Domains.Add(domain);
                break;
            default:
                return;
        }
        _settings.Save();
        _newDomain.Text = "";
        ReloadSitesList();
        _tray.SettingsChanged();
    }

    private void RemoveSelected()
    {
        var node = _sites.SelectedNode;
        switch (node?.Tag)
        {
            case CustomSite site:
                _settings.CustomSites.Remove(site);
                break;
            case string domain when node.Parent?.Tag is SitePreset preset:
                _settings.RemoveDomain(preset, domain);
                break;
            case string domain when node.Parent?.Tag is CustomSite site:
                site.Domains.Remove(domain);
                break;
            default:
                return;
        }
        _settings.Save();
        ReloadSitesList();
        _tray.SettingsChanged();
    }

    private void ResetSelectedPreset()
    {
        if (SelectedSiteNode()?.Tag is not SitePreset preset) return;
        _settings.ResetPreset(preset);
        _settings.Save();
        ReloadSitesList();
        _tray.SettingsChanged();
    }

    // MARK: 隐藏单个节点的复选框(TreeView 没有公开 API,通过 TVM_SETITEM 清空状态图标)

    private const int TvFirst = 0x1100;
    private const int TvmSetItem = TvFirst + 63;
    private const int TvifState = 0x0008;
    private const int TvisStateImageMask = 0xF000;

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct TvItem
    {
        public int Mask;
        public IntPtr Item;
        public int State;
        public int StateMask;
        public IntPtr Text;
        public int TextMax;
        public int Image;
        public int SelectedImage;
        public int Children;
        public IntPtr Param;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, ref TvItem lParam);

    private void HideCheckBox(TreeNode node)
    {
        var item = new TvItem
        {
            Item = node.Handle,
            Mask = TvifState,
            StateMask = TvisStateImageMask,
            State = 0,
        };
        SendMessage(_sites.Handle, TvmSetItem, IntPtr.Zero, ref item);
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
