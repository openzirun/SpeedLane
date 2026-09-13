using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SpeedLane;

/// <summary>代理连接方式</summary>
public enum ProxyMode
{
    SshTunnel,
    RemoteSocks5,
    RemoteHttp,
}

/// <summary>SSH 认证方式</summary>
public enum AuthMethod
{
    Key,
    Password,
}

/// <summary>一台加速服务器的配置(密码经 DPAPI 加密后存储)</summary>
public class ServerConfig
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "新服务器";
    public string Host { get; set; } = "";
    public int SshPort { get; set; } = 22;
    public string User { get; set; } = "root";
    public AuthMethod Auth { get; set; } = AuthMethod.Key;
    public ProxyMode Mode { get; set; } = ProxyMode.SshTunnel;
    public int RemotePort { get; set; } = 1080;
    /// <summary>DPAPI(当前用户)加密后的密码,Base64</summary>
    public string? EncryptedPassword { get; set; }

    [JsonIgnore]
    public string PlainPassword
    {
        get
        {
            if (string.IsNullOrEmpty(EncryptedPassword)) return "";
            try
            {
                var data = ProtectedData.Unprotect(
                    Convert.FromBase64String(EncryptedPassword), null, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(data);
            }
            catch
            {
                return "";
            }
        }
        set
        {
            if (string.IsNullOrEmpty(value))
            {
                EncryptedPassword = null;
                return;
            }
            var data = ProtectedData.Protect(
                Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser);
            EncryptedPassword = Convert.ToBase64String(data);
        }
    }

    public override string ToString() =>
        string.IsNullOrEmpty(Host) ? Name : $"{Name} ({Host})";
}

/// <summary>用户自定义的加速站点:一个名称对应一组域名,可单独开/关</summary>
public class CustomSite
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public List<string> Domains { get; set; } = new();
    public bool Enabled { get; set; } = true;

    /// <summary>旧版单域名字段,仅用于读取旧配置,加载后迁移进 Domains</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Domain { get; set; }

    public void MigrateLegacy()
    {
        if (Domains.Count == 0 && !string.IsNullOrEmpty(Domain))
            Domains.Add(Domain);
        if (string.IsNullOrEmpty(Name))
            Name = Domains.FirstOrDefault() ?? "";
        Domain = null;
    }
}

/// <summary>域名输入的统一清洗:去协议、去路径、小写、去空白</summary>
public static class DomainParser
{
    public static string Clean(string raw) =>
        raw.Trim().ToLowerInvariant().Replace("https://", "").Replace("http://", "").Split('/')[0];

    /// <summary>解析多域名输入(逗号、空格、换行、分号分隔),过滤无效项并去重</summary>
    public static List<string> ParseList(string raw) =>
        raw.Split(new[] { ',', ';', ' ', '\n', '\r', '\t' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(Clean)
            .Where(d => d.Length > 0 && d.Contains('.'))
            .Distinct()
            .ToList();
}

/// <summary>预设的可加速站点(一个服务对应一组域名,由一个开关统一控制;与 macOS 版保持一致)</summary>
public record SitePreset(string Id, string Name, string[] Domains);

/// <summary>站点分组:把相关服务归在一起,组级操作批量开/关组内所有服务</summary>
public record SiteGroup(string Id, string Name, SitePreset[] Presets);

public static class Presets
{
    public static readonly SiteGroup[] Groups =
    {
        new("ai", "AI 助手", new SitePreset[]
        {
            // 网页版与桌面版共用;桌面版走系统代理,语音模式经 livekit,登录需 Cloudflare 验证同出口
            new("chatgpt", "ChatGPT", new[]
            {
                "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com",
                "ai.com", "livekit.cloud", "challenges.cloudflare.com",
            }),
            new("claude", "Claude", new[] { "claude.ai", "anthropic.com", "claudeusercontent.com" }),
            // 登录依赖 accounts.google.com,页面资源来自 gstatic / googleusercontent
            new("gemini", "Gemini", new[]
            {
                "gemini.google.com", "aistudio.google.com", "generativelanguage.googleapis.com",
                "deepmind.google", "accounts.google.com", "gstatic.com", "googleusercontent.com",
            }),
            new("perplexity", "Perplexity", new[] { "perplexity.ai", "pplx.ai" }),
            new("grok", "Grok", new[] { "grok.com", "x.ai" }),
        }),
        new("dev", "开发工具", new SitePreset[]
        {
            // 含 Copilot 接口域名(githubcopilot.com)
            new("github", "GitHub", new[]
            {
                "github.com", "githubusercontent.com", "githubassets.com",
                "github.io", "githubapp.com", "ghcr.io", "github.dev", "githubcopilot.com",
            }),
            new("stackoverflow", "Stack Overflow", new[]
            {
                "stackoverflow.com", "stackexchange.com", "sstatic.net",
                "superuser.com", "serverfault.com",
            }),
            new("huggingface", "Hugging Face", new[] { "huggingface.co", "hf.co" }),
            new("docker", "Docker Hub", new[] { "docker.io", "docker.com" }),
            new("npm", "npm", new[] { "npmjs.com", "npmjs.org" }),
            new("golang", "Go 模块代理", new[] { "proxy.golang.org", "sum.golang.org", "go.dev", "golang.org" }),
            new("k8s", "Kubernetes 镜像", new[] { "k8s.io", "gcr.io", "pkg.dev" }),
            new("crates", "crates.io", new[] { "crates.io" }),
            new("vscode", "VS Code 插件市场", new[] { "marketplace.visualstudio.com", "vsassets.io", "vscode-cdn.net" }),
            new("vercel", "Vercel", new[] { "vercel.com", "vercel.app" }),
        }),
        new("google", "Google 服务", new SitePreset[]
        {
            new("google", "Google", new[]
            {
                "google.com", "googleapis.com", "gstatic.com",
                "googleusercontent.com", "ggpht.com", "gvt1.com", "googlesource.com",
            }),
            new("youtube", "YouTube", new[]
            {
                "youtube.com", "ytimg.com", "googlevideo.com", "youtu.be",
            }),
        }),
        new("community", "社区", new SitePreset[]
        {
            new("reddit", "Reddit", new[] { "reddit.com", "redd.it", "redditstatic.com", "redditmedia.com" }),
            new("medium", "Medium", new[] { "medium.com" }),
            // 语音走 UDP,SOCKS 隧道下不可用,文字与图片正常
            new("discord", "Discord", new[] { "discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media" }),
            new("x", "X (Twitter)", new[] { "x.com", "twitter.com", "twimg.com", "t.co" }),
        }),
        new("reference", "资料", new SitePreset[]
        {
            new("wikipedia", "Wikipedia", new[] { "wikipedia.org", "wikimedia.org" }),
            new("udemy", "Udemy", new[] { "udemy.com", "udemycdn.com" }),
            new("archive", "Internet Archive", new[] { "archive.org" }),
        }),
    };

    /// <summary>所有预设的平铺列表(按分组顺序)</summary>
    public static readonly SitePreset[] All = Groups.SelectMany(g => g.Presets).ToArray();
}

/// <summary>应用设置,持久化到 %APPDATA%\SpeedLane\settings.json</summary>
public class AppSettings
{
    public List<ServerConfig> Servers { get; set; } = new();
    public Guid? DefaultServerId { get; set; }
    public int LocalPort { get; set; } = 1080;
    public HashSet<string> EnabledPresets { get; set; } = new() { "github" };
    public List<CustomSite> CustomSites { get; set; } = new();
    /// <summary>用户给预设追加的域名,按预设 id 存</summary>
    public Dictionary<string, List<string>> PresetExtraDomains { get; set; } = new();
    /// <summary>用户从预设里删掉的域名,按预设 id 存</summary>
    public Dictionary<string, List<string>> PresetRemovedDomains { get; set; } = new();
    public bool AutoConnect { get; set; }
    /// <summary>已写入 git 全局配置的域名,用于断开时清理</summary>
    public List<string> AppliedGitDomains { get; set; } = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static string Directory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SpeedLane");

    private static string FilePath => Path.Combine(Directory, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), JsonOptions);
                if (loaded != null)
                {
                    foreach (var site in loaded.CustomSites) site.MigrateLegacy();
                    return loaded;
                }
            }
        }
        catch
        {
            // 配置损坏时回退到默认值
        }
        return new AppSettings();
    }

    public void Save()
    {
        System.IO.Directory.CreateDirectory(Directory);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, JsonOptions));
    }

    /// <summary>默认连接的服务器(未设置时取第一台)</summary>
    [JsonIgnore]
    public ServerConfig? DefaultServer
    {
        get
        {
            if (DefaultServerId is Guid id)
            {
                var match = Servers.FirstOrDefault(s => s.Id == id);
                if (match != null) return match;
            }
            return Servers.FirstOrDefault();
        }
    }

    // MARK: 预设域名的用户修改

    /// <summary>预设实际生效的域名:默认列表去掉用户删除的,再加上用户追加的</summary>
    public List<string> EffectiveDomains(SitePreset preset)
    {
        var removed = PresetRemovedDomains.TryGetValue(preset.Id, out var r) ? r : new List<string>();
        var result = preset.Domains.Where(d => !removed.Contains(d)).ToList();
        if (PresetExtraDomains.TryGetValue(preset.Id, out var extra))
            foreach (var d in extra)
                if (!result.Contains(d)) result.Add(d);
        return result;
    }

    public bool IsPresetModified(SitePreset preset) =>
        (PresetExtraDomains.TryGetValue(preset.Id, out var e) && e.Count > 0)
        || (PresetRemovedDomains.TryGetValue(preset.Id, out var r) && r.Count > 0);

    public void AddDomain(SitePreset preset, string domain)
    {
        if (domain.Length == 0) return;
        // 之前删掉的默认域名重新加回来,只需撤销删除
        if (preset.Domains.Contains(domain))
        {
            if (PresetRemovedDomains.TryGetValue(preset.Id, out var removed))
            {
                removed.Remove(domain);
                if (removed.Count == 0) PresetRemovedDomains.Remove(preset.Id);
            }
            return;
        }
        if (!PresetExtraDomains.TryGetValue(preset.Id, out var extra))
            PresetExtraDomains[preset.Id] = extra = new List<string>();
        if (!extra.Contains(domain)) extra.Add(domain);
    }

    public void RemoveDomain(SitePreset preset, string domain)
    {
        if (preset.Domains.Contains(domain))
        {
            if (!PresetRemovedDomains.TryGetValue(preset.Id, out var removed))
                PresetRemovedDomains[preset.Id] = removed = new List<string>();
            if (!removed.Contains(domain)) removed.Add(domain);
        }
        else if (PresetExtraDomains.TryGetValue(preset.Id, out var extra))
        {
            extra.Remove(domain);
            if (extra.Count == 0) PresetExtraDomains.Remove(preset.Id);
        }
    }

    public void ResetPreset(SitePreset preset)
    {
        PresetExtraDomains.Remove(preset.Id);
        PresetRemovedDomains.Remove(preset.Id);
    }

    /// <summary>当前所有需要走代理的域名(去重、小写,只含已开启的)</summary>
    [JsonIgnore]
    public List<string> ActiveDomains
    {
        get
        {
            var result = new List<string>();
            foreach (var preset in Presets.All)
                if (EnabledPresets.Contains(preset.Id))
                    result.AddRange(EffectiveDomains(preset));
            result.AddRange(CustomSites.Where(s => s.Enabled).SelectMany(s => s.Domains));
            return result.Select(d => d.ToLowerInvariant()).Distinct().ToList();
        }
    }
}

/// <summary>生成 PAC 脚本:命中列表内域名(含子域名)走代理,其余全部直连</summary>
public static class PacBuilder
{
    public static string Build(IEnumerable<string> domains, string proxyLine)
    {
        var list = string.Join(",\n  ", domains.Select(d => $"\"{d}\""));
        return $$"""
        var domains = [
          {{list}}
        ];

        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          for (var i = 0; i < domains.length; i++) {
            var d = domains[i];
            if (host === d ||
                (host.length > d.length &&
                 host.substring(host.length - d.length - 1) === "." + d)) {
              return "{{proxyLine}}";
            }
          }
          return "DIRECT";
        }
        """;
    }
}
