# 验收 7：在线装 Node（真下载 + 真解压，隔离目录，不动系统已有 Node）
# 说明：本项需要联网，默认不在 run-all 里跑；用 run-all.ps1 -Network 启用。
$Root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $Root 'install.ps1'
$sandbox = Join-Path $Root '_verify_node'

# 记录测试前的用户 PATH，稍后校验「测试模式没有改环境」
$pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')

if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }

Write-Host "      正在从镜像下载 Node（约 30MB），可能需要 1~3 分钟…" -ForegroundColor DarkGray
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps `
    -InstallRoot $sandbox -SimulateNoNode -NodeMethod portable -NoEnvChange `
    -SkipDsh -SkipShortcut -SkipDshHome -NoStart -NonInteractive 2>&1 | Out-String
$code = $LASTEXITCODE
$sw.Stop()

$pathAfter = [Environment]::GetEnvironmentVariable('Path', 'User')
$nodeExe = Get-ChildItem -LiteralPath $sandbox -Recurse -Filter node.exe -ErrorAction SilentlyContinue | Select-Object -First 1

$problems = @()
if ($code -ne 0) { $problems += "退出码 $code（应为 0）" }
if ($out -notmatch '下载完成') { $problems += "没有看到下载完成日志" }
if ($out -notmatch '解压校验') { $problems += "没有看到解压校验日志" }
if (-not $nodeExe) { $problems += "解压目录里找不到 node.exe" }
else {
    $ver = (& $nodeExe.FullName -v) 2>$null
    if ("$ver" -notmatch '^v(2[2-9]|[3-9]\d)\.') { $problems += "解压出的 Node 版本异常：$ver" }
    else { Write-Host "      实测解压版本：$ver（$([math]::Round($nodeExe.Length/1MB,1)) MB 的 node.exe）" -ForegroundColor DarkGray }
}
if ($out -notmatch '跳过写入用户 PATH') { $problems += "测试模式未能拦住 PATH 写入（有污染系统环境的风险）" }
if ($pathBefore -ne $pathAfter) { $problems += "用户 PATH 被改动了（测试模式应当拦截）" }

# 清理隔离目录
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }

if ($problems.Count -eq 0) {
    Write-Host "PASS 在线装 Node：镜像下载→解压→校验通过，且未污染系统环境（用时 $([int]$sw.Elapsed.TotalSeconds)s）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 在线装 Node：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    if ($out -match '免安装版 Node 部署失败.*') { ($out -split "`r?`n" | Where-Object { $_ -match '部署失败' }) | ForEach-Object { Write-Host "       $($_.Trim())" -ForegroundColor DarkRed } }
    exit 1
}
