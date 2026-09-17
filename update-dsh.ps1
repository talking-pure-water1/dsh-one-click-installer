<#
  update-dsh.ps1 —— 一键更新 DSH 到最新版

  流程：读当前版本 → 查最新版本 → npm 全局更新 → 复核版本 → （可选）重启服务使新版生效

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File update-dsh.ps1            # 交互式
    ... -File update-dsh.ps1 -DryRun -NoRestart -NonInteractive                   # 只看计划
    ... -File update-dsh.ps1 -Restart                                             # 更新完自动重启服务
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Restart,
    [switch]$NoRestart,
    [switch]$NonInteractive,
    [switch]$Force,
    [string]$InstallRoot = ''
)

$ErrorActionPreference = 'Continue'
if ($InstallRoot -eq '') { $InstallRoot = Split-Path -Parent $PSScriptRoot }
$launcherDir = Join-Path $PSScriptRoot 'launcher'
if (-not (Test-Path -LiteralPath $launcherDir)) { $launcherDir = $PSScriptRoot }
$logFile = Join-Path $launcherDir 'update.log'
$cfgFile = Join-Path $launcherDir 'config.json'

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

function Get-DshCmd {
    param([string]$Prefix)
    $cands = @()
    if ($Prefix) { $cands += (Join-Path $Prefix 'dsh.cmd') }
    $g = Get-Command dsh -ErrorAction SilentlyContinue
    if ($g) { $cands += $g.Source }
    foreach ($c in $cands) {
        if (-not $c) { continue }
        if ($c -match '\\_npx\\' -or $c -match '\\node_modules\\') { continue }  # npx 临时缓存不算
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return ''
}

function Get-DshVersion {
    param([string]$DshCmd)
    if (-not $DshCmd) { return '' }
    try {
        $v = (& $DshCmd --version) 2>$null
        if ($v -is [array]) { $v = $v | Select-Object -First 1 }
        return "$v".Trim()
    } catch { return '' }
}

function Get-RunningDshPid {
    foreach ($p in @(3080, 3081, 3082, 8080)) {
        try {
            $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $conn) { continue }
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($conn.OwningProcess)" -ErrorAction SilentlyContinue
            if ($proc -and $proc.CommandLine -match 'bin\.js') { return [PSCustomObject]@{ Pid = $conn.OwningProcess; Port = $p } }
        } catch { }
    }
    return $null
}

Write-Host ""
Write-Host "  ══════ DSH 更新工具 ══════" -ForegroundColor Cyan
if ($DryRun) { Write-Host "  模式：只检查（DryRun），不会真的更新" -ForegroundColor Magenta }
Write-Host ""

$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npm) { Write-Log "找不到 npm，请先运行「安装DSH（初次使用点击这里就好啦⭐️）.cmd」补齐环境" 'err'; exit 1 }

$prefix = ''
try { $prefix = (npm config get prefix) 2>$null; if ($prefix -is [array]) { $prefix = $prefix[0] } } catch { }
$dshCmd = Get-DshCmd -Prefix $prefix
$current = Get-DshVersion -DshCmd $dshCmd
if ($current -eq '') { Write-Log "当前未检测到可用的 dsh 命令（将直接安装最新版）" 'warn' }
else { Write-Log "当前版本：$current" }

# 查最新版（走已配置的镜像源）
$latest = ''
if (-not $DryRun) {
    try {
        $latest = (& npm view '@deepseek-ai/dsh' version) 2>$null
        if ($latest -is [array]) { $latest = $latest | Select-Object -First 1 }
        $latest = "$latest".Trim()
    } catch { }
    if ($latest -eq '') { Write-Log "查不到最新版本（网络或镜像问题），将直接执行更新" 'warn' }
    else { Write-Log "最新版本：$latest" }
} else {
    Write-Log "DryRun：将执行 npm view @deepseek-ai/dsh version 查询最新版" 'note'
}

if ($latest -ne '' -and $current -eq $latest -and -not $Force) {
    Write-Log "已经是最新版（$current），无需更新" 'ok'
} else {
    if ($DryRun) {
        Write-Log "DryRun：将执行 npm i -g @deepseek-ai/dsh" 'note'
    } else {
        Write-Log "开始更新（npm i -g @deepseek-ai/dsh）…"
        & npm i -g '@deepseek-ai/dsh' 2>&1 | ForEach-Object { Write-Log ("npm: " + $_) 'note' }
        $prefixAfter = ''
        try { $prefixAfter = (npm config get prefix) 2>$null; if ($prefixAfter -is [array]) { $prefixAfter = $prefixAfter[0] } } catch { }
        $dshCmdAfter = Get-DshCmd -Prefix $prefixAfter
        $after = Get-DshVersion -DshCmd $dshCmdAfter
        if ($after -ne '' -and $after -ne $current) { Write-Log "更新完成：$current → $after" 'ok' }
        elseif ($after -ne '') { Write-Log "更新命令已执行，版本仍为 $after（可能已是最新）" 'ok' }
        else { Write-Log "更新后仍无法读取版本，请查看上方 npm 输出" 'warn' }
        $current = $after
    }
}

# 重启建议
$running = Get-RunningDshPid
if ($running) {
    Write-Host ""
    Write-Log "检测到 DSH 正在运行（PID $($running.Pid)，端口 $($running.Port)）：新版本要重启服务才生效" 'warn'
    $doRestart = $false
    if ($Restart) { $doRestart = $true }
    elseif (-not $NoRestart -and -not $NonInteractive -and -not $DryRun) {
        $a = Read-Host "  现在重启 DSH 使新版本生效？(Y/N)"
        $doRestart = ($a -match '^[Yy]')
    }
    if ($DryRun) {
        Write-Log "DryRun：如需生效，之后可执行 start-dsh.ps1（或重启服务）" 'note'
    } elseif ($doRestart) {
        Write-Log "正在停止旧服务（PID $($running.Pid)）…"
        try { Stop-Process -Id $running.Pid -Force -ErrorAction SilentlyContinue } catch { }
        $waited = 0
        while ($waited -lt 20) {
            Start-Sleep -Milliseconds 500
            $waited++
            $still = Get-NetTCPConnection -LocalPort $running.Port -State Listen -ErrorAction SilentlyContinue
            if (-not $still) { break }
        }
        Write-Log "旧服务已停止，正在启动新版本…"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'launcher\start-dsh.ps1') -InstallRoot $InstallRoot
    } else {
        Write-Log "已跳过重启。想让新版本生效：关掉 DSH 后双击桌面快捷方式，或运行 launcher\start-dsh.ps1" 'note'
    }
} else {
    Write-Log "当前没有运行中的 DSH 服务，下次启动即为新版本" 'ok'
}

Write-Host ""
exit 0
