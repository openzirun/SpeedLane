using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace SpeedLane;

/// <summary>通过注册表管理系统"自动代理配置(PAC)",并通知 WinINET 立即生效</summary>
public static class SystemProxy
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    private const int InternetOptionSettingsChanged = 39;
    private const int InternetOptionRefresh = 37;

    [DllImport("wininet.dll", SetLastError = true)]
    private static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);

    public static void EnablePac(string url)
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true)
            ?? throw new InvalidOperationException("无法打开 Internet Settings 注册表键");
        key.SetValue("AutoConfigURL", url);
        Notify();
    }

    public static void DisablePac()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true);
            key?.DeleteValue("AutoConfigURL", throwOnMissingValue: false);
        }
        catch
        {
        }
        Notify();
    }

    private static void Notify()
    {
        InternetSetOption(IntPtr.Zero, InternetOptionSettingsChanged, IntPtr.Zero, 0);
        InternetSetOption(IntPtr.Zero, InternetOptionRefresh, IntPtr.Zero, 0);
    }
}
