# 验收 4：已有 DSH 实例在跑 —— 应复用而不是重复启动（避免 EADDRINUSE）
$Root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $Root 'launcher\start-dsh.ps1'

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps -ProbeOnly -InstallRoot $Root 2>&1 | Out-String
$code = $LASTEXITCODE

if ($out -match 'decision=reuse url=(\S+)') {
    $url = $Matches[1]
    Write-Host "PASS 已有实例：正确识别为复用（$url），不会重复启动" -ForegroundColor Green
    exit 0
}
if ($out -match 'decision=start port=3080') {
    Write-Host "SKIP 当前没有正在运行的 DSH 实例，本项无法验证（其余项不受影响）" -ForegroundColor Yellow
    exit 0
}
Write-Host "FAIL 已有实例：决策输出异常（退出码 $code）" -ForegroundColor Red
Write-Host $out
exit 1
