using System.Diagnostics;

namespace SpeedLane;

/// <summary>为 git 命令行按域名设置代理(只影响列表内域名,其余仓库不走代理)</summary>
public static class GitProxy
{
    public static void Apply(AppSettings settings, string proxyUrl)
    {
        Clear(settings);
        var applied = new List<string>();
        foreach (var domain in settings.ActiveDomains)
        {
            if (RunGit("config", "--global", $"http.https://{domain}/.proxy", proxyUrl))
                applied.Add(domain);
        }
        settings.AppliedGitDomains = applied;
        settings.Save();
    }

    public static void Clear(AppSettings settings)
    {
        foreach (var domain in settings.AppliedGitDomains)
            RunGit("config", "--global", "--unset-all", $"http.https://{domain}/.proxy");
        settings.AppliedGitDomains = new List<string>();
        settings.Save();
    }

    private static bool RunGit(params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "git",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var process = Process.Start(psi)!;
            process.WaitForExit(10000);
            return process.HasExited && process.ExitCode == 0;
        }
        catch
        {
            // 未安装 git 时静默跳过
            return false;
        }
    }
}
