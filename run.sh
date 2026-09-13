#!/bin/bash
# SpeedLane 本地测试脚本(macOS)
#   ./run.sh            编译并启动,自动弹出主面板和设置窗口
#   ./run.sh --popover  只弹主面板
#   ./run.sh --settings 只开设置窗口
#   ./run.sh --shot     自动截图到 /tmp/speedlane-shots 后退出
#   ./run.sh --stop     停止所有实例并还原系统代理
#   ./run.sh --backup   启动前先备份当前配置(便于随便折腾后还原)
#   ./run.sh --restore  还原最近一次备份的配置
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="dev.speedlane.app"
APP="dist/SpeedLane.app"
BIN="$APP/Contents/MacOS/SpeedLane"
SHOT_DIR="/tmp/speedlane-shots"
BACKUP="$HOME/.speedlane-settings-backup.plist"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

# 停掉正在跑的实例(打包版和 swift build 直接产出的二进制都算)
stop_instances() {
    local found=0
    if pgrep -f "$BIN" >/dev/null 2>&1; then
        pkill -f "$BIN" || true
        found=1
    fi
    if pgrep -f ".build/debug/SpeedLane" >/dev/null 2>&1; then
        pkill -f ".build/debug/SpeedLane" || true
        found=1
    fi
    [ $found -eq 1 ] && sleep 1
    return 0
}

# 还原系统代理:App 正常退出会自己还原,异常退出时用这个兜底
restore_proxy() {
    local changed=0
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        case "$service" in \**) continue ;; esac
        if networksetup -getautoproxyurl "$service" 2>/dev/null | grep -q "Enabled: Yes"; then
            networksetup -setautoproxystate "$service" off
            yellow "已关闭 $service 的自动代理配置"
            changed=1
        fi
    done < <(networksetup -listallnetworkservices | tail -n +2)
    [ $changed -eq 0 ] && green "系统代理无残留"
    return 0
}

# 残留的 ssh 隧道进程(App 崩溃时可能占着本地端口),只提示不自动杀
check_tunnels() {
    local pids
    pids=$(pgrep -f "ssh -N -D" 2>/dev/null || true)
    [ -z "$pids" ] && return 0
    yellow "发现残留的 ssh 隧道进程:"
    ps -o pid=,command= -p $pids
    # 非交互环境(CI、被其他脚本调用)下不提示、不结束
    if [ ! -t 0 ]; then
        yellow "非交互模式,未结束这些进程"
        return 0
    fi
    printf "是否结束这些进程? [y/N] "
    read -r answer
    case "$answer" in
        [yY]) kill $pids && green "已结束" ;;
        *) yellow "已跳过,如果连接时提示端口被占用请手动处理" ;;
    esac
}

case "${1:-}" in
    --stop)
        stop_instances
        restore_proxy
        check_tunnels
        green "已停止"
        exit 0
        ;;
    --backup)
        defaults export "$BUNDLE_ID" "$BACKUP"
        green "配置已备份到 $BACKUP"
        shift || true
        ;;
    --restore)
        [ -f "$BACKUP" ] || { yellow "没有找到备份文件 $BACKUP"; exit 1; }
        stop_instances
        defaults import "$BUNDLE_ID" "$BACKUP"
        green "配置已还原,重新运行 ./run.sh 生效"
        exit 0
        ;;
esac

# 解析启动参数
ARGS=()
case "${1:-}" in
    --popover)  ARGS=(--show-popover) ;;
    --settings) ARGS=(--show-settings) ;;
    --shot)
        mkdir -p "$SHOT_DIR"
        ARGS=(--capture "$SHOT_DIR")
        ;;
    "")         ARGS=(--show-popover --show-settings) ;;
    *)          ARGS=("$@") ;;
esac

green "正在编译…"
swift build -c release >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpeedLane "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" 2>/dev/null

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
green "打包完成 v$VERSION"

stop_instances
open -n "$APP" --args "${ARGS[@]}"

if [ "${1:-}" = "--shot" ]; then
    sleep 8
    green "截图已保存到 $SHOT_DIR"
    open "$SHOT_DIR"
    exit 0
fi

sleep 1
cat <<EOF

$(green "已启动,菜单栏找 ⚡ 图标")

  测试要点
    1. 设置 → 加速站点:点站点名展开,看域名能否增删,改过的预设有没有"恢复默认"
    2. 底部添加自定义站点:名称 + 多个域名(逗号或空格分隔)
    3. 每个分组右侧"全开 / 全关"批量开关
    4. 设置 → 服务器:填服务器后用"测试连接"验证
    5. 点"连接选中站点",状态变绿后浏览器访问目标站点验证

  实时查看生效的域名列表
    curl -s http://127.0.0.1:17890/proxy.pac | head -40

  测完收尾(还原系统代理、清理残留隧道)
    ./run.sh --stop

EOF
