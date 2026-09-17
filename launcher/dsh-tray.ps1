<#
  dsh-tray.ps1 —— DSH 托盘图标（右下角），提供「安全退出」等常用操作

  为什么自己写一个：
    - 第三方插件自带的托盘无法保证「优雅退出」，强杀进程会让最后的会话数据来不及落盘（「失忆」就是这么来的）；
    - 本脚本放在【安装目录】里，所以**删掉下载来的工具包之后它依然在**，快捷方式、托盘、更新功能都照常可用。

  菜单：
    打开 DSH 界面 / 重启 DSH / 安全退出 DSH（推荐）/ 更新 DSH / 打开控制面板 / 退出托盘

  用法（一般由启动器自动拉起，不需要手动运行）：
    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-tray.ps1 -HostPid 1234 -Url http://127.0.0.1:3080
    ... -File dsh-tray.ps1 -SelfTest        # 只打印菜单项，不显示图标（测试用）
#>
[CmdletBinding()]
param(
    [int]$HostPid = 0,
    [string]$Url = '',
    [string]$IconPath = '',
    [string]$AppRoot = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot                    # …\app\launcher
if ($AppRoot -eq '') { $AppRoot = Split-Path $scriptDir -Parent }
$startPs = Join-Path $scriptDir 'start-dsh.ps1'
$stopPs = Join-Path $scriptDir 'stop-dsh.ps1'
$updatePs = Join-Path $AppRoot 'update-dsh.ps1'
$panelPs = Join-Path $AppRoot 'panel.ps1'
if ($IconPath -eq '' -or -not (Test-Path -LiteralPath $IconPath)) { $IconPath = Join-Path $AppRoot 'assets\dsh.ico' }
if ($Url -eq '') {
    $urlFile = Join-Path $scriptDir 'serving-url.txt'
    if (Test-Path -LiteralPath $urlFile) { $Url = (Get-Content -LiteralPath $urlFile -Raw -Encoding UTF8).Trim() }
}
if ($Url -eq '') { $Url = 'http://127.0.0.1:3080' }

$menuItems = @(
    '打开 DSH 界面',
    '重启 DSH',
    '安全退出 DSH（推荐）',
    '更新 DSH',
    '打开控制面板',
    '退出托盘'
)

if ($SelfTest) {
    Write-Host "  hostPid=$HostPid url=$Url appRoot=$AppRoot"
    Write-Host "  startPs=$(Test-Path -LiteralPath $startPs) stopPs=$(Test-Path -LiteralPath $stopPs) updatePs=$(Test-Path -LiteralPath $updatePs) panelPs=$(Test-Path -LiteralPath $panelPs)"
    Write-Host "  菜单项: $($menuItems -join ' | ')"
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Invoke-Hidden {
    param([string]$Script, [string[]]$ScriptArgs)
    if (-not (Test-Path -LiteralPath $Script)) { return $false }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ScriptArgs
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden | Out-Null
    return $true
}

$notify = New-Object System.Windows.Forms.NotifyIcon
try {
    if (Test-Path -LiteralPath $IconPath) { $notify.Icon = New-Object System.Drawing.Icon($IconPath) }
    else { $notify.Icon = [System.Drawing.SystemIcons]::Application }
} catch { $notify.Icon = [System.Drawing.SystemIcons]::Application }
$notify.Text = 'DSH（DeepSeek Harness）'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miOpen = $menu.Items.Add('打开 DSH 界面')
$miOpen.add_Click({
    try {
        if (Test-Path -LiteralPath $startPs) { Invoke-Hidden -Script $startPs -ScriptArgs @('-InstallRoot', $AppRoot) | Out-Null }
        else { Start-Process $Url | Out-Null }
    } catch { }
})

$miRestart = $menu.Items.Add('重启 DSH')
$miRestart.add_Click({
    try {
        Invoke-Hidden -Script $stopPs -ScriptArgs @('-Quiet') | Out-Null
        Start-Sleep -Seconds 3
        Invoke-Hidden -Script $startPs -ScriptArgs @('-InstallRoot', $AppRoot) | Out-Null
        $notify.ShowBalloonTip(3000, 'DSH 正在重启', '先安全退出，再重新启动。', [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
})

$miSafeExit = $menu.Items.Add('安全退出 DSH（推荐）')
$miSafeExit.add_Click({
    try {
        $notify.ShowBalloonTip(3000, 'DSH 正在安全退出', '会让它把会话数据写完再关闭，稍等几秒。', [System.Windows.Forms.ToolTipIcon]::Info)
        Invoke-Hidden -Script $stopPs -ScriptArgs @() | Out-Null
    } catch { }
})

$menu.Items.Add('-') | Out-Null

$miUpdate = $menu.Items.Add('更新 DSH')
$miUpdate.add_Click({
    try {
        if (Test-Path -LiteralPath $updatePs) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updatePs) -WindowStyle Normal | Out-Null
        } else {
            $notify.ShowBalloonTip(3000, '找不到更新脚本', "请用开始菜单的 DSH 控制面板更新。", [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    } catch { }
})

$miPanel = $menu.Items.Add('打开控制面板')
$miPanel.add_Click({
    try {
        if (Test-Path -LiteralPath $panelPs) { Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $panelPs) | Out-Null }
    } catch { }
})

$menu.Items.Add('-') | Out-Null

$miQuit = $menu.Items.Add('退出托盘')
$miQuit.add_Click({
    try { $notify.Visible = $false } catch { }
    [System.Windows.Forms.Application]::ExitThread()
})

$notify.ContextMenuStrip = $menu
$notify.add_MouseDoubleClick({ try { $miOpen.PerformClick() } catch { } })

try {
    $notify.ShowBalloonTip(3000, 'DSH 已在运行', "右键这里可以安全退出、重启、更新。`n界面：$Url", [System.Windows.Forms.ToolTipIcon]::Info)
} catch { }

# 宿主进程退出后，托盘自己也退出，避免留下孤儿图标
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({
    if ($HostPid -gt 0 -and -not (Get-Process -Id $HostPid -ErrorAction SilentlyContinue)) {
        try { $notify.Visible = $false } catch { }
        [System.Windows.Forms.Application]::ExitThread()
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run()
try { $notify.Visible = $false; $notify.Dispose() } catch { }
exit 0
