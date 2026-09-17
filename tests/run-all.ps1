# 一键跑完所有验收项并生成报告
# 用法： run-all.ps1            跑全部离线项（默认，快）
#        run-all.ps1 -Network   额外跑「在线装 Node」（真下载约 30MB）
param([switch]$Network)

$Root = Split-Path -Parent $PSScriptRoot
$tests = @(
    @{ Name = '0. 脚本语法与文件完整性'; File = 't0-syntax.ps1' },
    @{ Name = '1. 幂等性（两次 DryRun 不写盘）'; File = 't1-idempotent.ps1' },
    @{ Name = '2. 无 Node 分支（规划两条安装路线）'; File = 't2-no-node.ps1' },
    @{ Name = '3. 端口被占用（自动换端口）'; File = 't3-port-busy.ps1' },
    @{ Name = '4. 已有实例（复用不重启）'; File = 't4-existing-instance.ps1' },
    @{ Name = '5. 快捷方式（真实桌面/图标/目标）'; File = 't5-desktop-path.ps1' },
    @{ Name = '6. 执行策略受限（.cmd Bypass 生效）'; File = 't6-restricted-policy.ps1' },
    @{ Name = '8. 一键更新（DryRun 不动作）'; File = 't8-update-dryrun.ps1' },
    @{ Name = '9. 应用模式（浏览器探测/开关）'; File = 't9-appmode.ps1' },
    @{ Name = '10. 图形控制面板（接口/鉴权）'; File = 't10-panel.ps1' },
    @{ Name = '11. 自部署（工具包可删）'; File = 't11-deploy.ps1' },
    @{ Name = '12. 打包质量（精简/维护版）'; File = 't12-package.ps1' },
    @{ Name = '13. 托盘与安全退出'; File = 't13-tray-graceful.ps1' }
)
if ($Network) {
    $tests += @{ Name = '7. 在线装 Node（真下载+解压，隔离目录）'; File = 't7-online-node.ps1' }
}

Write-Host ""
Write-Host "  ═════════ DSH 一键安装器 · 验收测试 ═════════" -ForegroundColor Cyan
Write-Host "  安装目录：$Root"
Write-Host ""

$results = @()
foreach ($t in $tests) {
    $path = Join-Path $PSScriptRoot $t.File
    Write-Host "  ▶ $($t.Name)" -ForegroundColor White
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sw.Stop()

    # 判定以退出码为准：只有成功退出时才可能算「跳过」。
    # 曾经只要输出里出现 SKIP 就把失败的项也算成跳过（诊断信息里带出 -SkipNode 之类字样就会误判）。
    $verdict = 'FAIL'
    if ($code -eq 0) {
        $verdict = if ($out -match '(?m)^\s*SKIP') { 'SKIP' } else { 'PASS' }
    }
    # 摘要只认「行首就是判定词」的那一行，避免诊断信息里的字样被当成判定
    $firstLine = ($out -split "`r?`n" | Where-Object { $_ -match '^\s*(PASS|FAIL|SKIP)[ 　]' } | Select-Object -First 1)
    if (-not $firstLine) { $firstLine = ($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1) }

    $color = switch ($verdict) { 'PASS' { 'Green' } 'SKIP' { 'Yellow' } default { 'Red' } }
    Write-Host "    [$verdict] $($firstLine.Trim())  ($([int]$sw.Elapsed.TotalSeconds)s)" -ForegroundColor $color
    if ($verdict -eq 'FAIL') { Write-Host $out -ForegroundColor DarkRed }

    $results += [PSCustomObject]@{
        项目 = $t.Name; 结果 = $verdict; 耗时秒 = [int]$sw.Elapsed.TotalSeconds; 摘要 = "$($firstLine)".Trim()
    }
}

Write-Host ""
Write-Host "  ───────────── 结果汇总 ─────────────" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$pass = @($results | Where-Object { $_.结果 -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.结果 -eq 'FAIL' }).Count
$skip = @($results | Where-Object { $_.结果 -eq 'SKIP' }).Count
Write-Host "  通过 $pass 项，失败 $fail 项，跳过 $skip 项" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })

# 写报告
$report = Join-Path $Root 'tests\测试报告.md'
$md = New-Object System.Collections.ArrayList
[void]$md.Add("# DSH 一键安装器 · 验收测试报告")
[void]$md.Add("")
[void]$md.Add("- 测试时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$md.Add("- 安装目录：``$Root``")
[void]$md.Add("- 环境：Node $(node -v)，PowerShell $($PSVersionTable.PSVersion)")
[void]$md.Add("")
[void]$md.Add("| 验收项 | 结果 | 耗时 | 摘要 |")
[void]$md.Add("|---|---|---|---|")
foreach ($r in $results) {
    [void]$md.Add("| $($r.项目) | $($r.结果) | $($r.耗时秒)s | $($r.摘要) |")
}
[void]$md.Add("")
[void]$md.Add("**合计：通过 $pass，失败 $fail，跳过 $skip。**")
$md -join "`r`n" | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "  报告已写入：$report" -ForegroundColor DarkGray
Write-Host ""

if ($fail -gt 0) { exit 1 }
exit 0
