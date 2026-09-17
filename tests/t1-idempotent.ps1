# 验收 1：幂等性 —— 连续两次 DryRun 运行，均成功且不写任何文件
$Root = Split-Path -Parent $PSScriptRoot
$cmd = Join-Path $Root '安装DSH（初次使用点击这里就好啦⭐️）.cmd'
$env:DSH_NO_PAUSE = '1'

$defaultRoot = 'D:\dsh-launcher'
$existedBefore = Test-Path -LiteralPath $defaultRoot

$out1 = & cmd.exe /c "`"$cmd`" -DryRun -NonInteractive -SkipShortcut -NoStart" 2>&1 | Out-String
$code1 = $LASTEXITCODE
$out2 = & cmd.exe /c "`"$cmd`" -DryRun -NonInteractive -SkipShortcut -NoStart" 2>&1 | Out-String
$code2 = $LASTEXITCODE

$problems = @()
if ($code1 -ne 0) { $problems += "第一次运行退出码 $code1（应为 0）" }
if ($code2 -ne 0) { $problems += "第二次运行退出码 $code2（应为 0）" }
if ($out1 -notmatch '已安装 Node') { $problems += "第一次输出未报告 Node 已就绪" }
if ($out2 -notmatch '已安装 Node') { $problems += "第二次输出未报告 Node 已就绪" }
if ($out1 -notmatch 'dsh 命令已存在|将执行 npm i -g') { $problems += "第一次输出未报告 dsh 检测结果" }
if (-not $existedBefore -and (Test-Path -LiteralPath $defaultRoot)) { $problems += "DryRun 竟然创建了目录 $defaultRoot（不应写盘）" }

if ($problems.Count -eq 0) {
    Write-Host "PASS 幂等性：两次 DryRun 均成功，且未写盘" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 幂等性：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
