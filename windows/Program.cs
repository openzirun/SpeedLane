namespace SpeedLane;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // 单实例
        using var mutex = new Mutex(true, "SpeedLane-single-instance", out var isNew);
        if (!isNew)
        {
            MessageBox.Show("SpeedLane 已在运行,请查看系统托盘。", "SpeedLane");
            return;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayContext());
    }
}
