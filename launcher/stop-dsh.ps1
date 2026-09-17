<#
  stop-dsh.ps1 —— 安全停止 DSH（避免「退出后失忆」）

  为什么需要它：
    DSH 的会话是按批写入 JSONL 并 fsync 的。直接强杀进程（任务管理器结束任务、
    Stop-Process -Force）会让最后一批数据来不及落盘，重开时可能出现历史读取异常。
    正确做法是像在终端里按 Ctrl+C 那样，让 Node 有机会跑完退出处理后再关闭。

  做法（按顺序尝试）：
    1) 优雅：向宿主的控制台发送 CTRL_C（AttachConsole + GenerateConsoleCtrlEvent），等待它自行退出；
    2) 兜底：超时仍在运行才强制结束，并明确记录「本次为强制结束」。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File stop-dsh.ps1            # 按配置端口找宿主
    ... -File stop-dsh.ps1 -ProbeOnly                                          # 只看状态，不停
    ... -File stop-dsh.ps1 -Port 3081 -TimeoutSec 20                           # 指定端口/超时
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [int]$Port = 0,
    [int]$TimeoutSec = 20,
    [switch]$ProbeOnly,
    [switch]$Quiet,
    [switch]$Force      # 跳过优雅步骤，直接强杀（不推荐）
)

$ErrorActionPreference = 'Continue'

# 程序目录（本脚本所在目录）
$scriptDir = $PSScriptRoot
$cfgFile = Join-Path $scriptDir 'config.json'
$cfg = $null
if (Test-Path -LiteralPath $cfgFile) {
    try { $cfg = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
if ($InstallRoot -eq '' -and $cfg -and $cfg.installRoot) { $InstallRoot = "$($cfg.installRoot)" }
if ($InstallRoot -eq '') { $InstallRoot = Split-Path $scriptDir -Parent }
$urlFile = Join-Path $scriptDir 'serving-url.txt'
$logFile = Join-Path $scriptDir 'launch.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
    if ($Quiet) { return }
    switch ($Level) {
        'ok'   { Write-Host "  [√] $Message" -ForegroundColor Green }
        'warn' { Write-Host "  [!] $Message" -ForegroundColor Yellow }
        'err'  { Write-Host "  [×] $Message" -ForegroundColor Red }
        'note' { Write-Host "      $Message" -ForegroundColor DarkGray }
        default { Write-Host "  $Message" }
    }
}

function Test-PortOpen {
    param([int]$P)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $P, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(500)) { return $false }
        $c.EndConnect($iar); return $true
    } catch { return $false } finally { $c.Close() }
}

# 找出 DSH 宿主：端口占用者且命令行含 bin.js（DSH 的入口）
function Find-DshHost {
    $ports = @()
    if ($Port -gt 0) { $ports = @($Port) }
    else {
        if ($cfg -and $cfg.preferredPort) { $ports += [int]$cfg.preferredPort }
        if (Test-Path -LiteralPath $urlFile) {
            try {
                $u = (Get-Content -LiteralPath $urlFile -Raw -Encoding UTF8).Trim()
                if ($u -match ':(\d+)') { $ports += [int]$Matches[1] }
            } catch { }
        }
        $ports += @(3080, 3081, 3082, 8080)
    }
    foreach ($p in ($ports | Select-Object -Unique)) {
        if ($p -le 0) { continue }
        if (-not (Test-PortOpen -P $p)) { continue }
        try {
            $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $conn) { continue }
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($conn.OwningProcess)" -ErrorAction SilentlyContinue
            if ($proc -and $proc.CommandLine -match 'bin\.js') {
                return [PSCustomObject]@{ Pid = [int]$conn.OwningProcess; Port = $p }
            }
        } catch { }
    }
    return $null
}

# 优雅停止：向目标进程的控制台发 CTRL_C（在子进程里做，避免影响自己）
function Send-CtrlC {
    param([int]$TargetPid)
    $code = @'
param([int]$TargetPid)
Add-Type -Namespace W -Name K -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint dwProcessId);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
"@
[void][W.K]::FreeConsole()
if (-not [W.K]::AttachConsole([uint32]$TargetPid)) { exit 2 }
[void][W.K]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)   # 自己也收到 Ctrl+C，忽略掉
$ok = [W.K]::GenerateConsoleCtrlEvent(0, 0)
Start-Sleep -Milliseconds 300
[void][W.K]::FreeConsole()
if ($ok) { exit 0 } else { exit 1 }
'@
    $tmp = Join-Path $env:TEMP ("dsh-ctrlc-{0}.ps1" -f (Get-Random))
    try {
        Set-Content -LiteralPath $tmp -Value $code -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -TargetPid $TargetPid | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# ── 主流程 ──
$dshHost = Find-DshHost
if (-not $dshHost) {
    if ($ProbeOnly) { Write-Host "  running=false"; exit 0 }
    Write-Log "当前没有正在运行的 DSH（未找到监听中的宿主进程）" 'note'
    exit 0
}

if ($ProbeOnly) {
    Write-Host "  running=true pid=$($dshHost.Pid) port=$($dshHost.Port)"
    exit 0
}

Write-Log "准备停止 DSH（PID $($dshHost.Pid)，端口 $($dshHost.Port)）"

$stopped = $false
if (-not $Force) {
    $sent = Send-CtrlC -TargetPid $dshHost.Pid
    if ($sent) {
        Write-Log "已发送优雅退出信号（等同 Ctrl+C），等待它自己收尾…" 'note'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            Start-Sleep -Milliseconds 500
            if (-not (Get-Process -Id $dshHost.Pid -ErrorAction SilentlyContinue)) { $stopped = $true; break }
        }
        if ($stopped) { Write-Log "DSH 已优雅退出（会话数据已正常收尾，用时 $([int]$sw.Elapsed.TotalSeconds) 秒）" 'ok' }
        else { Write-Log "优雅退出超时（$TimeoutSec 秒）" 'warn' }
    } else {
        Write-Log "无法发送优雅退出信号（可能是权限或控制台限制）" 'warn'
    }
}

if (-not $stopped) {
    Write-Log "改为强制结束进程 $($dshHost.Pid)（本次为强制退出，极端情况下最后一条记录可能不完整）" 'warn'
    try { Stop-Process -Id $dshHost.Pid -Force -ErrorAction SilentlyContinue } catch { }
    $waited = 0
    while ($waited -lt 20) {
        Start-Sleep -Milliseconds 500
        $waited++
        if (-not (Get-Process -Id $dshHost.Pid -ErrorAction SilentlyContinue)) { $stopped = $true; break }
    }
}

# 等端口释放
$freed = $false
for ($i = 0; $i -lt 20; $i++) {
    if (-not (Test-PortOpen -P $dshHost.Port)) { $freed = $true; break }
    Start-Sleep -Milliseconds 300
}

if ($stopped) {
    Write-Log "DSH 已停止（端口 $($dshHost.Port) $(if ($freed) { '已释放' } else { '仍被占用，稍等即可' })）" 'ok'
    exit 0
} else {
    Write-Log "停止失败：进程 $($dshHost.Pid) 仍在运行，请用任务管理器确认" 'err'
    exit 1
}
