# SpeedLane

> 只给选中的网站开一条快车道 —— macOS 菜单栏分流加速工具

[![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#系统要求)
[![swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](Package.swift)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

SpeedLane 通过你**自己的境外服务器**加速访问 GitHub、Google 等指定网站,而其他所有网站保持直连、完全不经过代理。没有订阅、没有第三方节点、没有全局翻墙 —— 一台能 SSH 登录的 VPS 就够了。

## 特性

- ⚡ **白名单分流**:基于 PAC 自动代理,只有你开启的站点走加速,其余流量一律直连
- 🖥 **服务器零配置**:默认用 SSH 动态端口转发(`ssh -D`)建立加密隧道,服务器上不需要安装任何软件;也支持连接服务器上已有的 SOCKS5 / HTTP 代理
- 🗂 **多服务器管理**:可添加多台服务器,一键切换默认连接,支持密码(存 macOS 钥匙串)和 SSH 密钥两种登录方式,内置连接测试
- ✅ **站点开关自由组合**:内置 GitHub、Google、YouTube、Stack Overflow、Hugging Face、Docker Hub、npm、Wikipedia 等预设(含相关 CDN 域名),支持添加自定义域名,每个站点独立滑块开关
- 🧰 **git 命令行加速**:自动按域名为 git 配置代理,只影响所选域名的 clone/push
- 🖱 **右键快捷菜单**:右键点击菜单栏图标可快速连接/断开、打开设置、切换开机自动运行
- 🚀 **开机自动运行 + 启动后自动连接**:两者配合实现无感使用
- 🧹 **干净退出**:关闭开关或退出 App 自动还原系统代理设置

## 工作原理

```
浏览器 / 系统 ──> PAC 自动代理判断
                   ├─ 命中开启的域名 ──> 本地 SOCKS5 (127.0.0.1:1080) ──SSH 加密隧道──> 你的服务器 ──> 目标网站
                   └─ 其他所有域名 ──> 直连(不经过任何代理)
```

1. 开启后 App 运行 `ssh -N -D 1080 user@your-server` 建立本地 SOCKS5 隧道
2. 本地起一个只监听 `127.0.0.1` 的微型 HTTP 服务,向系统提供按你的站点选择动态生成的 PAC 文件
3. 通过 `networksetup` 把系统"自动代理配置"指向该 PAC;修改站点选择即时生效
4. 关闭/退出时自动恢复原有网络设置

## 系统要求

- macOS 13 (Ventura) 及以上
- 一台境外 VPS(任意可 SSH 登录的 Linux 服务器即可)
- 构建需要 Xcode / Swift 5.9+

## 安装

### 方式一:下载 DMG(推荐)

从 [Releases](https://github.com/openzirun/SpeedLane/releases) 下载最新的 `SpeedLane-x.x.x.dmg`,打开后把 SpeedLane 拖入 Applications 文件夹。

> **首次打开提示"无法验证开发者"或"已损坏"?**
> 项目未购买 Apple 开发者证书,系统会拦截来自网络的未签名应用。任选其一解除:
> - 右键点击 App → 打开 → 再点"打开";或
> - 终端执行 `xattr -cr /Applications/SpeedLane.app` 后正常双击打开

### 方式二:源码构建

```bash
git clone https://github.com/openzirun/SpeedLane.git
cd SpeedLane
./build_app.sh          # 打包出 dist/SpeedLane.app
./make_dmg.sh           # (可选)生成 DMG
open dist/SpeedLane.app
```

## 使用

1. 点击菜单栏 ⚡ 图标 → **设置…** → "服务器"标签页,添加你的服务器(IP、SSH 端口、用户名、密码或密钥),可用"测试连接"验证,★ 为默认连接
2. 在"加速站点"标签页或菜单弹窗中,用滑块开启要加速的站点,或添加自定义域名
3. 点击 **连接选中站点**,状态变绿即生效
4. 右键菜单栏图标可快速连接/断开、打开设置、开启"开机自动运行";"通用"设置里还可开启"启动后自动连接"

**登录方式二选一:**

- **密码**:直接在设置中填写,保存在 macOS 钥匙串(经 SSH_ASKPASS 传递,不出现在命令行参数和配置文件中)
- **SSH 密钥**:先在终端执行一次 `ssh-copy-id user@your-server-ip`

## FAQ

**浏览器生效了,终端里 curl 却不走代理?**
命令行工具不读系统 PAC。git 已自动覆盖(连接时按所选域名配置);其他工具可临时 `export https_proxy=socks5://127.0.0.1:1080`(该终端所有请求都会走代理,用完 `unset`)。

**App 异常退出后网络设置残留?**
系统设置 → Wi-Fi → 详细信息 → 代理,关闭"自动代理配置";或执行 `networksetup -setautoproxystate Wi-Fi off`。

**为什么每次重新编译后读取钥匙串会弹授权框?**
本地构建使用 ad-hoc 签名,二进制指纹每次变化。点"始终允许"即可;正式分发版本使用固定的 Developer ID 签名则无此问题。

**连接失败显示红色?**
常见原因:密码错误、SSH 密钥未配置、服务器防火墙未放行 SSH 端口。用设置里的"测试连接"可看到具体错误信息。

## 项目结构

| 文件 | 职责 |
|------|------|
| [Models.swift](Sources/SpeedLane/Models.swift) | 站点预设、服务器模型、设置持久化 |
| [SSHTunnel.swift](Sources/SpeedLane/SSHTunnel.swift) | SSH 动态转发进程管理、连接测试 |
| [PACServer.swift](Sources/SpeedLane/PACServer.swift) | 本地 PAC 服务与 PAC 脚本生成 |
| [SystemProxy.swift](Sources/SpeedLane/SystemProxy.swift) | 系统代理(networksetup)开关 |
| [KeychainStore.swift](Sources/SpeedLane/KeychainStore.swift) | 服务器密码钥匙串存取 |
| [GitProxy.swift](Sources/SpeedLane/GitProxy.swift) | git 按域名代理配置 |
| [AppController.swift](Sources/SpeedLane/AppController.swift) | 总控制流程 |
| [StatusBarController.swift](Sources/SpeedLane/StatusBarController.swift) | 菜单栏图标、左键弹窗/右键菜单 |
| [MenuView.swift](Sources/SpeedLane/MenuView.swift) / [SettingsView.swift](Sources/SpeedLane/SettingsView.swift) | 菜单栏弹窗与设置窗口 |
| [LaunchAtLogin.swift](Sources/SpeedLane/LaunchAtLogin.swift) | 开机自动运行(SMAppService) |

## 免责声明

SpeedLane 是一个连接**用户自有服务器**的网络工具,面向开发者访问开发资源(代码托管、包镜像、技术文档)的场景。本项目不提供任何服务器、节点或网络服务。请遵守你所在国家/地区的法律法规,使用本工具产生的一切后果由使用者自行承担。

## License

[MIT](LICENSE)
