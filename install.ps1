<#
  安装DSH.ps1 —— DSH 一键安装器（电脑小白版）
  流程：环境勘察 → 安装/校验 Node.js → 配置 npm → 全局安装 dsh → 数据目录取舍
        → 创建可自定义名称/图标的桌面快捷方式 → 首次启动并等待界面可用

  设计要点（对应方案里的五个坑）：
   1) 用「全局安装 dsh」得到稳定命令，不依赖 npx 哈希缓存目录
   2) 本脚本由 .cmd 以 -ExecutionPolicy Bypass 调起（绕过执行策略限制）
   3) 桌面路径一律用系统 API 取真实位置（兼容 360/OneDrive 迁移）
   4) 安装位置默认选非 C 盘（保护 C 盘空间）
   5) 启动器负责端口探测与单一开页者，本脚本只调用它

  用法示例：
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -DryRun -NonInteractive
#>
[CmdletBinding()]
param(
    # 只检测并打印将要执行的动作，不写任何文件、不下载、不安装
    [switch]$DryRun,
    # 无人值守：不弹输入框，快捷方式用默认名（DSH Web）
    [switch]$NonInteractive,
    # 安装根目录（默认自动挑选非 C 盘）
    [string]$InstallRoot = "",
    # 快捷方式名称 / 图标（不传则交互询问或取默认）
    [string]$ShortcutName = "",
    [string]$IconPath = "",
    # 跳过的环节（便于分步排错）
    [switch]$SkipNode,
    [switch]$SkipDsh,
    [switch]$SkipShortcut,
    [switch]$SkipDshHome,
    # 装完不立即启动
    [switch]$NoStart,
    # 只做修复：已存在即跳过，不重复下载/安装
    [switch]$Repair,
    # 测试用：假装本机没有 Node（配合 -DryRun 使用，不会真的安装）
    [switch]$SimulateNoNode,
    # 强制指定装 Node 的路线：auto（默认，winget 优先）/ winget / portable（免安装版，免管理员）
    [ValidateSet('auto', 'winget', 'portable')]
    [string]$NodeMethod = 'auto',
    # 测试用：不写任何用户环境变量与 PATH（隔离验证时用，只打印"将要写入什么"）
    [switch]$NoEnvChange,
    # 窗口模式：on=应用模式（Edge/Chrome --app 独立窗口，无地址栏，像桌面软件）；off=普通浏览器标签页
    [ValidateSet('on', 'off')]
    [string]$AppMode = 'on',
    # 关掉应用窗口时同时停止 DSH 服务（默认否，避免误关导致对话中断）
    [switch]$KillHostOnExit,
    # 无人值守时是否请求固定到任务栏（Win11 通常需要手动固定，会给出引导）
    [switch]$PinTaskbar
)

$ErrorActionPreference = 'Continue'
$script:InstallVersion = '1.1.0'
$script:LogFile = ''
$script:Warnings = New-Object System.Collections.ArrayList
$script:Steps = New-Object System.Collections.ArrayList
$script:NoEnvChange = [bool]$NoEnvChange

# ────────────────────────────── 输出与日志 ──────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$stamp] [$Level] $Message"
    if ($script:LogFile -ne '') {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
    switch ($Level) {
        'ok'    { Write-Host "  [√] $Message" -ForegroundColor Green }
        'warn'  { Write-Host "  [!] $Message" -ForegroundColor Yellow; [void]$script:Warnings.Add($Message) }
        'err'   { Write-Host "  [×] $Message" -ForegroundColor Red }
        'step'  { Write-Host ""; Write-Host "== $Message ==" -ForegroundColor Cyan }
        'note'  { Write-Host "      $Message" -ForegroundColor DarkGray }
        default { Write-Host "  $Message" }
    }
}

function Add-StepResult {
    param([string]$Name, [string]$Result, [string]$Detail = '')
    [void]$script:Steps.Add([PSCustomObject]@{ 环节 = $Name; 结果 = $Result; 说明 = $Detail })
}

function Show-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║        DSH 一键安装器  (DeepSeek Harness)            ║" -ForegroundColor DarkCyan
    Write-Host "  ║        自动装好 Node.js + DSH，并创建桌面快捷方式     ║" -ForegroundColor DarkCyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    if ($DryRun) { Write-Host "  模式：只检测（DryRun），不会安装任何东西" -ForegroundColor Magenta }
    Write-Host ""
}

# ────────────────────────────── 环境勘察 ──────────────────────────────
function Get-FixedDrives {
    $out = @()
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Free -eq $null) { continue }
        if ($d.Name -match '^[A-Za-z]$') {
            $out += [PSCustomObject]@{ Letter = $d.Name; FreeGB = [math]::Round($d.Free / 1GB, 1); Root = "$($d.Name):\" }
        }
    }
    # 用 @() 包一层：PS 5.1 下单个对象的 .Count 可能为空，会让判断退化
    return @($out)
}

function Select-InstallRoot {
    param([string]$Explicit)
    if ($Explicit -ne '') {
        # 用户显式指定：只在 DryRun 时校验可写性
        if (-not $DryRun) {
            try { if (-not (Test-Path -LiteralPath $Explicit)) { New-Item -ItemType Directory -Path $Explicit -Force | Out-Null } }
            catch { throw "指定的安装目录无法创建：$Explicit （$($_.Exception.Message)）" }
        }
        return $Explicit
    }
    $drives = @(Get-FixedDrives)
    $c = @($drives | Where-Object { $_.Letter -eq 'C' } | Select-Object -First 1)
    $nonC = @($drives | Where-Object { $_.Letter -ne 'C' } | Sort-Object FreeGB -Descending)
    # C 盘可用空间 < 3GB 时强制不用 C 盘
    if ($c.Count -gt 0 -and $c[0].FreeGB -lt 3) {
        if ($nonC.Count -gt 0) {
            Write-Log ("C 盘仅剩 {0} GB，自动把安装位置放到 {1} 盘" -f $c[0].FreeGB, $nonC[0].Letter) 'warn'
            return (Join-Path $nonC[0].Root 'dsh-launcher')
        }
        Write-Log "C 盘空间不足且没有其它可用磁盘，请先清理磁盘空间" 'warn'
        return (Join-Path $c[0].Root 'dsh-launcher')
    }
    if ($nonC.Count -gt 0) {
        Write-Log ("自动选择空间最大的非系统盘：{0} 盘（可用 {1} GB）" -f $nonC[0].Letter, $nonC[0].FreeGB) 'note'
        return (Join-Path $nonC[0].Root 'dsh-launcher')
    }
    return (Join-Path $c[0].Root 'dsh-launcher')
}

function Test-NodeAdequate {
    param([string]$VersionText)
    # DSH 生态要求：^22.19.0 || >=24.0.0
    if ($VersionText -notmatch 'v?(\d+)\.(\d+)\.(\d+)') { return $false }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
    if ($major -ge 24) { return $true }
    if ($major -eq 22 -and $minor -ge 19) { return $true }
    return $false
}

function Get-NodeInfo {
    param([switch]$PretendMissing)
    $result = [PSCustomObject]@{ Found = $false; Path = ''; Version = ''; Adequate = $false }
    if ($PretendMissing) { return $result }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    $candidate = ''
    if ($cmd) { $candidate = $cmd.Source }
    if ($candidate -eq '') {
        foreach ($p in @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe", "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
            if ($p -and (Test-Path -LiteralPath $p)) { $candidate = $p; break }
        }
    }
    if ($candidate -eq '') { return $result }
    $result.Found = $true
    $result.Path = $candidate
    try { $result.Version = (& $candidate -v) 2>$null } catch { $result.Version = '' }
    if ($result.Version -is [array]) { $result.Version = ($result.Version | Select-Object -First 1) }
    $result.Adequate = (Test-NodeAdequate -VersionText "$($result.Version)")
    return $result
}

function Get-NpmInfo {
    $r = [PSCustomObject]@{ Found = $false; Path = ''; Prefix = ''; Registry = ''; Cache = ''; UserNpmrc = (Join-Path $env:USERPROFILE '.npmrc') }
    $cmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($cmd) { $r.Found = $true; $r.Path = $cmd.Source }
    if ($r.Found) {
        try { $r.Prefix = (npm config get prefix) 2>$null } catch { }
        try { $r.Registry = (npm config get registry) 2>$null } catch { }
        try { $r.Cache = (npm config get cache) 2>$null } catch { }
        if ($r.Prefix -is [array]) { $r.Prefix = $r.Prefix[0] }
        if ($r.Registry -is [array]) { $r.Registry = $r.Registry[0] }
        if ($r.Cache -is [array]) { $r.Cache = $r.Cache[0] }
    }
    return $r
}

function Get-DesktopPath {
    # 坑 3：桌面可能被 360/OneDrive 迁移，必须问系统要真实路径
    try {
        $p = [Environment]::GetFolderPath('Desktop')
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    try {
        $sh = New-Object -ComObject WScript.Shell
        $p = $sh.SpecialFolders.Item('Desktop')
        if ($p) { return $p }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Desktop')
}

function Get-DshHomeInfo {
    $r = [PSCustomObject]@{ EnvSet = ''; LegacyExists = $false; Path = '' }
    $r.EnvSet = [Environment]::GetEnvironmentVariable('DSH_HOME', 'User')
    if (-not $r.EnvSet) { $r.EnvSet = $env:DSH_HOME }
    $legacy = Join-Path $env:USERPROFILE '.dsh'
    $r.LegacyExists = (Test-Path -LiteralPath $legacy)
    if ($r.EnvSet) { $r.Path = $r.EnvSet } elseif ($r.LegacyExists) { $r.Path = $legacy }
    return $r
}

function Get-DshCommandPath {
    param([string]$NpmPrefix)
    $cands = @()
    if ($NpmPrefix) { $cands += (Join-Path $NpmPrefix 'dsh.cmd') }
    $cmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($cmd) { $cands += $cmd.Source }
    foreach ($c in $cands) {
        if (-not $c) { continue }
        # npx 临时缓存里的命令不算「已安装」：目录名是哈希，随时会变，不能给快捷方式用
        if ($c -match '\\_npx\\' -or $c -match '\\node_modules\\') { continue }
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return ''
}

# ────────────────────────────── 动作实现 ──────────────────────────────
function Install-NodeByWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
    Write-Log "尝试用 winget 安装 Node.js LTS（会弹出一次系统授权窗口，请点「是」）"
    if ($DryRun) { Write-Log "DryRun：跳过实际安装" 'note'; return $false }
    try {
        & winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 |
            ForEach-Object { Write-Log ("winget: " + $_) 'note' }
    } catch {
        Write-Log "winget 安装失败：$($_.Exception.Message)" 'warn'
        return $false
    }
    # 刷新当前进程 PATH，让新装的 node 立即可见
    $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    Start-Sleep -Seconds 2
    $info = Get-NodeInfo
    return ($info.Found -and $info.Adequate)
}

function Install-NodePortable {
    param([string]$Root)
    $mirror = 'https://npmmirror.com/mirrors/node'
    Write-Log "改用免安装版 Node（无需管理员权限），源：$mirror"
    if ($DryRun) { Write-Log "DryRun：跳过下载与解压" 'note'; return $false }
    try {
        $index = Invoke-RestMethod -Uri "$mirror/index.json" -TimeoutSec 30
        $lts = $index | Where-Object { $_.lts -and ($_.files -contains 'win-x64-zip') } | Select-Object -First 1
        if (-not $lts) { throw "镜像里找不到带 win-x64-zip 的 LTS 版本" }
        $ver = $lts.version
        $zipName = "node-$ver-win-x64.zip"
        $url = "$mirror/$ver/$zipName"
        $dlDir = Join-Path $Root 'downloads'
        $zipPath = Join-Path $dlDir $zipName
        New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
        Write-Log "下载 Node $ver（约 30MB，国内镜像，请稍候）"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # 进度条会让下载慢很多
        Invoke-WebRequest -Uri $url -OutFile $zipPath -TimeoutSec 600
        $ProgressPreference = $oldProgress
        $sw.Stop()
        $zipKB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 0)
        Write-Log "下载完成：$zipKB KB，用时 $([int]$sw.Elapsed.TotalSeconds) 秒" 'ok'
        $nodeDir = Join-Path $Root 'node'
        if (Test-Path -LiteralPath $nodeDir) { Remove-Item -LiteralPath $nodeDir -Recurse -Force }
        Write-Log "解压到 $nodeDir"
        Expand-Archive -LiteralPath $zipPath -DestinationPath $nodeDir -Force
        $inner = Get-ChildItem -LiteralPath $nodeDir -Directory | Select-Object -First 1
        $realDir = if ($inner) { $inner.FullName } else { $nodeDir }
        $nodeExe = Join-Path $realDir 'node.exe'
        if (-not (Test-Path -LiteralPath $nodeExe)) { throw "解压后找不到 node.exe" }
        $probe = (& $nodeExe -v) 2>$null
        Write-Log "解压校验：$nodeExe → $probe" 'ok'
        # 写用户 PATH（用 .NET API，避免 setx 的 1024 字符截断）
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$realDir*") {
            if ($script:NoEnvChange) {
                Write-Log "（测试模式）跳过写入用户 PATH，本应追加：$realDir" 'note'
            } else {
                $newPath = if ([string]::IsNullOrEmpty($userPath)) { $realDir } else { $userPath.TrimEnd(';') + ';' + $realDir }
                [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
                Write-Log "已把 $realDir 加入用户 PATH" 'ok'
            }
        }
        $env:PATH = $env:PATH + ';' + $realDir
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        $info = Get-NodeInfo
        return ($info.Found -and $info.Adequate)
    } catch {
        Write-Log "免安装版 Node 部署失败：$($_.Exception.Message)" 'err'
        return $false
    }
}

function Set-NpmConfigIfNeeded {
    param($Npm, [string]$Root)
    if (-not $Npm.Found) { Write-Log "未检测到 npm，跳过 npm 配置" 'warn'; return }
    if ($script:NoEnvChange) { Write-Log "（测试模式）跳过 npm 配置写入" 'note'; return }
    $npmrc = $Npm.UserNpmrc
    # 备份一次原始 .npmrc
    if ((Test-Path -LiteralPath $npmrc) -and -not $DryRun) {
        $bak = "$npmrc.dsh-bak"
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $npmrc -Destination $bak -Force; Write-Log "已备份原始 .npmrc → $bak" 'note' }
    }
    # 1) 镜像源：没有才写，不覆盖用户已有配置
    if ("$($Npm.Registry)" -notmatch 'npmmirror|taobao') {
        if ($DryRun) { Write-Log "DryRun：将把 npm registry 设为 npmmirror 镜像" 'note' }
        else {
            & npm config set registry https://registry.npmmirror.com 2>&1 | Out-Null
            Write-Log "已设置 npm 镜像源：registry.npmmirror.com" 'ok'
        }
    } else { Write-Log "npm 镜像源已是 $($Npm.Registry)，保持不变" }

    # 2) 缓存目录：在 C 盘就搬到安装盘（保护 C 盘）
    if ("$($Npm.Cache)" -match '^[Cc]:') {
        $newCache = Join-Path $Root 'npm-cache'
        if ($DryRun) { Write-Log "DryRun：将把 npm 缓存从 $($Npm.Cache) 移到 $newCache" 'note' }
        else {
            New-Item -ItemType Directory -Path $newCache -Force | Out-Null
            & npm config set cache $newCache 2>&1 | Out-Null
            Write-Log "npm 缓存已迁到 $newCache（原：$($Npm.Cache)）" 'ok'
        }
    } else { Write-Log "npm 缓存位置 $($Npm.Cache) 不在 C 盘，保持不变" }

    # 3) 全局安装目录：在 C 盘就搬到安装盘并补 PATH
    if ("$($Npm.Prefix)" -match '^[Cc]:') {
        $newPrefix = Join-Path $Root 'npm-global'
        if ($DryRun) { Write-Log "DryRun：将把 npm 全局目录从 $($Npm.Prefix) 改到 $newPrefix" 'note' }
        else {
            New-Item -ItemType Directory -Path $newPrefix -Force | Out-Null
            & npm config set prefix $newPrefix 2>&1 | Out-Null
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if ($userPath -notlike "*$newPrefix*") {
                [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $newPrefix), 'User')
            }
            $env:PATH = $env:PATH + ';' + $newPrefix
            Write-Log "npm 全局目录已改到 $newPrefix 并加入用户 PATH" 'ok'
        }
    } else { Write-Log "npm 全局目录 $($Npm.Prefix) 不在 C 盘，保持不变" }
}

function Install-DshGlobal {
    param($Npm)
    if (-not $Npm.Found) { Write-Log "没有 npm，无法安装 dsh" 'err'; return $false }
    Write-Log "开始全局安装 dsh（npm i -g @deepseek-ai/dsh）"
    if ($DryRun) { Write-Log "DryRun：跳过实际安装" 'note'; return $false }
    try {
        & npm i -g '@deepseek-ai/dsh' 2>&1 | ForEach-Object { Write-Log ("npm: " + $_) 'note' }
    } catch {
        Write-Log "全局安装失败：$($_.Exception.Message)" 'warn'
    }
    $after = Get-NpmInfo
    $dshCmd = Get-DshCommandPath -NpmPrefix $after.Prefix
    if ($dshCmd -ne '') {
        Write-Log "dsh 已就位：$dshCmd" 'ok'
        return $true
    }
    Write-Log "全局安装未产生可用的 dsh 命令，稍后将用 npx 兜底" 'warn'
    return $false
}

function Deploy-App {
    param([string]$Source, [string]$Target)
    # 把程序文件复制到安装目录。这样【下载来的工具包文件夹可以删掉】，快捷方式依然有效。
    if ((Test-Path -LiteralPath $Source) -and (Test-Path -LiteralPath $Target)) {
        try {
            $s = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
            $t = (Resolve-Path -LiteralPath $Target).Path.TrimEnd('\')
            if ($s -ieq $t) { Write-Log "程序已在安装目录中运行，无需复制" 'note'; return $false }
        } catch { }
    }
    $items = @(
        'launcher', 'assets',
        'install.ps1', 'shortcut.ps1', 'update-dsh.ps1', 'uninstall.ps1', 'panel.ps1', 'pack-release.ps1',
        '安装DSH（初次使用点击这里就好啦⭐️）.cmd', '修复.cmd', '卸载.cmd', '更新DSH.cmd', '改名换图标.cmd', '启动面板（第二次及以后使用点击这个就好啦❀）.cmd', '打包发布.cmd',
        'README_给小白的使用说明.md'
    )
    $copied = 0
    foreach ($it in $items) {
        $src = Join-Path $Source $it
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $Target $it
        try {
            if (Test-Path -LiteralPath $src -PathType Container) {
                if (-not $DryRun) {
                    New-Item -ItemType Directory -Path $dst -Force | Out-Null
                    # 必须复制「目录内容」，否则会变成 app\launcher\launcher 这种嵌套
                    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
                }
                $copied++
            } else {
                if (-not $DryRun) { Copy-Item -LiteralPath $src -Destination $dst -Force }
                $copied++
            }
        } catch { Write-Log "复制 $it 失败：$($_.Exception.Message)" 'warn' }
    }
    Write-Log "已部署 $copied 项到 $Target" 'ok'

    # 清理陈旧文件：部署目录里遗留的、已不在本次部署清单中的入口/脚本（例如改名前的旧入口），
    # 避免「装两次出现两套入口」这种混乱；只管顶层 .cmd/.ps1，不碰 launcher\ 里的配置与日志。
    if (-not $DryRun) {
        $keep = @{}
        foreach ($it in $items) { if ($it -notmatch '\\') { $keep[$it] = $true } }
        $pruned = 0
        foreach ($f in (Get-ChildItem -LiteralPath $Target -File -Include *.cmd, *.ps1 -ErrorAction SilentlyContinue)) {
            if (-not $keep.ContainsKey($f.Name)) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "清理陈旧文件：$($f.Name)" 'note'
                $pruned++
            }
        }
        # launcher 子目录同理：清掉源目录里已不存在的脚本（例如被移除的 .vbs），保留 config.json 与日志
        $srcLauncher = Join-Path $Source 'launcher'
        $dstLauncher = Join-Path $Target 'launcher'
        if ((Test-Path -LiteralPath $srcLauncher) -and (Test-Path -LiteralPath $dstLauncher)) {
            foreach ($f in (Get-ChildItem -LiteralPath $dstLauncher -File -ErrorAction SilentlyContinue)) {
                if ($f.Name -in @('config.json') -or $f.Extension -eq '.log') { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $srcLauncher $f.Name))) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    Write-Log "清理陈旧文件：launcher\$($f.Name)" 'note'
                    $pruned++
                }
            }
        }
        if ($pruned -gt 0) { Write-Log "共清理 $pruned 个陈旧文件" 'ok' }
    }
    return $true
}

function New-LauncherConfig {
    param([string]$DataRoot, [bool]$PluginAutoOpen, [string]$DshHomePath, [string]$DshCmd, [bool]$AppWindow, [bool]$KillOnExit)
    # 配置写在「已部署的程序目录」（与启动器脚本同级），数据目录只放缓存/Node/DSH_HOME
    $appRoot = $script:DeployDir
    $launcherDir = Join-Path $appRoot 'launcher'
    if (-not $DryRun) { New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null }
    $cfgPath = Join-Path $launcherDir 'config.json'
    $cfg = [ordered]@{
        version         = $script:InstallVersion
        installRoot     = $DataRoot
        programRoot     = $appRoot
        sourceRoot      = $PSScriptRoot
        launcherDir     = $launcherDir
        dshHome         = $DshHomePath
        dshCommand      = $DshCmd
        preferredPort   = 3080
        pluginAutoOpen  = $PluginAutoOpen
        appMode         = $AppWindow
        killHostOnExit  = $KillOnExit
        isolatedBrowserProfile = $false
        createdAt       = (Get-Date -Format 's')
    }
    if ($DryRun) { Write-Log "DryRun：将写入配置 $cfgPath" 'note'; return $cfgPath }
    ($cfg | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    Write-Log "已写入启动器配置：$cfgPath" 'ok'
    return $cfgPath
}

# ────────────────────────────── 主流程 ──────────────────────────────
Show-Banner
$script:InstallRoot = Select-InstallRoot -Explicit $InstallRoot
$script:DeployDir = Join-Path $script:InstallRoot 'app'    # 程序副本（工具包删了也能用）
$programRoot = $PSScriptRoot
$programLauncherDir = Join-Path $programRoot 'launcher'
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $script:InstallRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $programLauncherDir -Force | Out-Null
    $script:LogFile = Join-Path $programRoot 'install.log'
    Add-Content -LiteralPath $script:LogFile -Value ("`r`n===== 安装开始 {0} (v{1}) =====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $script:InstallVersion) -Encoding UTF8
}
Write-Log "程序目录：$programRoot"
Write-Log "数据目录：$script:InstallRoot（缓存/Node/DSH 数据放这里，保护 C 盘）"
Write-Log "日志文件：$(if ($script:LogFile) { $script:LogFile } else { '(DryRun 不写日志)' })"

# ── 1. Node.js ──
Write-Log "第 1 步 / 检查 Node.js" 'step'
$node = Get-NodeInfo -PretendMissing:$SimulateNoNode
$nodeReady = $false
if ($node.Found -and $node.Adequate) {
    Write-Log "已安装 Node $($node.Version)（$($node.Path)），无需再装" 'ok'
    Add-StepResult 'Node.js' '已就绪' "$($node.Version)"
    $nodeReady = $true
} else {
    if ($node.Found) { Write-Log "Node 版本过低（$($node.Version)），DSH 需要 22.19+ 或 24+，将安装新版" 'warn' }
    else { Write-Log "未检测到 Node.js，需要安装" 'warn' }
    if ($SkipNode) {
        Write-Log "按参数要求跳过 Node 安装（-SkipNode）" 'warn'
        Add-StepResult 'Node.js' '已跳过' '用户指定 -SkipNode'
    } elseif ($DryRun) {
        if ($NodeMethod -eq 'portable') { Write-Log "DryRun：将用 npmmirror 免安装版（不动系统）" 'note'; Add-StepResult 'Node.js' '待安装(DryRun)' '免安装版' }
        elseif ($NodeMethod -eq 'winget') { Write-Log "DryRun：将用 winget 安装 LTS" 'note'; Add-StepResult 'Node.js' '待安装(DryRun)' 'winget' }
        else { Write-Log "DryRun：将先尝试 winget 安装 LTS，失败则用 npmmirror 免安装版" 'note'; Add-StepResult 'Node.js' '待安装(DryRun)' 'winget 或免安装版' }
    } else {
        if ($NodeMethod -eq 'portable') {
            Write-Log "按参数指定：使用免安装版 Node（免管理员）" 'note'
            $nodeReady = Install-NodePortable -Root $script:InstallRoot
        } elseif ($NodeMethod -eq 'winget') {
            $nodeReady = Install-NodeByWinget
        } else {
            $nodeReady = Install-NodeByWinget
            if (-not $nodeReady) {
                Write-Log "winget 路线不可用，转用免安装版" 'warn'
                $nodeReady = Install-NodePortable -Root $script:InstallRoot
            }
        }
        if ($nodeReady) {
            $node = Get-NodeInfo
            Write-Log "Node 安装完成：$($node.Version)" 'ok'
            Add-StepResult 'Node.js' '已安装' "$($node.Version)"
        } else {
            Write-Log "Node 安装失败：请检查网络后重新双击运行；也可手动安装 Node 24 LTS（https://nodejs.org）" 'err'
            Add-StepResult 'Node.js' '安装失败' '需人工处理'
        }
    }
}

# ── 2. npm 环境 ──
Write-Log "第 2 步 / 检查 npm 与镜像配置" 'step'
$npm = Get-NpmInfo
if ($npm.Found) {
    Write-Log "npm 已就绪（全局目录 $($npm.Prefix)，缓存 $($npm.Cache)）" 'ok'
    Set-NpmConfigIfNeeded -Npm $npm -Root $script:InstallRoot
    Add-StepResult 'npm 配置' '已检查' "registry=$($npm.Registry)"
} else {
    Write-Log "未检测到 npm（Node 可能未装好）" 'warn'
    Add-StepResult 'npm 配置' '未就绪' '随 Node 一起提供'
}

# ── 3. 全局安装 dsh ──
Write-Log "第 3 步 / 安装 DSH 本体" 'step'
$npm = Get-NpmInfo
$dshCmd = Get-DshCommandPath -NpmPrefix $npm.Prefix
if ($dshCmd -ne '') {
    Write-Log "dsh 命令已存在：$dshCmd（跳过安装）" 'ok'
    Add-StepResult 'DSH 本体' '已就绪' $dshCmd
} elseif ($SkipDsh) {
    Write-Log "按参数要求跳过 dsh 安装（-SkipDsh）" 'warn'
    Add-StepResult 'DSH 本体' '已跳过' ''
} elseif ($DryRun) {
    Write-Log "DryRun：将执行 npm i -g @deepseek-ai/dsh" 'note'
    Add-StepResult 'DSH 本体' '待安装(DryRun)' ''
} else {
    $okDsh = Install-DshGlobal -Npm $npm
    if ($okDsh) {
        $npm = Get-NpmInfo
        $dshCmd = Get-DshCommandPath -NpmPrefix $npm.Prefix
        Add-StepResult 'DSH 本体' '已安装' $dshCmd
    } else {
        Write-Log "将改用 npx 方式启动（首次会稍慢），功能不受影响" 'warn'
        Add-StepResult 'DSH 本体' '全局安装失败' '改用 npx 兜底'
    }
}

# ── 4. 数据目录（DSH_HOME）──
Write-Log "第 4 步 / 数据目录（保护 C 盘）" 'step'
$homeInfo = Get-DshHomeInfo
$dshHomePath = $homeInfo.Path
if ($SkipDshHome) {
    Write-Log "按参数要求不改动数据目录" 'note'
    Add-StepResult '数据目录' '未改动' $(if ($dshHomePath) { $dshHomePath } else { '默认 ~/.dsh' })
} elseif ($homeInfo.EnvSet) {
    Write-Log "已设置 DSH_HOME=$($homeInfo.EnvSet)，保持用户配置不变" 'ok'
    Add-StepResult '数据目录' '沿用现有设置' $homeInfo.EnvSet
} elseif ($homeInfo.LegacyExists) {
    Write-Log "检测到已有数据目录 $($env:USERPROFILE)\.dsh（含历史会话/插件），保持不动" 'ok'
    $dshHomePath = Join-Path $env:USERPROFILE '.dsh'
    Add-StepResult '数据目录' '沿用默认位置' $dshHomePath
} else {
    $target = Join-Path $script:InstallRoot 'dsh-home'
    if ($DryRun) { Write-Log "DryRun：将设置 DSH_HOME=$target" 'note' }
    else {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        [Environment]::SetEnvironmentVariable('DSH_HOME', $target, 'User')
        $env:DSH_HOME = $target
        Write-Log "已设置 DSH_HOME=$target（数据不落 C 盘）" 'ok'
    }
    $dshHomePath = $target
    Add-StepResult '数据目录' '新建于非 C 盘' $target
}

# ── 5. 是否由插件自动开页（坑 5：只保留一个开页者）──
# 注意：dsh-web-open 不一定写在 bundles 里（它常通过 cordis.patch.yml 的 insert 行加载），
# 所以依赖声明、bundles、patch 三处都要查，漏一处就会退化成「两个开页者」。
$pluginAutoOpen = $false
try {
    $profileDir = Join-Path $dshHomePath 'profiles\web'
    $profilePkg = Join-Path $profileDir 'package.json'
    $profilePatch = Join-Path $profileDir 'cordis.patch.yml'
    $hitDep = $false; $hitBundle = $false; $hitPatch = $false
    if (Test-Path -LiteralPath $profilePkg) {
        $pj = Get-Content -LiteralPath $profilePkg -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pj.dependencies) { $hitDep = (@($pj.dependencies.PSObject.Properties.Name) -contains 'dsh-web-open') }
        if ($pj.dsh -and $pj.dsh.profile -and $pj.dsh.profile.bundles) {
            $hitBundle = (@($pj.dsh.profile.bundles) -contains 'dsh-web-open')
        }
    }
    if (Test-Path -LiteralPath $profilePatch) {
        $hitPatch = ((Get-Content -LiteralPath $profilePatch -Raw -Encoding UTF8) -match 'dsh-web-open')
    }
    if ($hitDep -or $hitBundle -or $hitPatch) {
        $pluginAutoOpen = $true
        Write-Log "检测到 dsh-web-open 插件（依赖=$hitDep bundles=$hitBundle patch=$hitPatch）：启动时由它负责开浏览器，启动器不重复开页" 'note'
    }
} catch { }

# ── 6. 部署程序文件（关键：让下载来的工具包可以删掉）──
Write-Log "第 5 步 / 把程序部署到安装目录" 'step'
Write-Log "程序目录（下载来的工具包）：$PSScriptRoot" 'note'
Write-Log "安装目录（程序副本）：$script:DeployDir" 'note'
if ($DryRun) {
    Write-Log "DryRun：将把启动器/面板/图标等复制到 $script:DeployDir" 'note'
    Add-StepResult '程序部署' '待部署(DryRun)' $script:DeployDir
} else {
    New-Item -ItemType Directory -Path $script:DeployDir -Force | Out-Null
    [void](Deploy-App -Source $PSScriptRoot -Target $script:DeployDir)
    Add-StepResult '程序部署' '已部署' $script:DeployDir
}

# ── 7. 启动器配置 ──
Write-Log "第 6 步 / 写入启动器配置" 'step'
$cfgPath = New-LauncherConfig -DataRoot $script:InstallRoot -PluginAutoOpen $pluginAutoOpen -DshHomePath $dshHomePath -DshCmd $dshCmd -AppWindow ($AppMode -eq 'on') -KillOnExit ([bool]$KillHostOnExit)
Add-StepResult '启动器配置' '已写入' (Join-Path $script:DeployDir 'launcher')

# ── 8. 快捷方式（先问用户要不要改名字/图标，懒人可直接回车用默认）──
Write-Log "第 7 步 / 创建桌面快捷方式" 'step'
$desktop = Get-DesktopPath
Write-Log "桌面真实路径：$desktop" 'note'
if ($SkipShortcut) {
    Write-Log "按参数要求跳过快捷方式（-SkipShortcut）" 'warn'
    Add-StepResult '桌面快捷方式' '已跳过' ''
} elseif ($DryRun) {
    Write-Log "DryRun：将创建快捷方式（名称：$(if ($ShortcutName) { $ShortcutName } else { 'DSH Web' })）" 'note'
    Add-StepResult '桌面快捷方式' '待创建(DryRun)' $desktop
} else {
    $askUser = (-not $NonInteractive)
    $finalName = if ($ShortcutName -ne '') { $ShortcutName } else { 'DSH Web' }
    $finalIcon = $IconPath
    $wantPin = [bool]$PinTaskbar
    $defaultIconPath = Join-Path $script:DeployDir 'assets\dsh.ico'

    if ($askUser -and $ShortcutName -eq '') {
        Write-Host ""
        Write-Host "  ── 快捷方式设置（不想改就直接按回车）──" -ForegroundColor Cyan
        $ans = Read-Host "  1) 给快捷方式起个名字？直接回车用默认【DSH Web】"
        if (-not [string]::IsNullOrWhiteSpace($ans)) { $finalName = $ans.Trim() }
        Write-Host "  2) 图标要换吗？  [回车] 用默认鲸鱼图标   [1] 我自己选一个图标文件"
        $ans2 = Read-Host "     选择"
        if ($ans2 -match '^\s*1\s*$') {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = '选择快捷方式图标（.ico / .exe / .dll）'
            $dlg.Filter = '图标文件 (*.ico)|*.ico|程序或图标库 (*.exe;*.dll)|*.exe;*.dll|所有文件 (*.*)|*.*'
            $dlg.InitialDirectory = $script:DeployDir
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $finalIcon = $dlg.FileName
                Write-Host "      已选择：$finalIcon" -ForegroundColor Green
            } else {
                Write-Host "      未选择，使用默认图标" -ForegroundColor DarkGray
            }
        }
        Write-Host "  3) 要不要把它固定到任务栏（方便随时点）？  [回车] 不用   [1] 要"
        $ans3 = Read-Host "     选择"
        if ($ans3 -match '^\s*1\s*$') { $wantPin = $true }
        Write-Host ""
    }
    if ($finalIcon -eq '') { $finalIcon = $defaultIconPath }

    $scArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:DeployDir 'shortcut.ps1'),
                '-LauncherRoot', $script:DeployDir, '-Force', '-RemoveDuplicates')
    if ($finalName -ne '') { $scArgs += @('-Name', $finalName) }
    if ($finalIcon -ne '') { $scArgs += @('-IconPath', $finalIcon) }
    if ($NonInteractive) { $scArgs += '-NonInteractive' }
    & powershell.exe @scArgs
    if ($LASTEXITCODE -eq 0) {
        Write-Log "快捷方式已创建：$finalName" 'ok'
        Add-StepResult '桌面快捷方式' '已创建' "$desktop\$finalName.lnk"
    } else {
        Write-Log "快捷方式创建失败，可稍后单独运行 shortcut.ps1 重试" 'warn'
        Add-StepResult '桌面快捷方式' '失败' '可单独重试'
    }

    # 顺便在开始菜单放一个「DSH 控制面板」入口（不占桌面，删了快捷方式也能找到面板）
    try {
        $smDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        if (Test-Path -LiteralPath $smDir) {
            $smLnk = Join-Path $smDir 'DSH 控制面板.lnk'
            # 与 shortcut.ps1 同理：COM 的 Save() 走系统 ANSI 代码页，非中文系统（如 cp1252）上
            # 中文名会被压成 "??????" 而保存失败。先存 ASCII 临时名，再改名成真名。
            $smTmp = Join-Path $smDir ("__dsh_panel_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".lnk")
            $sh = New-Object -ComObject WScript.Shell
            $s = $sh.CreateShortcut($smTmp)
            $s.TargetPath = 'powershell.exe'
            $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:DeployDir 'panel.ps1')`""
            $s.WorkingDirectory = $script:DeployDir
            $s.Description = 'DSH 图形控制面板'
            $s.IconLocation = "$defaultIconPath,0"
            $s.Save()
            if (Test-Path -LiteralPath $smLnk) { Remove-Item -LiteralPath $smLnk -Force }
            Move-Item -LiteralPath $smTmp -Destination $smLnk -Force
            Write-Log "已在开始菜单添加入口：DSH 控制面板" 'note'
        }
    } catch { Write-Log "开始菜单入口创建失败（不影响使用）" 'note' }

    # 固定到任务栏：Win11 已移除程序化固定能力，能自动就自动，不能就手把手引导
    if ($wantPin) {
        $targetLnk = Join-Path $desktop "$finalName.lnk"
        $pinned = $false
        try {
            $shellApp = New-Object -ComObject Shell.Application
            $folderObj = $shellApp.Namespace($desktop)
            $itemObj = $folderObj.ParseName("$finalName.lnk")
            if ($itemObj) {
                foreach ($v in $itemObj.Verbs()) {
                    $vn = "$($v.Name)".Replace('&', '')
                    if ($vn -match '任务栏|taskbar') { $v.DoIt(); $pinned = $true; break }
                }
            }
        } catch { }
        if ($pinned) {
            Write-Log "已请求固定到任务栏（若没出现，可能被系统策略拦下）" 'ok'
            Add-StepResult '任务栏固定' '已尝试自动固定' '若未生效请看下方引导'
        } else {
            Write-Log "系统不允许程序自动固定到任务栏（Win11 的限制），请手动固定一次：" 'warn'
            Write-Host "      ① 在桌面找到「$finalName」快捷方式" -ForegroundColor Yellow
            Write-Host "      ② 右键它 → 选【显示更多选项】→【固定到任务栏】(或直接右键→固定到任务栏)" -ForegroundColor Yellow
            Write-Host "      ③ 以后任务栏上点一下就能打开 DSH" -ForegroundColor Yellow
            try { Start-Process explorer.exe "/select,`"$targetLnk`"" | Out-Null } catch { }
            Write-Log "已帮你打开桌面并选中该快捷方式，右键即可固定" 'note'
            Add-StepResult '任务栏固定' '需手动（已引导）' '右侧已打开桌面并选中图标'
        }
    }
}

# ── 9. 首次启动 ──
Write-Log "第 8 步 / 启动 DSH 并等待界面就绪" 'step'
if ($NoStart) {
    Write-Log "按参数要求不自动启动（-NoStart）" 'note'
    Add-StepResult '首次启动' '已跳过' '双击桌面快捷方式即可启动'
} elseif ($DryRun) {
    Write-Log "DryRun：将启动 DSH 并轮询界面可用性" 'note'
    Add-StepResult '首次启动' '待启动(DryRun)' ''
} else {
    $startArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:DeployDir 'launcher\start-dsh.ps1'), '-InstallRoot', $script:InstallRoot, '-TimeoutSec', '150')
    & powershell.exe @startArgs
    if ($LASTEXITCODE -eq 0) { Add-StepResult '首次启动' '界面已就绪' '窗口已打开' }
    else { Add-StepResult '首次启动' '未确认就绪' '见 launcher\launch.log' }
}

# ── 汇总 ──
Write-Host ""
Write-Host "  ─────────────── 安装结果汇总 ───────────────" -ForegroundColor Cyan
$script:Steps | Format-Table -AutoSize | Out-String | Write-Host
if ($script:Warnings.Count -gt 0) {
    Write-Host "  提示（不影响使用，但请留意）：" -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "    - $w" -ForegroundColor Yellow }
}
Write-Host ""
if ($script:LogFile) { Write-Host "  完整日志：$script:LogFile" -ForegroundColor DarkGray }
Write-Host ""
Write-Host "  以后启动 DSH：双击桌面快捷方式即可。" -ForegroundColor Green
if (-not $DryRun) {
    Write-Host "  程序已安装到：$script:DeployDir" -ForegroundColor DarkGray
    Write-Host "  ★ 这个下载来的工具包文件夹现在可以删掉了，快捷方式照样能用。" -ForegroundColor Yellow
    Write-Host "  ★ 想改配置/看日志/卸载：开始菜单搜索「DSH 控制面板」，或运行 $script:DeployDir\启动面板（第二次及以后使用点击这个就好啦❀）.cmd" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  首次使用提醒：进入界面后，请在设置里填入你自己的 DeepSeek API Key" -ForegroundColor Cyan
    Write-Host "  （去 https://platform.deepseek.com 注册并创建，费用与数据都在你自己账号下）" -ForegroundColor Cyan
}
Write-Host ""

# ── 退出码：Node 没装好属于致命失败，让 .cmd / 调用方能感知 ──
$fatal = (-not $SkipNode) -and (-not $DryRun) -and (-not $nodeReady)
if ($fatal) {
    Write-Log "关键环节失败（Node.js 未就绪），请按上面的提示处理后重新运行。" 'err'
    exit 1
}
exit 0
