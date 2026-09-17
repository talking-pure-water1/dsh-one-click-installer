<#
  start-dsh.ps1 —— DSH 启动器（快捷方式实际调用的脚本）

  职责：
   1) 读 launcher\config.json
   2) 判断「已有 DSH 实例 / 端口被别的程序占用 / 端口空闲」三种情况（坑 5）
   3) 隐藏窗口启动 dsh web，并轮询到界面真正可用为止
   4) 按「单一开页者」原则决定是否打开浏览器（已装 dsh-web-open 插件时交给插件开）
   5) 把实际地址写入 serving-url.txt，日志写 launch.log

  参数：
    -InstallRoot <路径>   安装根目录（默认取本脚本上一级目录）
    -Port <n>             指定端口（默认读 config.json 的 3080）
    -NoBrowser            只启动/检测，不开浏览器
    -ProbeOnly            只做判断并打印，不启动、不开页（测试用）
    -TimeoutSec <n>       等待界面就绪的最长秒数（默认 120）
    -ForceNew             即使已有实例也另起一个（默认不会，避免 EADDRINUSE）
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$ProbeOnly,
    [int]$TimeoutSec = 120,
    [switch]$ForceNew,
    # 以「应用模式」打开：Edge/Chrome 的 --app 窗口（无地址栏/标签栏，像原生桌面软件）
    [switch]$NoAppMode,
    # 关掉应用窗口时同时停止 DSH 服务（默认不开，避免误关）
    [switch]$KillHostOnExit,
    # 只探测会用哪个浏览器、什么模式，不启动任何东西（测试用）
    [switch]$ProbeBrowser,
    # 手动指定浏览器路径
    [string]$Browser = '',
    # 用一个全新的浏览器配置打开应用窗口（默认否：共用你平时的浏览器配置，保留界面状态与上次会话）
    [switch]$IsolatedProfile,
    # 出错时弹窗提示（快捷方式会加这个参数；命令行/测试不要加，避免卡住）
    [switch]$ShowErrors,
    # 本次不要托盘图标（默认按配置，配置默认开）
    [switch]$NoTray
)

$ErrorActionPreference = 'Continue'

# 致命错误统一出口：写日志 + （快捷方式启动时）弹一个提示框，避免用户双击后「什么都没发生」
function Stop-Fatal {
    param([string]$Message, [string]$Hint = '')
    Write-Log $Message 'err'
    if ($Hint -ne '') { Write-Log $Hint 'note' }
    if ($ShowErrors) {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            $text = "$Message`r`n`r`n$Hint`r`n`r`n日志：$logFile"
            [System.Windows.Forms.MessageBox]::Show($text, 'DSH 启动失败', 'OK', 'Warning') | Out-Null
        } catch { }
    }
    exit 1
}

# 程序目录 = 本脚本所在目录（配置、日志、serving-url 都放这里，随工具包走）
$scriptDir = $PSScriptRoot
$appRootForTray = Split-Path $scriptDir -Parent   # 安装目录（launcher 的上一级），托盘图标与面板在这里
$logFile = Join-Path $scriptDir 'launch.log'
$urlFile = Join-Path $scriptDir 'serving-url.txt'
$cfgFile = Join-Path $scriptDir 'config.json'

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
    switch ($Level) {
        'ok'   { Write-Host "  [√] $Message" -ForegroundColor Green }
        'warn' { Write-Host "  [!] $Message" -ForegroundColor Yellow }
        'err'  { Write-Host "  [×] $Message" -ForegroundColor Red }
        'note' { Write-Host "      $Message" -ForegroundColor DarkGray }
        default { Write-Host "  $Message" }
    }
}

# ── 读配置 ──
$cfg = $null
if (Test-Path -LiteralPath $cfgFile) {
    try { $cfg = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null }
}
$preferredPort = 3080
if ($cfg -and $cfg.preferredPort) { $preferredPort = [int]$cfg.preferredPort }
if ($Port -gt 0) { $preferredPort = $Port }
$dshHome = ''
if ($cfg -and $cfg.dshHome) { $dshHome = $cfg.dshHome }
if (-not $dshHome) {
    if ($env:DSH_HOME) { $dshHome = $env:DSH_HOME }
    else { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
}
$pluginAutoOpen = $false
if ($cfg -and $cfg.pluginAutoOpen) { $pluginAutoOpen = [bool]$cfg.pluginAutoOpen }
# 配置里没有记录时，现查一次 profile（防止配置过期）
# 三处都查：依赖声明 / bundles / cordis.patch.yml（dsh-web-open 常走 patch 插入）
if (-not $pluginAutoOpen) {
    try {
        $pdir = Join-Path $dshHome 'profiles\web'
        $pp = Join-Path $pdir 'package.json'
        $patchFile = Join-Path $pdir 'cordis.patch.yml'
        if (Test-Path -LiteralPath $pp) {
            $pj = Get-Content -LiteralPath $pp -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pj.dependencies -and (@($pj.dependencies.PSObject.Properties.Name) -contains 'dsh-web-open')) { $pluginAutoOpen = $true }
            if (-not $pluginAutoOpen -and $pj.dsh -and $pj.dsh.profile -and $pj.dsh.profile.bundles) {
                if (@($pj.dsh.profile.bundles) -contains 'dsh-web-open') { $pluginAutoOpen = $true }
            }
        }
        if (-not $pluginAutoOpen -and (Test-Path -LiteralPath $patchFile)) {
            if ((Get-Content -LiteralPath $patchFile -Raw -Encoding UTF8) -match 'dsh-web-open') { $pluginAutoOpen = $true }
        }
    } catch { }
}

# ── 应用模式（app 窗口）相关配置 ──
$appMode = $true                       # 默认用 --app 窗口打开，视觉上像桌面软件
if ($NoAppMode) { $appMode = $false }
if ($cfg -and (@($cfg.PSObject.Properties.Name) -contains 'appMode')) { $appMode = [bool]$cfg.appMode }
if ($NoAppMode) { $appMode = $false }
$killOnExit = $false                   # 默认：关窗口不影响服务
if ($cfg -and (@($cfg.PSObject.Properties.Name) -contains 'killHostOnExit')) { $killOnExit = [bool]$cfg.killHostOnExit }
if ($KillHostOnExit) { $killOnExit = $true }
$isolatedProfile = $false              # 默认共用浏览器配置，界面状态不丢
if ($cfg -and (@($cfg.PSObject.Properties.Name) -contains 'isolatedBrowserProfile')) { $isolatedProfile = [bool]$cfg.isolatedBrowserProfile }
if ($IsolatedProfile) { $isolatedProfile = $true }
$useTray = $true                       # 托盘图标（可关：它是隐藏运行的辅助进程，部分安全软件会敏感）
if ($cfg -and (@($cfg.PSObject.Properties.Name) -contains 'trayIcon')) { $useTray = [bool]$cfg.trayIcon }
if ($NoTray) { $useTray = $false }
# 应用模式的独立浏览器 profile：优先放数据目录，避免把浏览器缓存塞进工具目录（也避免被打进发布包）
$appProfileDir = ''
if ($cfg -and (@($cfg.PSObject.Properties.Name) -contains 'installRoot') -and "$($cfg.installRoot)" -ne '') {
    $dataRoot = "$($cfg.installRoot)"
    if (Test-Path -LiteralPath (Split-Path $dataRoot -Parent)) { $appProfileDir = Join-Path $dataRoot 'app-profile' }
}
if ($appProfileDir -eq '') { $appProfileDir = Join-Path $scriptDir 'app-profile' }

# ── 工具函数 ──
function Test-PortOpen {
    param([int]$P)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $P, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(600)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Test-IsDshService {
    param([int]$P)
    # 先看 HTTP 是否是 DSH 的界面（不依赖进程查询权限）
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$P/" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200 -and $r.Content -match '__DSH_BOOT__|dsh-client|DSH') { return $true }
        return $false
    } catch { }
    # 兜底：看占用进程命令行是否含 bin.js（DSH 的入口）
    try {
        $conn = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($conn.OwningProcess)" -ErrorAction SilentlyContinue
            if ($proc -and $proc.CommandLine -match 'bin\.js') { return $true }
        }
    } catch { }
    return $false
}

function Find-FreePort {
    param([int]$Start, [int]$Count = 25)
    for ($p = $Start; $p -lt ($Start + $Count); $p++) {
        if (-not (Test-PortOpen -P $p)) { return $p }
    }
    return 0   # 0 = 交给 dsh 自己随机挑
}

function Get-SavedUrl {
    if (Test-Path -LiteralPath $urlFile) {
        try {
            $u = (Get-Content -LiteralPath $urlFile -Raw -Encoding UTF8).Trim()
            if ($u -match '^https?://127\.0\.0\.1:(\d+)') { return $u }
        } catch { }
    }
    return ''
}

function Get-DshStartCommand {
    param([int]$P)
    $portArg = if ($P -gt 0) { " --port $P" } else { "" }
    # 1) 配置里记录的全局 dsh
    if ($cfg -and $cfg.dshCommand -and (Test-Path -LiteralPath $cfg.dshCommand)) {
        return @{ File = 'cmd.exe'; Args = @('/c', "`"$($cfg.dshCommand)`" web$portArg") }
    }
    # 2) npm 全局目录里的 dsh.cmd
    try {
        $prefix = (npm config get prefix) 2>$null
        if ($prefix -is [array]) { $prefix = $prefix[0] }
        if ($prefix) {
            $cand = Join-Path $prefix 'dsh.cmd'
            if (Test-Path -LiteralPath $cand) { return @{ File = 'cmd.exe'; Args = @('/c', "`"$cand`" web$portArg") } }
        }
    } catch { }
    # 3) PATH 里的 dsh
    $g = Get-Command dsh -ErrorAction SilentlyContinue
    if ($g) { return @{ File = 'cmd.exe'; Args = @('/c', "`"$($g.Source)`" web$portArg") } }
    # 4) npx 兜底
    return @{ File = 'cmd.exe'; Args = @('/c', "npx -y @deepseek-ai/dsh web$portArg") }
}

function Find-AppBrowser {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return $Explicit }
    $cands = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:ProgramFiles\Vivaldi\Application\vivaldi.exe"
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return ''
}

function Open-DshWindow {
    param([string]$Url)
    # 应用模式：--app 窗口，没有地址栏和标签栏，视觉上就是桌面软件
    if ($appMode) {
        $b = Find-AppBrowser -Explicit $Browser
        if ($b -ne '') {
            $bargs = @("--app=$Url", '--no-first-run', '--no-default-browser-check')
            # 默认共用你平时的浏览器配置（保留界面状态/上次会话）；-IsolatedProfile 才用独立配置
            if ($isolatedProfile) { $bargs += "--user-data-dir=$appProfileDir" }
            try {
                $p = Start-Process -FilePath $b -ArgumentList $bargs -PassThru
                Write-Log "已用应用模式打开（$(Split-Path $b -Leaf)，独立窗口无地址栏）" 'ok'
                return $p
            } catch {
                Write-Log "应用模式打开失败：$($_.Exception.Message)，改用默认浏览器" 'warn'
            }
        } else {
            Write-Log "未找到 Edge/Chrome/Brave/Vivaldi，退回默认浏览器标签页" 'note'
        }
    }
    try {
        Start-Process $Url | Out-Null
        Write-Log "已打开浏览器：$Url" 'ok'
    } catch {
        Write-Log "打开浏览器失败，请手动访问：$Url" 'warn'
    }
    return $null
}

function Start-TrayIfMissing {
    param([string]$Url, [int]$HostPid)
    # 应用模式下我们会关掉插件的自动开页（避免多开标签页），托盘图标由我们自己拉起。
    # 用自带的 dsh-tray.ps1（而不是插件的托盘）：它能提供「安全退出」，且随安装目录一起存在。
    try {
        $tray = Join-Path $scriptDir 'dsh-tray.ps1'
        if (-not (Test-Path -LiteralPath $tray)) {
            # 退化：如果安装目录里没有自带托盘，才用插件自带的
            $tray = Join-Path $dshHome 'profiles\web\node_modules\dsh-web-open\assets\dsh-tray-helper.ps1'
            if (-not (Test-Path -LiteralPath $tray)) { return }
        }
        $up = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -match 'dsh-tray' }
        if ($up) { return }
        $ico = Join-Path $appRootForTray 'assets\dsh.ico'
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $tray, '-HostPid', "$HostPid", '-Url', $Url, '-IconPath', $ico, '-AppRoot', $appRootForTray
        ) -WindowStyle Hidden | Out-Null
        Write-Log "已拉起托盘图标（右键可安全退出 / 重启 / 更新）" 'note'
    } catch { }
}

# ── 主逻辑 ──
Write-Host ""
Write-Log "启动器开始（程序目录：$scriptDir）"

if ($ProbeBrowser) {
    $b = Find-AppBrowser -Explicit $Browser
    $name = if ($b -ne '') { Split-Path $b -Leaf } else { 'none' }
    Write-Host "  browser=$name path=`"$b`" appMode=$appMode killOnExit=$killOnExit"
    exit 0
}

$StartedByUs = $false

# 情况 A：首选端口上已有 DSH 实例 → 复用，不重复启动
$savedUrl = Get-SavedUrl
if ((Test-PortOpen -P $preferredPort) -and (Test-IsDshService -P $preferredPort)) {
    $url = "http://127.0.0.1:$preferredPort"
    Write-Log "检测到 DSH 正在运行（$url），不再重复启动（避免端口冲突）" 'ok'
    if ($ProbeOnly) { Write-Host "  decision=reuse url=$url"; exit 0 }
    try { Set-Content -LiteralPath $urlFile -Value $url -Encoding UTF8 } catch { }
    if (-not $NoBrowser) { [void](Open-DshWindow -Url $url) }
    exit 0
}

# 情况 B：首选端口被别的程序占用 → 换端口
$targetPort = $preferredPort
if (Test-PortOpen -P $preferredPort) {
    Write-Log "端口 $preferredPort 被其它程序占用" 'warn'
    $targetPort = Find-FreePort -Start ($preferredPort + 1) -Count 25
    if ($targetPort -eq 0) { $targetPort = Find-FreePort -Start 3081 -Count 40 }
    if ($targetPort -gt 0) { Write-Log "改用空闲端口 $targetPort" 'ok' }
    else { Write-Log "未找到空闲端口，交给 dsh 自行选择端口" 'warn' }
}

if ($ProbeOnly) {
    Write-Host "  decision=start port=$(if ($targetPort -gt 0) { $targetPort } else { 'auto' }) pluginAutoOpen=$pluginAutoOpen"
    exit 0
}

# 情况 C：端口空闲（或已换端口）→ 启动
$cmd = Get-DshStartCommand -P $targetPort
Write-Log "启动命令：$($cmd.File) $($cmd.Args -join ' ')" 'note'
if ($dshHome) { $env:DSH_HOME = $dshHome }

# 应用模式：关掉插件的自动开页，避免同时冒出一个标签页（窗口由启动器负责）
$useAppOwnWindow = $false
if (-not $NoBrowser -and $appMode -and (Find-AppBrowser -Explicit $Browser) -ne '') {
    $env:DSH_WEB_OPEN = '0'
    $useAppOwnWindow = $true
    Write-Log "应用模式：已临时设置 DSH_WEB_OPEN=0（插件不自动开页，窗口交给启动器）" 'note'
}

$stdout = Join-Path $scriptDir 'dsh-stdout.log'
$stderr = Join-Path $scriptDir 'dsh-stderr.log'
# 工作目录优先用数据目录（config.installRoot），不可用时退回程序目录
$workDir = $scriptDir
if (-not $InstallRoot -and $cfg -and $cfg.installRoot) { $InstallRoot = "$($cfg.installRoot)" }
if ($InstallRoot -and (Test-Path -LiteralPath $InstallRoot)) { $workDir = $InstallRoot }
$proc = $null
try {
    $proc = Start-Process -FilePath $cmd.File -ArgumentList $cmd.Args -WorkingDirectory $workDir `
        -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $StartedByUs = $true
    Write-Log "已启动 DSH（进程 PID $($proc.Id)），等待界面就绪…"
} catch {
    Stop-Fatal -Message "启动失败：$($_.Exception.Message)" -Hint "可尝试在命令行手动运行：npx @deepseek-ai/dsh web"
}

# 轮询就绪：既探测目标端口，也从日志里发现真实端口（dsh 可能自行换端口）
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$readyUrl = ''
$lastTick = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1200
    $lastTick++
    if ($lastTick % 8 -eq 0) { Write-Log "仍在等待…（已等 $([int]((Get-Date) - $deadline.AddSeconds(-$TimeoutSec)).TotalSeconds) 秒）" 'note' }

    $candidates = @()
    if ($targetPort -gt 0) { $candidates += $targetPort }
    foreach ($f in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $f) {
            try {
                $txt = Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                foreach ($m in [regex]::Matches("$txt", 'http://127\.0\.0\.1:(\d+)')) {
                    $candidates += [int]$m.Groups[1].Value
                }
            } catch { }
        }
    }
    foreach ($p in ($candidates | Select-Object -Unique)) {
        if ($p -le 0) { continue }
        if (Test-IsDshService -P $p) { $readyUrl = "http://127.0.0.1:$p"; break }
    }
    if ($readyUrl -ne '') { break }
    if ($proc -and $proc.HasExited) {
        Stop-Fatal -Message "DSH 进程已退出（退出码 $($proc.ExitCode)），启动失败" -Hint "详见日志：$stderr"
    }
}

if ($readyUrl -eq '') {
    Stop-Fatal -Message "等待超时（$TimeoutSec 秒）仍未确认界面可用" -Hint "请看日志排查：$stdout"
}

try { Set-Content -LiteralPath $urlFile -Value $readyUrl -Encoding UTF8 } catch { }
Write-Log "界面已就绪：$readyUrl" 'ok'

$winProc = $null
if ($NoBrowser) {
    Write-Log "按参数要求不打开浏览器（-NoBrowser）" 'note'
} elseif ($useAppOwnWindow) {
    $winProc = Open-DshWindow -Url $readyUrl
    if ($useTray) { Start-TrayIfMissing -Url $readyUrl -HostPid $proc.Id }
    else { Write-Log "按配置不启动托盘图标（trayIcon=false）" 'note' }
} elseif ($pluginAutoOpen) {
    Write-Log "已装 dsh-web-open 插件：由插件负责打开浏览器，启动器不重复开页" 'note'
    Write-Log "如果浏览器没弹出，请手动访问：$readyUrl" 'note'
} else {
    [void](Open-DshWindow -Url $readyUrl)
}

# 可选：关掉应用窗口就停止服务（默认关闭，避免误关）
if ($killOnExit -and $winProc -ne $null -and $StartedByUs) {
    Write-Log "已启用「关窗即停服务」：关闭应用窗口后将自动停止 DSH" 'note'
    try { $winProc.WaitForExit() } catch { }
    Write-Log "应用窗口已关闭，正在停止 DSH（PID $($proc.Id)）…"
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
}

exit 0
