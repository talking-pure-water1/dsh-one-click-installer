# 验收 6：执行策略受限场景 —— 直接跑 .ps1 应被拦，走 .cmd 应成功（Bypass 生效）
$Root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $Root 'install.ps1'
$cmd = Join-Path $Root '安装DSH（初次使用点击这里就好啦⭐️）.cmd'
$env:DSH_NO_PAUSE = '1'

# a) 受策略限制直接运行 .ps1：预期失败
$a = & cmd.exe /c "powershell.exe -NoProfile -ExecutionPolicy Restricted -File `"$ps`" -DryRun -NonInteractive -SkipShortcut -NoStart" 2>&1 | Out-String
$codeA = $LASTEXITCODE
$blocked = ($codeA -ne 0) -or ($a -match 'cannot be loaded|禁止运行|running scripts is disabled|UnauthorizedAccess')

# b) 走 .cmd（内部使用 Bypass）：预期成功
$b = & cmd.exe /c "`"$cmd`" -DryRun -NonInteractive -SkipShortcut -NoStart" 2>&1 | Out-String
$codeB = $LASTEXITCODE

$problems = @()
if (-not $blocked) { $problems += "直接运行 .ps1 竟然没被策略拦下（本项测试前提不成立，请检查执行策略）" }
if ($codeB -ne 0) { $problems += ".cmd 入口失败（退出码 $codeB），Bypass 未生效" }
if ($b -notmatch 'DSH 一键安装器') { $problems += ".cmd 入口没有正常输出安装器标题" }

if ($problems.Count -eq 0) {
    Write-Host "PASS 执行策略：.ps1 被拦（符合预期），.cmd 入口正常放行" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 执行策略：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
