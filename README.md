# DSH 一键安装器（Windows）

> 给**不懂电脑的人**用的 DeepSeek Harness（`dsh`）一键安装 + 启动工具：
> 双击一次，自动装好 Node.js + DSH，创建可自定义名字/图标的桌面快捷方式，之后点图标就能用。

[![Tests](https://github.com/talking-pure-water1/dsh-one-click-installer/actions/workflows/tests.yml/badge.svg)](https://github.com/talking-pure-water1/dsh-one-click-installer/actions/workflows/tests.yml)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)
![License](https://img.shields.io/badge/license-MIT-green)

**简体中文** | [使用说明（给小白）](docs/使用说明.md)

---

## 这是什么

`@deepseek-ai/dsh` 官方只提供命令行安装（`npx @deepseek-ai/dsh web`）。对国内新手来说有几个坎：

- 机器上没装 Node.js，或者版本太老；
- `npx` 在国内网络下容易失败、缓存目录名还是哈希，没法做快捷方式；
- 装完不知道去哪找入口，桌面上也没有图标；
- 直接强杀进程退出，下次打开会「历史加载失败」；
- 系统可能禁止运行 `.ps1`，双击 `.cmd` 又看到一堆英文报错。

本项目把这些坎一次性抹平：**一个 60 KB 的脚本包，双击即可用**。

## 功能

| 能力 | 说明 |
|---|---|
| 🔍 **环境自检** | 检测 Node（要求 22.19+ 或 24+）、npm、磁盘空间、桌面真实位置 |
| 📦 **两种装 Node 的路线** | 优先 `winget`（系统级、签名包）；无管理员权限时改用 npmmirror 国内镜像的免安装版，**全程不需要管理员** |
| 🧭 **零污染安装** | npm 镜像/缓存/全局目录若在 C 盘会迁到空间最大的非系统盘；不写注册表 |
| 🚀 **稳定的启动方式** | 全局安装 `@deepseek-ai/dsh`，拿到固定命令（不用 npx 的哈希缓存目录） |
| 🖥️ **应用模式窗口** | 用 Edge/Chrome 的 `--app` 打开：无地址栏、无标签栏，看起来就是桌面软件 |
| 🎯 **单一开页者** | 检测 `dsh-web-open` 插件（依赖/bundles/patch 三处），避免"每次弹出两个同样的网站" |
| 🔌 **端口冲突自愈** | 端口被占自动换空闲端口；已有实例则只开窗口，不重复启动 |
| 🛑 **安全退出（防"失忆"）** | 退出时向 DSH 进程发送等价 Ctrl+C 的信号，让它把会话数据写完再关；超时才兜底强杀并记录 |
| 🐳 **自带托盘菜单** | 右下角图标：打开界面 / 重启 / **安全退出** / 更新 DSH / 打开控制面板 |
| 🎨 **快捷方式自定义** | 名字随便取（支持中文）、图标可换（`.ico/.exe/.dll`），自动清理重复图标 |
| 🗂️ **自部署** | 程序复制到安装目录，**下载来的工具包可以直接删掉**，快捷方式照常可用 |
| 🧰 **图形控制面板** | 本地小网页（零依赖），安装/启动/更新/改名换图标/卸载/看日志全在按钮上；**Node 没装时也能打开** |
| ⬆️ **一键更新** | 显示当前版本、查最新版、执行更新，并可选顺手重启服务 |
| 📦 **打包脚本** | 生成"精简版（给用户）/ 维护版（含测试）"两种分发包，自动剔除本机运行产物 |
| ✅ **验收测试** | 13 项离线自测 + 1 项联网自测，覆盖安装、部署、快捷方式、端口、执行策略、托盘、打包质量 |

体积对比：本工具发布包 **≈ 60 KB**（纯 PowerShell 脚本，无任何二进制）。

## 快速开始

1. 从 [Releases](../../releases) 下载 `DSH-one-click-installer-*-slim.zip`（给普通用户的精简版）并解压到任意位置；
   - 注意：GitHub 会把发布资产名里的中文统一替换掉，所以附件是英文名；解压出来的文件夹仍是 `DSH一键安装`
   - 想自己打包（含 13 项验收测试的维护版）：下载源码后双击 `打包发布.cmd`
2. 双击 **`安装DSH（初次使用点击这里就好啦⭐️）.cmd`**；
3. 中途会问快捷方式的名字和图标（**懒得改就一路回车**），等 1~3 分钟；
4. 装好后会自动打开 DSH 窗口，桌面出现你命名的快捷方式。

> 系统弹出"Windows 已保护你的电脑 / 未知发布者"时，点 **更多信息 → 仍要运行** 即可（脚本类工具的通用提示；本工具未做代码签名）。

装完第一次使用：进入界面后自己填 API Key（<https://platform.deepseek.com> 注册获取）。本项目**不代管任何账号与密钥**。

## 日常使用

| 入口 | 用途 |
|---|---|
| 桌面快捷方式 | 启动 DSH（最常用） |
| **右下角托盘图标** | 打开界面 / 重启 / **安全退出** / 更新 DSH / 控制面板 |
| 开始菜单「DSH 控制面板」 | 安装/启动/更新/改名换图标/卸载/看日志 |
| 工具包（还在的话） | `更新DSH.cmd`、`改名换图标.cmd`、`卸载.cmd`、`启动面板…❀.cmd` |

**退出请用托盘里的「安全退出」**，不要用任务管理器"结束任务"：DSH 的会话是分批落盘的，安全退出会先让它收尾，强杀有可能让最后一段记录不完整。

## 目录结构

```
dsh-one-click-installer/
├── install.ps1            # 主安装逻辑
├── shortcut.ps1           # 快捷方式创建/改名/换图标（含重复清理）
├── update-dsh.ps1         # 一键更新 DSH
├── uninstall.ps1          # 卸载（默认保留会话数据）
├── panel.ps1              # 图形控制面板（HttpListener，零依赖）
├── pack-release.ps1       # 打包发布（精简版 / 维护版）
├── *.cmd                  # 双击入口（纯 ASCII + ExecutionPolicy Bypass）
├── launcher/
│   ├── start-dsh.ps1      # 启动器：端口探测 → 启动/复用 → 就绪轮询 → 开窗口
│   ├── stop-dsh.ps1       # 安全退出：Ctrl+C 优雅停止，超时兜底
│   └── dsh-tray.ps1       # 托盘菜单
├── assets/dsh.ico         # 默认图标
├── docs/使用说明.md        # 面向小白的完整说明 + FAQ（19 条）
└── tests/                 # 验收测试（13 项离线 + 1 项联网）
```

## 运行测试

```powershell
# 离线套件（约 1.5 分钟）：语法/BOM、幂等性、无 Node 分支、端口占用、
#                        实例复用、快捷方式、执行策略、一键更新、应用模式、面板、自部署、打包质量、托盘安全退出
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1

# 追加联网项：真从镜像下载 Node 到隔离目录（约 30 MB）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1 -Network
```

测试会在真实桌面上创建并删除临时快捷方式、临时占用端口、拉起本地监听，属预期行为；在没有交互式桌面的环境里个别项会自动 SKIP。

## 设计取舍

- **不用 `npx` 做快捷方式目标**：npx 缓存目录名是哈希（`_npx\<hash>`），会随解析变化，指向它会随时失效。
- **不用 `wscript` + `.vbs` 隐藏启动**：这是杀毒软件最敏感的行为特征，改为快捷方式直接调用系统自带 PowerShell。
- **桌面路径一律用 `[Environment]::GetFolderPath('Desktop')`**：很多国内机器被 360/OneDrive 搬到了 `D:\360MoveData\...`。
- **`.cmd` 入口保持纯 ASCII**：避免代码页导致的中文乱码；中文全部放在带 UTF-8 BOM 的 `.ps1` 里。
- **不写注册表、不动系统级 PATH**：只改用户级环境变量，卸载可还原。

## 免责声明

- 本项目是**社区作品**，与 DeepSeek 官方无隶属或背书关系；"DeepSeek Harness"、"dsh" 归其各自权利人所有。
- 本工具只做**环境准备与启动封装**，不修改 DSH 本体，不采集任何数据，不接触你的 API Key。
- 安装包未做代码签名，Windows/杀软可能提示风险；请从本仓库 Release 下载并自行审阅脚本（全部为可读 PowerShell）。
- 使用第三方 API 中转站/网关时，你的对话内容会经过第三方，请自行评估风险。

## 许可

[MIT](LICENSE)
