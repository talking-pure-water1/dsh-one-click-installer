# 验收 13：托盘与安全退出 —— 菜单齐全、优雅停止真的生效（用假宿主测试，不动真实 DSH）
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$tray = Join-Path $Root 'launcher\dsh-tray.ps1'
$stop = Join-Path $Root 'launcher\stop-dsh.ps1'
$sandbox = Join-Path $Root '_verify_tray'
$marker = Join-Path $sandbox 'graceful-marker.txt'
$dummy = Join-Path $sandbox 'dummy-bin.js'   # 文件名含 bin.js，便于被当成 DSH 宿主识别

$problems = @()
foreach ($d in @($sandbox)) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

# 假宿主：占 3081 端口，收到 SIGINT 就写标记再退出
$js = @'
const fs = require('fs');
const marker = process.argv[2];
function bye(sig) { try { fs.writeFileSync(marker, 'graceful:' + sig, 'utf8'); } catch (e) {} process.exit(0); }
process.on('SIGINT', () => bye('SIGINT'));
process.on('SIGBREAK', () => bye('SIGBREAK'));
process.on('SIGTERM', () => bye('SIGTERM'));
const http = require('http');
http.createServer((req, res) => res.end('ok')).listen(3081, '127.0.0.1');
setInterval(() => {}, 1000);
'@
Set-Content -LiteralPath $dummy -Value $js -Encoding UTF8

$proc = $null
try {
    # 1) 托盘脚本自检：菜单项必须齐（尤其「安全退出」）
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tray -SelfTest 2>&1 | Out-String
    foreach ($need in @('打开 DSH 界面', '重启 DSH', '安全退出 DSH（推荐）', '更新 DSH', '打开控制面板')) {
        if ($out -notmatch [regex]::Escape($need)) { $problems += "托盘菜单缺少：$need" }
    }
    if ($out -notmatch 'stopPs=True') { $problems += "托盘脚本找不到 stop-dsh.ps1" }
    if ($out -notmatch 'updatePs=True') { $problems += "托盘脚本找不到 update-dsh.ps1（删掉工具包后就没法更新了）" }
    if ($out -notmatch 'panelPs=True') { $problems += "托盘脚本找不到 panel.ps1" }

    # 2) stop-dsh.ps1 探测（此时应报没有运行中的 DSH 于该端口）
    $probe = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stop -Port 3081 -ProbeOnly 2>&1 | Out-String
    if ($probe -notmatch 'running=false') { $problems += "空端口探测结果异常：$($probe.Trim())" }

    # 3) 启动假宿主，然后让 stop-dsh.ps1 优雅停止它
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "node `"$dummy`" `"$marker`"") -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    $conn = Get-NetTCPConnection -LocalPort 3081 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) {
        $problems += "假宿主没有监听 3081，无法继续测试"
    } else {
        $probe2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stop -Port 3081 -ProbeOnly 2>&1 | Out-String
        if ($probe2 -notmatch 'running=true') { $problems += "应识别到运行中的假宿主：$($probe2.Trim())" }

        $stopOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stop -Port 3081 -TimeoutSec 15 2>&1 | Out-String
        $stopCode = $LASTEXITCODE
        if ($stopCode -ne 0) { $problems += "安全退出返回码 $stopCode" }
        if ($stopOut -notmatch '优雅退出') { $problems += "没有走优雅退出（输出：$($stopOut.Trim())）" }
        if (Test-Path -LiteralPath $marker) {
            $m = (Get-Content -LiteralPath $marker -Raw).Trim()
            if ($m -notmatch 'SIGINT|SIGBREAK') { $problems += "假宿主收到的信号异常：$m" }
        } else {
            $problems += "假宿主没有写出优雅退出标记（说明是强杀的）"
        }
        $stillThere = Get-NetTCPConnection -LocalPort 3081 -State Listen -ErrorAction SilentlyContinue
        if ($stillThere) { $problems += "停止后 3081 仍被占用" }
    }
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Get-Process node -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.StartTime -gt (Get-Date).AddMinutes(-5) } |
        ForEach-Object { try { $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine; if ($cl -match 'dummy-bin\.js') { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } } catch { } }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($problems.Count -eq 0) {
    Write-Host "PASS 托盘与安全退出：菜单齐全，优雅停止真实生效（假宿主收到 SIGINT 后自行退出，未被强杀）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 托盘与安全退出：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
