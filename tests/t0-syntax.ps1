# 验收 0：脚本语法 + 关键文件完整性（防止中文/引号类低级事故）
$Root = Split-Path -Parent $PSScriptRoot
$problems = @()

# 1) 所有 .ps1 必须能通过 AST 解析（全角引号、缺括号这类问题会在此暴露）
$scripts = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1
foreach ($s in $scripts) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$errs)
    if (@($errs).Count -gt 0) {
        $problems += "语法错误：$($s.Name) → $($errs[0].Message)"
    }
}

# 2) 关键文件必须在位
$required = @(
    '安装DSH（初次使用点击这里就好啦⭐️）.cmd', '修复.cmd', '卸载.cmd', '改名换图标.cmd', '打包发布.cmd', '更新DSH.cmd', '启动面板（第二次及以后使用点击这个就好啦❀）.cmd',
    'install.ps1', 'shortcut.ps1', 'uninstall.ps1', 'pack-release.ps1', 'update-dsh.ps1', 'panel.ps1',
    'launcher\start-dsh.ps1', 'launcher\stop-dsh.ps1', 'launcher\dsh-tray.ps1', 'assets\dsh.ico'
)
foreach ($r in $required) {
    $p = Join-Path $Root $r
    if (-not (Test-Path -LiteralPath $p)) { $problems += "缺少文件：$r" }
}

# 3) 编码检查：.ps1 必须带 UTF-8 BOM（否则中文在 PowerShell 5.1 下乱码/报错）
foreach ($s in $scripts) {
    $bytes = [System.IO.File]::ReadAllBytes($s.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        $problems += "缺少 UTF-8 BOM：$($s.Name)"
    }
}

# 4) .cmd 入口必须是纯 ASCII（编码安全），且包含 Bypass 与免暂停开关
foreach ($c in @('安装DSH（初次使用点击这里就好啦⭐️）.cmd', '修复.cmd', '卸载.cmd', '改名换图标.cmd', '打包发布.cmd', '更新DSH.cmd', '启动面板（第二次及以后使用点击这个就好啦❀）.cmd')) {
    $p = Join-Path $Root $c
    if (Test-Path -LiteralPath $p) {
        $text = [System.IO.File]::ReadAllText($p)
        if ($text -match '[^\x00-\x7F]') { $problems += "$c 含非 ASCII 字符（cmd 编码风险）" }
        if ($text -notmatch 'ExecutionPolicy Bypass') { $problems += "$c 未使用 Bypass" }
        if ($text -notmatch 'DSH_NO_PAUSE') { $problems += "$c 缺少免暂停开关" }
    }
}

if ($problems.Count -eq 0) {
    Write-Host "PASS 语法与完整性：$($scripts.Count) 个脚本语法通过、BOM 齐全、关键文件在位" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 语法与完整性：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
