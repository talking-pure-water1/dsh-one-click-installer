# 验收 2：无 Node 分支 —— 模拟新机器，验证会走「待安装」路线（DryRun，不真装）
$Root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $Root 'install.ps1'

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps `
    -DryRun -NonInteractive -SimulateNoNode -SkipShortcut -NoStart 2>&1 | Out-String
$code = $LASTEXITCODE

$problems = @()
if ($code -ne 0) { $problems += "退出码 $code（应为 0）" }
if ($out -notmatch '未检测到 Node.js') { $problems += "未提示「未检测到 Node.js」" }
if ($out -notmatch '待安装\(DryRun\)') { $problems += "未给出待安装计划" }
if ($out -notmatch 'winget 或免安装版') { $problems += "未说明两条安装路线" }

if ($problems.Count -eq 0) {
    Write-Host "PASS 无 Node 分支：正确识别缺失并规划两条安装路线" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 无 Node 分支：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
