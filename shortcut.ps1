<#
  shortcut.ps1 —— 创建/修改 DSH 桌面快捷方式（支持自定义名称与图标）

  设计要点：
   - 桌面路径用系统 API 取真实位置（兼容 360/OneDrive 迁移，坑 3）
   - 目标：powershell 隐藏运行 launcher\start-dsh.ps1（不再用 wscript/.vbs，减少杀软误报）
   - 默认图标 assets\dsh.ico，也可选任意 .ico/.exe/.dll
   - 写入后立刻回读 .lnk 属性并打印，确保真的生效

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File shortcut.ps1              # 交互式
    ... -File shortcut.ps1 -Name "我的DSH" -IconPath "D:\a.ico" -Force            # 无人值守
    ... -File shortcut.ps1 -LauncherRoot "D:\dsh-launcher" -DryRun                # 只预览
#>
[CmdletBinding()]
param(
    [string]$Name = '',
    [string]$IconPath = '',
    [string]$LauncherRoot = '',
    [string]$DesktopPath = '',
    [switch]$Interactive,
    [switch]$NonInteractive,
    [switch]$Force,
    [switch]$StartMenu,
    [switch]$DryRun,
    # 清理「指向同一个启动器」的其它快捷方式（避免反复安装后桌面堆一串同名/异名图标）
    [switch]$RemoveDuplicates
)

$ErrorActionPreference = 'Stop'

function Get-RealDesktop {
    param([string]$Override)
    if ($Override -ne '') { return $Override }
    try {
        $p = [Environment]::GetFolderPath('Desktop')
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    try {
        $sh = New-Object -ComObject WScript.Shell
        return $sh.SpecialFolders.Item('Desktop')
    } catch { }
    return (Join-Path $env:USERPROFILE 'Desktop')
}

function Get-InvalidNameChars { return [System.IO.Path]::GetInvalidFileNameChars() }

function Repair-ShortcutName {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return 'DSH Web' }
    $clean = $Raw.Trim()
    foreach ($ch in (Get-InvalidNameChars)) { $clean = $clean.Replace([string]$ch, '') }
    $clean = $clean.TrimEnd('.')
    if ($clean -eq '') { return 'DSH Web' }
    if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60) }
    return $clean
}

function Select-IconFile {
    param([string]$DefaultIcon, [string]$Root)
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '选择快捷方式图标（.ico / .exe / .dll）'
    $dlg.Filter = '图标文件 (*.ico)|*.ico|程序或图标库 (*.exe;*.dll)|*.exe;*.dll|所有文件 (*.*)|*.*'
    if (Test-Path -LiteralPath $Root) { $dlg.InitialDirectory = $Root }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $DefaultIcon
}

function Ask-Name {
    param([string]$Default)
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null
        $answer = [Microsoft.VisualBasic.Interaction]::InputBox(
            "给这个快捷方式起个名字（双击它就能打开 DSH）：", 'DSH 快捷方式名称', $Default)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer
    } catch {
        return $Default
    }
}

# ── 解析「程序目录」（本脚本所在目录，启动器就在它的 launcher 子目录里）──
if ($LauncherRoot -eq '') {
    $LauncherRoot = $PSScriptRoot
}
# 启动目标：直接用 powershell 隐藏运行启动器。
# 不再使用 wscript + .vbs（那是杀毒软件最敏感的行为特征，能少一个就少一个）。
$startPs = Join-Path $LauncherRoot 'launcher\start-dsh.ps1'
if (-not (Test-Path -LiteralPath $startPs)) {
    Write-Host "  [×] 找不到启动器：$startPs" -ForegroundColor Red
    Write-Host "      请确认 shortcut.ps1 与本目录下的 launcher 文件夹在一起（-LauncherRoot 可显式指定）。" -ForegroundColor Yellow
    exit 2
}
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startPs`" -InstallRoot `"$LauncherRoot`" -ShowErrors"

$defaultIcon = Join-Path $LauncherRoot 'assets\dsh.ico'
$desktop = Get-RealDesktop -Override $DesktopPath
if ([string]::IsNullOrWhiteSpace($desktop)) {
    $desktop = Join-Path $env:USERPROFILE 'Desktop'
}
Write-Host "  [i] 桌面目录：$desktop（存在=$(Test-Path -LiteralPath $desktop)）" -ForegroundColor DarkGray

# ── 交互式询问名称与图标 ──
$interactiveMode = $Interactive -or (-not $NonInteractive)
if ($Name -eq '') {
    if ($interactiveMode) { $Name = Ask-Name -Default 'DSH Web' } else { $Name = 'DSH Web' }
}
$Name = Repair-ShortcutName -Raw $Name

if ($IconPath -eq '') {
    if ($interactiveMode) {
        $picked = Select-IconFile -DefaultIcon $defaultIcon -Root $LauncherRoot
        $IconPath = $picked
    } else {
        $IconPath = $defaultIcon
    }
}
$iconFinal = if (Test-Path -LiteralPath $IconPath) { $IconPath } else { $defaultIcon }
if ($iconFinal -eq $defaultIcon -and -not (Test-Path -LiteralPath $defaultIcon)) {
    Write-Host "  [!] 未找到默认图标 $defaultIcon，快捷方式将使用系统默认图标" -ForegroundColor Yellow
    $iconFinal = ''
}

$lnkPath = Join-Path $desktop "$Name.lnk"

# 桌面目录不一定存在（全新用户、无人值守会话、CI 机器都可能没有），先补出来再写快捷方式
if (-not $DryRun -and -not (Test-Path -LiteralPath $desktop)) {
    try { New-Item -ItemType Directory -Path $desktop -Force | Out-Null } catch { }
    if (Test-Path -LiteralPath $desktop) { Write-Host "  [i] 桌面目录原本不存在，已创建：$desktop" -ForegroundColor DarkGray }
    else {
        Write-Host "  [×] 桌面目录无法创建：$desktop" -ForegroundColor Red
        exit 3
    }
}

Write-Host ""
Write-Host "  名称：$Name"
Write-Host "  位置：$lnkPath"
Write-Host "  目标：$psExe"
Write-Host "  参数：$psArgs"
Write-Host "  图标：$(if ($iconFinal) { $iconFinal } else { '(系统默认)' })"
Write-Host ""

if ($DryRun) { Write-Host "  [DryRun] 仅预览，不写入" -ForegroundColor Magenta; exit 0 }

if ((Test-Path -LiteralPath $lnkPath) -and -not $Force) {
    $overwrite = $true
    if ($interactiveMode) {
        $ans = Read-Host "  已存在同名快捷方式，是否覆盖？(Y/N)"
        $overwrite = ($ans -match '^[Yy]')
    }
    if (-not $overwrite) { Write-Host "  已取消，未做修改。" -ForegroundColor Yellow; exit 0 }
}

# ── 创建快捷方式 ──
try {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    # 注意：CreateShortcut 会沿用已存在 .lnk 的旧属性，所以每个字段都要显式覆盖，
    # 否则旧快捷方式残留的 Arguments 会被继承下来（曾经踩过这个坑）。
    $lnk.TargetPath = $psExe
    $lnk.Arguments = $psArgs
    $lnk.WorkingDirectory = $LauncherRoot
    $lnk.Description = '一键启动 DSH（DeepSeek Harness）'
    $lnk.WindowStyle = 7
    if ($iconFinal -ne '') { $lnk.IconLocation = "$iconFinal,0" } else { $lnk.IconLocation = '' }
    $lnk.Save()
} catch {
    Write-Host "  [×] 创建快捷方式失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      目标文件：$lnkPath" -ForegroundColor DarkGray
    Write-Host "      目标目录：$desktop（存在=$(Test-Path -LiteralPath $desktop)）" -ForegroundColor DarkGray
    Write-Host "      会话=$(try { (Get-Process -Id $PID).SessionId } catch { '?' }) 交互式=$([Environment]::UserInteractive)" -ForegroundColor DarkGray
    if ($_.ScriptStackTrace) { Write-Host "      调用栈：$($_.ScriptStackTrace)" -ForegroundColor DarkGray }
    exit 3
}

# ── 回读校验 ──
try {
    $verify = $shell.CreateShortcut($lnkPath)
    $okTarget = ("$($verify.TargetPath)" -like '*powershell*') -and ("$($verify.Arguments)" -match 'start-dsh\.ps1')
    Write-Host "  [√] 已创建：$lnkPath" -ForegroundColor Green
    Write-Host "      目标回读：$($verify.TargetPath)" -ForegroundColor DarkGray
    Write-Host "      参数回读：$($verify.Arguments)" -ForegroundColor DarkGray
    Write-Host "      工作目录：$($verify.WorkingDirectory)" -ForegroundColor DarkGray
    Write-Host "      图标回读：$($verify.IconLocation)" -ForegroundColor DarkGray
    if (-not $okTarget) { Write-Host "  [!] 目标回读不一致，请手动检查" -ForegroundColor Yellow }
} catch {
    Write-Host "  [!] 回读校验失败（文件可能已创建成功）：$($_.Exception.Message)" -ForegroundColor Yellow
}

# ── 清理重复：桌面/开始菜单里指向同一个启动器的其它快捷方式 ──
if ($RemoveDuplicates) {
    $dirs = @($desktop, (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))
    $removed = 0
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.lnk -ErrorAction SilentlyContinue)) {
            if ($f.FullName -eq $lnkPath) { continue }
            try {
                $s = $shell.CreateShortcut($f.FullName)
                $isOurs = ("$($s.Arguments)" -match 'start-dsh\.ps1') -or
                          ("$($s.TargetPath)" -match '启动DSH\.vbs$') -or
                          ("$($s.Arguments)" -match '启动DSH\.vbs')
                if ($isOurs) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    Write-Host "  [√] 清理重复快捷方式：$($f.Name)" -ForegroundColor DarkYellow
                    $removed++
                }
            } catch { }
        }
    }
    if ($removed -eq 0) { Write-Host "      没有发现重复的快捷方式" -ForegroundColor DarkGray }
}

# ── 可选：开始菜单 ──
if ($StartMenu) {
    try {
        $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        if (Test-Path -LiteralPath $sm) {
            $smLnk = Join-Path $sm "$Name.lnk"
            $s2 = $shell.CreateShortcut($smLnk)
            $s2.TargetPath = $psExe
            $s2.Arguments = $psArgs
            $s2.WorkingDirectory = $LauncherRoot
            $s2.Description = '一键启动 DSH（DeepSeek Harness）'
            $s2.WindowStyle = 7
            if ($iconFinal -ne '') { $s2.IconLocation = "$iconFinal,0" } else { $s2.IconLocation = '' }
            $s2.Save()
            Write-Host "  [√] 开始菜单项：$smLnk" -ForegroundColor Green
        }
    } catch { Write-Host "  [!] 开始菜单项创建失败：$($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host ""
exit 0
