# 验收 3：端口被别的程序占用 —— 应自动换端口，且不崩溃
$Root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $Root 'launcher\start-dsh.ps1'

# 找一个空闲端口，然后用「非 DSH」的假监听占住它
$port = 0
for ($p = 3099; $p -lt 3130; $p++) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $p); $c.Close() } catch { $c.Close(); $port = $p; break }
}
if ($port -eq 0) { Write-Host "SKIP 找不到可用于测试的空闲端口" -ForegroundColor Yellow; exit 0 }

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
$listener.Start()
try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps `
        -ProbeOnly -Port $port -InstallRoot $Root 2>&1 | Out-String
    $code = $LASTEXITCODE

    $problems = @()
    if ($code -ne 0) { $problems += "退出码 $code（应为 0）" }
    if ($out -notmatch "被其它程序占用") { $problems += "未识别出端口被占用" }
    if ($out -notmatch 'decision=start port=(\d+)') {
        $problems += "未给出换端口后的启动决策"
    } else {
        $chosen = [int]$Matches[1]
        if ($chosen -eq $port) { $problems += "竟然仍选用被占用的端口 $port" }
        $c2 = New-Object System.Net.Sockets.TcpClient
        try { $c2.Connect('127.0.0.1', $chosen); $c2.Close(); $problems += "选中的端口 $chosen 实际已被占用" } catch { $c2.Close() }
    }

    if ($problems.Count -eq 0) {
        Write-Host "PASS 端口占用：已自动改选其它空闲端口（测试占用端口 $port）" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "FAIL 端口占用：" -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
        exit 1
    }
} finally {
    $listener.Stop()
}
