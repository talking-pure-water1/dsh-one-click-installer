# 验收 5：快捷方式落点与属性 —— 必须在「真实桌面」（兼容 360/OneDrive 迁移）并可回读
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lnk-verify.ps1')
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
    # 主校验：直接解析 .lnk 内容（与系统代码页无关，中文名也照样能验）
    $raw = Get-LnkRawText -Path $lnk
    if (-not (Test-LnkContains $raw 'powershell.exe')) { $problems += "目标不是 powershell（.lnk 内容里找不到 powershell.exe）" }
    if (-not (Test-LnkContains $raw 'start-dsh.ps1')) { $problems += "参数里没有启动脚本（.lnk 内容里找不到 start-dsh.ps1）" }
    if (Test-LnkContains $raw '.vbs') { $problems += "参数里仍有 .vbs（旧实现残留）" }
    if (-not (Test-LnkContains $raw 'dsh.ico')) { $problems += "图标未生效（.lnk 内容里找不到 dsh.ico）" }
    if (-not (Test-LnkContains $raw $Root)) { $problems += "参数里没有安装目录（.lnk 内容里找不到 $Root）" }
    if ($raw.Size -lt 500) { $problems += "快捷方式文件过小（$($raw.Size) 字节，疑似空壳）" }

    # 附加校验：系统 ANSI 代码页能表示这个路径时，再用 WScript.Shell 回读一遍
    # （最接近用户实际看到的东西；中文系统上是能跑的，不会白白丢掉这层覆盖）
    $ansiEnc = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
    $comReadable = ($ansiEnc.GetString($ansiEnc.GetBytes($lnk)) -eq $lnk)
    if ($comReadable) {
        $sh = New-Object -ComObject WScript.Shell
        $v = $sh.CreateShortcut($lnk)
        if ("$($v.TargetPath)" -notmatch 'powershell') { $problems += "COM 回读目标不是 powershell：$($v.TargetPath)" }
        if ("$($v.Arguments)" -notmatch 'start-dsh\.ps1') { $problems += "COM 回读参数里没有启动脚本" }
        if ($v.IconLocation -notmatch 'dsh\.ico') { $problems += "COM 回读图标未生效：$($v.IconLocation)" }
        if ($v.WorkingDirectory -ne $Root) { $problems += "COM 回读工作目录不符：$($v.WorkingDirectory)" }
    } else {
        Write-Host "       （本机代码页表示不了这个路径，跳过 WScript.Shell 回读：COM 根本打不开这种名字）" -ForegroundColor DarkGray
    }
    Remove-Item -LiteralPath $lnk -Force   # 清理测试产物
}

if ($desk -ne $naive) {
    Write-Host "       （本机桌面被迁移：真实=$desk ；%USERPROFILE%\Desktop=$naive ）" -ForegroundColor DarkGray
}

if ($problems.Count -eq 0) {
    Write-Host "PASS 快捷方式：落点正确，目标/参数/图标/安装目录校验一致" -ForegroundColor Green
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
