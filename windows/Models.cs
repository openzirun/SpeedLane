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

/// <summary>用户自定义的加速域名</summary>
public class CustomSite
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Domain { get; set; } = "";
    public bool Enabled { get; set; } = true;
}

/// <summary>预设的可加速站点分组(与 macOS 版保持一致)</summary>
public record SitePreset(string Id, string Name, string[] Domains);

public static class Presets
{
    public static readonly SitePreset[] All =
    {
        new("github", "GitHub", new[]
        {
            "github.com", "githubusercontent.com", "githubassets.com",
            "github.io", "githubapp.com", "ghcr.io", "github.dev",
        }),
        new("google", "Google", new[]
        {
            "google.com", "googleapis.com", "gstatic.com",
            "googleusercontent.com", "ggpht.com", "gvt1.com", "googlesource.com",
        }),
        new("youtube", "YouTube", new[]
        {
            "youtube.com", "ytimg.com", "googlevideo.com", "youtu.be",
        }),
        new("stackoverflow", "Stack Overflow", new[]
        {
            "stackoverflow.com", "stackexchange.com", "sstatic.net",
            "superuser.com", "serverfault.com",
        }),
        new("huggingface", "Hugging Face", new[] { "huggingface.co", "hf.co" }),
        new("docker", "Docker Hub", new[] { "docker.io", "docker.com" }),
        new("npm", "npm", new[] { "npmjs.com", "npmjs.org" }),
        new("wikipedia", "Wikipedia", new[] { "wikipedia.org", "wikimedia.org" }),
    };
}

/// <summary>应用设置,持久化到 %APPDATA%\SpeedLane\settings.json</summary>
public class AppSettings
{
    public List<ServerConfig> Servers { get; set; } = new();
    public Guid? DefaultServerId { get; set; }
    public int LocalPort { get; set; } = 1080;
    public HashSet<string> EnabledPresets { get; set; } = new() { "github" };
    public List<CustomSite> CustomSites { get; set; } = new();
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
                if (loaded != null) return loaded;
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

    /// <summary>当前所有需要走代理的域名(去重、小写,只含已开启的)</summary>
    [JsonIgnore]
    public List<string> ActiveDomains
    {
        get
        {
            var result = new List<string>();
            foreach (var preset in Presets.All)
                if (EnabledPresets.Contains(preset.Id))
                    result.AddRange(preset.Domains);
            result.AddRange(CustomSites.Where(s => s.Enabled).Select(s => s.Domain));
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
