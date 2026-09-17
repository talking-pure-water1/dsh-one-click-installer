# 验收 5：快捷方式落点与属性 —— 必须在「真实桌面」（兼容 360/OneDrive 迁移）并可回读
$Root = Split-Path -Parent $PSScriptRoot
$sc = Join-Path $Root 'shortcut.ps1'
$icon = Join-Path $Root 'assets\dsh.ico'
$name = 'DSH测试快捷方式_t5'

$desk = [Environment]::GetFolderPath('Desktop')
$naive = Join-Path $env:USERPROFILE 'Desktop'
$lnk = Join-Path $desk "$name.lnk"

if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sc `
    -LauncherRoot $Root -Name $name -IconPath $icon -Force -NonInteractive 2>&1 | Out-String
$code = $LASTEXITCODE

$problems = @()
if ($code -ne 0) { $problems += "退出码 $code（应为 0）" }
if (-not (Test-Path -LiteralPath $lnk)) { $problems += "快捷方式未出现在真实桌面：$lnk" }
if (-not (Test-Path -LiteralPath $desk)) { $problems += "真实桌面目录本身不存在：$desk" }

if (Test-Path -LiteralPath $lnk) {
    $sh = New-Object -ComObject WScript.Shell
    $v = $sh.CreateShortcut($lnk)
    # 现在快捷方式直接调用 powershell 隐藏运行 start-dsh.ps1（不再经过 wscript + .vbs）
    if ("$($v.TargetPath)" -notmatch 'powershell') { $problems += "目标不是 powershell：$($v.TargetPath)" }
    if ("$($v.Arguments)" -notmatch 'start-dsh\.ps1') { $problems += "参数里没有启动脚本：$($v.Arguments)" }
    if ("$($v.Arguments)" -match '\.vbs') { $problems += "参数里仍有 .vbs（旧实现残留）：$($v.Arguments)" }
    if ($v.IconLocation -notmatch 'dsh\.ico') { $problems += "图标未生效：$($v.IconLocation)" }
    if ($v.WorkingDirectory -ne $Root) { $problems += "工作目录不符：$($v.WorkingDirectory)" }
    Remove-Item -LiteralPath $lnk -Force   # 清理测试产物
}

if ($desk -ne $naive) {
    Write-Host "       （本机桌面被迁移：真实=$desk ；%USERPROFILE%\Desktop=$naive ）" -ForegroundColor DarkGray
}

if ($problems.Count -eq 0) {
    Write-Host "PASS 快捷方式：落点正确、目标/图标/工作目录回读一致" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 快捷方式：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    # 失败时把子进程输出与运行环境一并打印出来 —— 否则原因会被吞掉，CI 上无从排查
    $sid = try { (Get-Process -Id $PID).SessionId } catch { '?' }
    $cp = [System.Text.Encoding]::Default.CodePage
    Write-Host "       [环境] 会话=$sid 交互式=$([Environment]::UserInteractive) 代码页=$cp 桌面存在=$(Test-Path -LiteralPath $desk) 用户=$env:USERNAME" -ForegroundColor DarkGray
    # 对照实验：换纯 ASCII 名字再建一次。
    # 能建 => 是「中文名 + 系统 ANSI 代码页」的问题；也建不了 => 是整机/会话不支持 .lnk。
    $asciiName = 'DSH-ASCII-probe'
    $asciiLnk = Join-Path $desk "$asciiName.lnk"
    if (Test-Path -LiteralPath $asciiLnk) { Remove-Item -LiteralPath $asciiLnk -Force }
    $asciiOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sc `
        -LauncherRoot $Root -Name $asciiName -IconPath $icon -Force -NonInteractive 2>&1 | Out-String
    $asciiCode = $LASTEXITCODE
    $asciiExists = Test-Path -LiteralPath $asciiLnk
    if ($asciiExists) { Remove-Item -LiteralPath $asciiLnk -Force }
    Write-Host "       [对照] 纯 ASCII 名字：退出码=$asciiCode，快捷方式$(if ($asciiExists) { '生成成功' } else { '未生成' })" -ForegroundColor DarkGray
    if ($asciiOut -and -not $asciiExists) {
        $asciiOut.Trim() -split "`r?`n" | Select-Object -First 10 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    }
    if ($out) {
        Write-Host "       [shortcut.ps1 输出]" -ForegroundColor DarkGray
        $out.Trim() -split "`r?`n" | Select-Object -First 30 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "       [shortcut.ps1 没有任何输出]" -ForegroundColor DarkGray
    }
    exit 1
}
