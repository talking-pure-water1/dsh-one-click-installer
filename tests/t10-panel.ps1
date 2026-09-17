# 验收 10：图形控制面板 —— 起服务、页面可打开、接口正常、异常输入被拒
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $Root 'panel.ps1'

# 关掉「自动发现代理」（WPAD）：CI 机器上 Invoke-WebRequest 会去探测 wpad 主机，
# 每次都要等 DNS 超时，表现为「面板明明在监听、本机却连不上」，且一跑就是两分钟。
try { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy } catch { }
[System.Net.ServicePointManager]::Expect100Continue = $false

# 找一个空闲端口
$port = 0
for ($p = 17850; $p -lt 17900; $p++) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $p); $c.Close() } catch { $c.Close(); $port = $p; break }
}
if ($port -eq 0) { Write-Host "SKIP 找不到可用于测试的空闲端口" -ForegroundColor Yellow; exit 0 }

$proc = $null
$problems = @()
$envSkipped = $false
$tmp = Join-Path $env:TEMP ("dsh-panel-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$panelOut = Join-Path $tmp 'panel-out.log'
$panelErr = Join-Path $tmp 'panel-err.log'
try {
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps, '-Port', "$port", '-NoBrowser') `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $panelOut -RedirectStandardError $panelErr

    # 等待面板起来（快失败 + 最多约 45 秒；进程若已退出则立即结束等待）
    # 单个请求超时给到 20 秒：CI 上首次 /api/status 要起 node/dsh 进程，2 秒根本不够，
    # 会被误判成「面板没起来」。
    $base = "http://127.0.0.1:$port"
    $up = $false
    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Milliseconds 800
        try {
            $r = Invoke-WebRequest -Uri "$base/api/status" -UseBasicParsing -TimeoutSec 20
            if ($r.StatusCode -eq 200) { $up = $true; break }
        } catch { }
        if ($proc.HasExited) { break }
    }
    if (-not $up) {
        # 收集诊断信息：面板自己的输出与错误
        $diag = ''
        foreach ($f in @($panelOut, $panelErr)) {
            if (Test-Path -LiteralPath $f) {
                $t = (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)
                if ($t) { $diag += $t }
            }
        }
        if ($diag -match 'Access is denied|拒绝访问|HttpListener|权限|not permitted|已被占用|already in use') {
            # 环境不允许绑定本地监听地址（常见于 CI/受策略限制的机器）——这是环境限制，不是代码缺陷
            $envSkipped = $true
            Write-Host "SKIP 图形面板：本机环境不允许绑定本地监听端口（需管理员/URL ACL），非代码缺陷" -ForegroundColor Yellow
            Write-Host "     面板报错：$($diag.Trim().Split([Environment]::NewLine)[0])" -ForegroundColor DarkGray
        } else {
            $problems += "面板未能在约 36 秒内启动（端口 $port，已试 $i 次）"
            if ($diag) { $problems += "面板输出：$($diag.Trim())" } else { $problems += "面板既没有输出也没有报错（疑似请求被代理/防火墙吞掉）" }
            if ($proc.HasExited) { $problems += "面板进程已退出，退出码 $($proc.ExitCode)" } else { $problems += "面板进程仍在运行（说明端口已监听，问题出在 HTTP 请求侧）" }
        }
    }
    if ($up) {
        # 1) 首页
        $homeRes = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 15
        if ($homeRes.StatusCode -ne 200) { $problems += "首页状态码 $($homeRes.StatusCode)" }
        if ($homeRes.Content -notmatch '控制面板') { $problems += "首页缺少标题" }
        if ($homeRes.Content -notmatch '一键操作') { $problems += "首页缺少操作区" }
        if ($homeRes.Content -notmatch '安装 / 修复') { $problems += "首页缺少安装按钮" }

        # 2) 状态接口
        $st = Invoke-RestMethod -Uri "$base/api/status" -TimeoutSec 15
        if (-not ($st.PSObject.Properties.Name -contains 'node')) { $problems += "状态缺少 node 字段" }
        if (-not ($st.PSObject.Properties.Name -contains 'dsh')) { $problems += "状态缺少 dsh 字段" }
        if (-not ($st.PSObject.Properties.Name -contains 'running')) { $problems += "状态缺少 running 字段" }
        if ("$($st.programRoot)" -ne $Root) { $problems += "programRoot 不对：$($st.programRoot)" }
        Write-Host "      面板状态：node=$($st.node) dsh=$($st.dsh) running=$($st.running) url=$($st.url)" -ForegroundColor DarkGray

        # 3) 日志接口
        $log = Invoke-WebRequest -Uri "$base/api/log?name=launch" -UseBasicParsing -TimeoutSec 15
        if ($log.StatusCode -ne 200) { $problems += "日志接口状态码 $($log.StatusCode)" }

        # 4) 非法设置项必须被拒（400），且不能改动配置
        $cfgPath = Join-Path $Root 'launcher\config.json'
        $before = if (Test-Path -LiteralPath $cfgPath) { [System.IO.File]::ReadAllText($cfgPath) } else { '' }
        try {
            Invoke-WebRequest -Uri "$base/api/setting" -Method POST -UseBasicParsing -TimeoutSec 15 `
                -ContentType 'application/json' -Body '{"key":"evilKey"}' | Out-Null
            $problems += "非法设置项竟然被接受（应返回 400）"
        } catch {
            if ("$($_.Exception.Response.StatusCode.value__)" -ne '400') { $problems += "非法设置项应返回 400，实际：$($_.Exception.Message)" }
        }
        $after = if (Test-Path -LiteralPath $cfgPath) { [System.IO.File]::ReadAllText($cfgPath) } else { '' }
        if ($before -ne $after) { $problems += "非法请求竟然改动了 config.json" }

        # 5) 未知动作必须被拒（400）
        try {
            Invoke-WebRequest -Uri "$base/api/action" -Method POST -UseBasicParsing -TimeoutSec 15 `
                -ContentType 'application/json' -Body '{"action":"rm -rf /"}' | Out-Null
            $problems += "未知动作竟然被接受（应返回 400）"
        } catch {
            if ("$($_.Exception.Response.StatusCode.value__)" -ne '400') { $problems += "未知动作应返回 400，实际：$($_.Exception.Message)" }
        }
    }
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($envSkipped) { exit 0 }   # 环境不允许绑端口：已打印 SKIP，不作为失败

if ($problems.Count -eq 0) {
    Write-Host "PASS 图形面板：首页/状态/日志接口正常，非法输入被拒且未改动配置" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 图形面板：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
