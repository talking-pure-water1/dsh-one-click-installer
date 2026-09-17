# 验收 8：一键更新（DryRun）—— 必须能读到当前版本、给出计划，且不真的动 npm
$Root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $Root 'update-dsh.ps1'

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps -DryRun -NoRestart -NonInteractive 2>&1 | Out-String
$code = $LASTEXITCODE

$problems = @()
if ($code -ne 0) { $problems += "退出码 $code（应为 0）" }
if ($out -notmatch 'DSH 更新工具') { $problems += "没有输出更新工具标题" }
if ($out -notmatch '当前版本|当前未检测到') { $problems += "没有报告当前版本" }
if ($out -notmatch 'DryRun') { $problems += "DryRun 模式下没有给出计划" }
if ($out -match '更新完成：') { $problems += "DryRun 竟然真的执行了更新" }
if ($out -match 'npm: added') { $problems += "DryRun 竟然调用了 npm 安装" }

$verLine = ($out -split "`r?`n" | Where-Object { $_ -match '当前版本' } | Select-Object -First 1)

if ($problems.Count -eq 0) {
    Write-Host "PASS 一键更新(DryRun)：$($verLine.Trim())，仅给出计划未动 npm" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 一键更新：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
