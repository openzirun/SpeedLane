# SpeedLane 本地测试脚本(Windows,在 PowerShell 里运行)
#   .\windows\run.ps1          编译并启动
#   .\windows\run.ps1 -Stop    停止实例并还原系统代理
#   .\windows\run.ps1 -Backup  备份当前配置
#   .\windows\run.ps1 -Restore 还原最近一次备份
param(
    [switch]$Stop,
    [switch]$Backup,
    [switch]$Restore
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$settingsDir = Join-Path $env:APPDATA "SpeedLane"
$settingsFile = Join-Path $settingsDir "settings.json"
$backupFile = Join-Path $env:USERPROFILE ".speedlane-settings-backup.json"
$proxyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

function Stop-Instances {
    Get-Process SpeedLane -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# 还原系统代理:App 正常退出会自己还原,异常退出时用这个兜底
function Restore-Proxy {
    $current = Get-ItemProperty -Path $proxyKey -Name AutoConfigURL -ErrorAction SilentlyContinue
    if ($current -and $current.AutoConfigURL) {
        Remove-ItemProperty -Path $proxyKey -Name AutoConfigURL
        Write-Host "已清除系统 PAC 设置" -ForegroundColor Yellow
    } else {
        Write-Host "系统代理无残留" -ForegroundColor Green
    }
}

if ($Stop) {
    Stop-Instances
    Restore-Proxy
    $tunnels = Get-Process ssh -ErrorAction SilentlyContinue
    if ($tunnels) {
        Write-Host "发现残留的 ssh 进程:" -ForegroundColor Yellow
        $tunnels | Format-Table Id, ProcessName -AutoSize
        $answer = Read-Host "是否结束这些进程? [y/N]"
        if ($answer -eq "y") { $tunnels | Stop-Process -Force; Write-Host "已结束" -ForegroundColor Green }
    }
    Write-Host "已停止" -ForegroundColor Green
    exit
}

if ($Backup) {
    if (Test-Path $settingsFile) {
        Copy-Item $settingsFile $backupFile -Force
        Write-Host "配置已备份到 $backupFile" -ForegroundColor Green
    } else {
        Write-Host "还没有配置文件,跳过备份" -ForegroundColor Yellow
    }
}

if ($Restore) {
    if (-not (Test-Path $backupFile)) { Write-Host "没有找到备份文件 $backupFile" -ForegroundColor Yellow; exit 1 }
    Stop-Instances
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
    Copy-Item $backupFile $settingsFile -Force
    Write-Host "配置已还原,重新运行 .\windows\run.ps1 生效" -ForegroundColor Green
    exit
}

Write-Host "正在编译…" -ForegroundColor Green
dotnet build windows\SpeedLane.Win.csproj -c Debug --nologo -v q
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$exe = Join-Path $root "windows\bin\Debug\net8.0-windows\SpeedLane.exe"
if (-not (Test-Path $exe)) { Write-Host "没有找到 $exe" -ForegroundColor Red; exit 1 }

Stop-Instances
Start-Process $exe

@"

已启动,图标在系统托盘(右下角,可能需要点箭头展开)

  测试要点
    1. 双击托盘图标打开设置 -> 加速站点:展开站点看域名能否增删,预设改过后"恢复默认"是否可用
    2. 域名那一层不应该有复选框;双击自定义站点名可以改名
    3. 底部"添加自定义站点":名称 + 多个域名(逗号或空格分隔)
    4. 右键托盘图标 -> 加速站点:每个分组里有"全部开启 / 全部关闭"
    5. 配好服务器后点"连接选中站点",用浏览器访问目标站点验证

  实时查看生效的域名列表
    curl.exe -s http://127.0.0.1:17890/proxy.pac

  测完收尾(还原系统代理)
    .\windows\run.ps1 -Stop

"@ | Write-Host
