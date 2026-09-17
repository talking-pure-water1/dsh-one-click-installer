# 验收 11：自部署 —— 程序复制到安装目录，快捷方式指向安装目录（所以工具包可以删掉）
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $Root 'install.ps1'
$sandbox = Join-Path $Root '_verify_deploy'
$desktop = [Environment]::GetFolderPath('Desktop')
$scName = 'DSH部署测试'
$lnk = Join-Path $desktop "$scName.lnk"
$startPs = Join-Path $sandbox 'app\launcher\start-dsh.ps1'

function Get-MatchingShortcuts {
    $sh = New-Object -ComObject WScript.Shell
    $out = @()
    foreach ($d in @($desktop, (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.lnk -ErrorAction SilentlyContinue)) {
            try { if ("$($sh.CreateShortcut($f.FullName).Arguments)" -match 'start-dsh\.ps1') { $out += $f.FullName } } catch { }
        }
    }
    return $out
}

# 清理可能的残留
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }

$problems = @()
try {
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer,
              '-InstallRoot', $sandbox, '-SkipNode', '-SkipDsh', '-SkipDshHome', '-NoStart',
              '-NonInteractive', '-NoEnvChange', '-ShortcutName', $scName)
    $out = & powershell.exe @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { $problems += "安装退出码 $LASTEXITCODE" }

    # 1) 程序确实被复制到安装目录
    foreach ($rel in @('app\launcher\start-dsh.ps1', 'app\panel.ps1', 'app\shortcut.ps1', 'app\assets\dsh.ico')) {
        $p = Join-Path $sandbox $rel
        if (-not (Test-Path -LiteralPath $p)) { $problems += "缺少部署文件：$rel" }
    }

    # 2) 配置写在部署目录里，且 programRoot 指向部署目录（不是下载来的工具包）
    $cfgPath = Join-Path $sandbox 'app\launcher\config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        $problems += "部署目录缺少 config.json"
    } else {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($cfg.programRoot)" -ne (Join-Path $sandbox 'app')) { $problems += "programRoot 不对：$($cfg.programRoot)" }
        if ("$($cfg.installRoot)" -ne $sandbox) { $problems += "installRoot 不对：$($cfg.installRoot)" }
    }

    # 3) 快捷方式指向部署目录，而不是工具包目录（这才保证「删掉工具包还能用」）
    if (-not (Test-Path -LiteralPath $lnk)) {
        $problems += "没有创建快捷方式：$lnk"
    } else {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        if ("$($s.TargetPath)" -notmatch 'powershell') { $problems += "快捷方式目标不是 powershell：$($s.TargetPath)" }
        if ("$($s.Arguments)" -notmatch 'start-dsh\.ps1') { $problems += "快捷方式参数里没有启动脚本：$($s.Arguments)" }
        # 关键判据：参数必须指向「部署目录里的启动脚本」，而不是下载来的工具包里的那份
        $expectedScript = Join-Path $sandbox 'app\launcher\start-dsh.ps1'
        if ("$($s.Arguments)" -notmatch [regex]::Escape($expectedScript)) { $problems += "快捷方式参数没有指向部署目录：$($s.Arguments)" }
        $sourceScript = Join-Path $Root 'launcher\start-dsh.ps1'
        if ("$($s.Arguments)" -match [regex]::Escape($sourceScript)) { $problems += "快捷方式仍指向工具包内部（删掉工具包就废了）" }
        Write-Host "      快捷方式目标：$($s.TargetPath)" -ForegroundColor DarkGray
    }

    # 4) 再装一次不应产生第二个快捷方式（去重）
    $before = @(Get-MatchingShortcuts).Count
    $out2 = & powershell.exe @args 2>&1 | Out-String
    $after = @(Get-MatchingShortcuts).Count
    if ($after -gt 1) { $problems += "重复安装产生了 $after 个指向同一启动器的快捷方式（应只有 1 个）" }
    if ($out2 -notmatch '复制|已在安装目录|部署') { }
} finally {
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
    foreach ($f in (Get-MatchingShortcuts)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($problems.Count -eq 0) {
    Write-Host "PASS 自部署：程序已复制到安装目录、快捷方式指向安装目录、重复安装不产生多余图标" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 自部署：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
