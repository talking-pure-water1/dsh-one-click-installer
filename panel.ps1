<#
  面板.ps1 —— DSH 图形控制面板（本地小网页，零依赖）

  为什么用 PowerShell 自带 HttpListener 而不是 Node：
    控制面板要在"Node 还没装"的时候就能打开，否则就没法点那个"一键安装"按钮了。

  功能：状态总览（Node/dsh/服务/路径）、按钮式操作（安装修复/启动/更新/改名换图标/卸载）、
        日志查看、窗口与关窗行为的开关。

  安全：只监听 127.0.0.1（本机），不对外网开放；端口自动选空闲值。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File 面板.ps1            # 正常使用
    ... -File 面板.ps1 -Port 17801 -NoBrowser                              # 指定端口/不开浏览器（测试用）
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot                      # 程序目录（工具包根）
$launcherDir = Join-Path $root 'launcher'
$cfgFile = Join-Path $launcherDir 'config.json'
$panelLog = Join-Path $launcherDir 'panel.log'

function Write-PanelLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $launcherDir)) { New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null }
        Add-Content -LiteralPath $panelLog -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -Encoding UTF8
    } catch { }
}

function Test-PortFree {
    param([int]$P)
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $P); $c.Close(); return $false } catch { $c.Close(); return $true }
}

# ── 选端口 ──
if ($Port -le 0) {
    $Port = 17800
    while (-not (Test-PortFree -P $Port) -and $Port -lt 17900) { $Port++ }
}
if (-not (Test-PortFree -P $Port)) {
    Write-Host "  [×] 找不到空闲端口（17800-17900 都被占用）" -ForegroundColor Red
    exit 1
}

# ── 读取配置与状态 ──
function Get-Config {
    if (Test-Path -LiteralPath $cfgFile) {
        try { return (Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Save-ConfigValue {
    param([string]$Key, $Value)
    $cfg = Get-Config
    if (-not $cfg) { return $false }
    $obj = @{}
    foreach ($p in $cfg.PSObject.Properties) { $obj[$p.Name] = $p.Value }
    $obj[$Key] = $Value
    try {
        ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfgFile -Encoding UTF8
        return $true
    } catch { return $false }
}

function Get-NodeVersion {
    $g = Get-Command node -ErrorAction SilentlyContinue
    if (-not $g) { return '' }
    try { $v = (& $g.Source -v) 2>$null; return "$v".Trim() } catch { return '' }
}

function Get-DshCmd {
    $cfg = Get-Config
    if ($cfg -and $cfg.dshCommand -and (Test-Path -LiteralPath $cfg.dshCommand)) { return "$($cfg.dshCommand)" }
    # 先走 PATH（快）；只有找不到时才去问 npm ——「npm config get prefix」要拉起一个 npm 进程，很慢
    $g = Get-Command dsh.cmd -ErrorAction SilentlyContinue
    if ($g -and $g.Source) { return "$($g.Source)" }
    try {
        $prefix = (npm config get prefix) 2>$null
        if ($prefix -is [array]) { $prefix = $prefix[0] }
        if ($prefix) {
            $c = Join-Path $prefix 'dsh.cmd'
            if (Test-Path -LiteralPath $c) { return $c }
        }
    } catch { }
    return ''
}

function Get-DshVersion {
    $c = Get-DshCmd
    if (-not $c) { return '' }
    try { $v = (& $c --version) 2>$null; if ($v -is [array]) { $v = $v[0] }; return "$v".Trim() } catch { return '' }
}

# ── 轻量缓存 ──
# 查 node / dsh 版本都要起进程（尤其 npm config get prefix 慢），而面板页面每 4 秒轮询一次
# /api/status。若每次都去起进程，接口会慢到客户端超时（CI 上就是这样把面板测试拖挂的）。
# 用几十秒的短缓存兜住：既快，又不会让版本信息过时太久。
$script:verCache = @{}
function Get-CachedValue {
    param([string]$Key, [int]$TtlSeconds, [scriptblock]$Factory)
    $now = Get-Date
    $hit = $script:verCache[$Key]
    if ($hit -and ($now - $hit.Time).TotalSeconds -lt $TtlSeconds) { return $hit.Value }
    $v = & $Factory
    $script:verCache[$Key] = @{ Time = $now; Value = $v }
    return $v
}

function Get-ServiceState {
    $r = [PSCustomObject]@{ Running = $false; Port = 0; Url = '' }
    $ports = @()
    $cfg = Get-Config
    if ($cfg -and $cfg.preferredPort) { $ports += [int]$cfg.preferredPort }
    $ports += @(3080, 3081, 8080)
    if (Test-Path -LiteralPath (Join-Path $launcherDir 'serving-url.txt')) {
        try {
            $u = (Get-Content -LiteralPath (Join-Path $launcherDir 'serving-url.txt') -Raw).Trim()
            if ($u -match ':(\d+)') { $ports = @([int]$Matches[1]) + $ports }
        } catch { }
    }
    foreach ($p in ($ports | Select-Object -Unique)) {
        if ($p -le 0) { continue }
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $c.Connect('127.0.0.1', $p); $c.Close()
            $r.Running = $true; $r.Port = $p; $r.Url = "http://127.0.0.1:$p"
            break
        } catch { $c.Close() }
    }
    return $r
}

# ── 动作：调用现有脚本 ──
function Start-Detached {
    param([string]$Script, [string[]]$ScriptArgs, [switch]$Visible)
    $full = Join-Path $root $Script
    if (-not (Test-Path -LiteralPath $full)) { return $false }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $full) + $ScriptArgs
    $style = if ($Visible) { 'Normal' } else { 'Hidden' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle $style | Out-Null
        Write-PanelLog "启动动作：$Script $($ScriptArgs -join ' ')"
        return $true
    } catch {
        Write-PanelLog "动作失败：$Script → $($_.Exception.Message)"
        return $false
    }
}

function Get-LogTail {
    param([string]$Name, [int]$Tail = 120)
    $map = @{
        install = (Join-Path $root 'install.log')
        launch  = (Join-Path $launcherDir 'launch.log')
        update  = (Join-Path $launcherDir 'update.log')
        panel   = $panelLog
    }
    $f = $map[$Name]
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { return "(暂无日志)" }
    try { return ((Get-Content -LiteralPath $f -Encoding UTF8 -Tail $Tail) -join "`r`n") } catch { return "(读取失败)" }
}

# ── HTTP 小工具 ──
function Send-Bytes {
    param($Response, [byte[]]$Bytes, [string]$ContentType)
    try {
        $Response.ContentType = $ContentType
        $Response.ContentLength64 = $Bytes.Length
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    } catch { } finally { try { $Response.OutputStream.Close() } catch { } }
}
function Send-Json {
    param($Response, $Object, [int]$Status = 200)
    $json = ($Object | ConvertTo-Json -Depth 6 -Compress)
    try { $Response.StatusCode = $Status } catch { }
    Send-Bytes -Response $Response -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8'
}
function Send-Html {
    param($Response, [string]$Html)
    Send-Bytes -Response $Response -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Html)) -ContentType 'text/html; charset=utf-8'
}
function Send-Text {
    param($Response, [string]$Text, [int]$Status = 200)
    try { $Response.StatusCode = $Status } catch { }
    Send-Bytes -Response $Response -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text)) -ContentType 'text/plain; charset=utf-8'
}

# ── 页面（静态 HTML + JS，通过 /api/* 交互）──
$page = @'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>DSH 控制面板</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { font-family: "Microsoft YaHei", system-ui, sans-serif; margin: 0; background: #f5f6f8; color: #1f2430; }
  header { background: #1f6feb; color: #fff; padding: 14px 20px; font-size: 18px; font-weight: 600; display:flex; justify-content:space-between; align-items:center;}
  header small { font-weight: 400; opacity: .85; }
  .wrap { max-width: 1040px; margin: 18px auto; padding: 0 16px 40px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  @media (max-width: 780px) { .grid { grid-template-columns: 1fr; } }
  .card { background: #fff; border: 1px solid #e3e6ea; border-radius: 10px; padding: 14px 16px; }
  .card h2 { margin: 0 0 10px; font-size: 15px; color: #4b5563; }
  .row { display: flex; justify-content: space-between; padding: 5px 0; border-bottom: 1px dashed #eef0f3; font-size: 14px; }
  .row:last-child { border-bottom: none; }
  .row b { font-weight: 600; }
  .ok { color: #14803c; } .bad { color: #c0392b; }
  button { font: inherit; padding: 9px 14px; margin: 4px 6px 4px 0; border-radius: 8px; border: 1px solid #cbd2d9; background: #fff; cursor: pointer; }
  button:hover { background: #f2f5f9; }
  button.primary { background: #1f6feb; border-color: #1f6feb; color: #fff; }
  button.primary:hover { background: #1a5fd0; }
  button.danger { background: #fff0f0; border-color: #f3c2c2; color: #b02418; }
  input[type=text] { font: inherit; padding: 8px 10px; border-radius: 8px; border: 1px solid #cbd2d9; width: 100%; }
  pre { background: #0f172a; color: #d6e2f0; padding: 12px; border-radius: 8px; max-height: 260px; overflow: auto; font-size: 12px; line-height: 1.5; }
  .muted { color: #6b7280; font-size: 12px; }
  .toast { position: fixed; right: 18px; bottom: 18px; background: #1f6feb; color: #fff; padding: 10px 16px; border-radius: 8px; opacity: 0; transition: .25s; }
  .toast.show { opacity: .95; }
</style>
</head>
<body>
<header>
  <span>DSH 控制面板</span>
  <small id="svc">检测中…</small>
</header>
<div class="wrap">
  <div class="grid">
    <div class="card">
      <h2>环境状态</h2>
      <div class="row"><span>Node.js</span><b id="node">…</b></div>
      <div class="row"><span>DSH 本体</span><b id="dsh">…</b></div>
      <div class="row"><span>服务状态</span><b id="running">…</b></div>
      <div class="row"><span>程序目录</span><b id="prog" style="font-weight:400;font-size:12px;word-break:break-all">…</b></div>
      <div class="row"><span>数据目录</span><b id="data" style="font-weight:400;font-size:12px;word-break:break-all">…</b></div>
      <div class="row"><span>窗口模式</span><b id="appmode">…</b></div>
    </div>

    <div class="card">
      <h2>一键操作</h2>
      <button class="primary" onclick="act('install')">安装 / 修复</button>
      <button class="primary" onclick="act('start')">启动 DSH</button>
      <button onclick="act('open')">打开 DSH 页面</button>
      <button onclick="act('update')">更新 DSH</button>
      <button onclick="act('uninstall')">卸载</button>
      <div style="margin-top:10px">
        <button onclick="act('open-data')">打开数据目录</button>
        <button onclick="act('open-log')">打开日志目录</button>
      </div>
      <div class="muted" style="margin-top:8px">安装/更新会弹出进度窗口；其余操作在后台执行。</div>
    </div>
  </div>

  <div class="grid" style="margin-top:16px">
    <div class="card">
      <h2>首次使用：自己配 API Key</h2>
      <div class="muted" style="margin-bottom:8px">
        进入 DSH 后需要填一个<strong>你自己的</strong> DeepSeek API Key（费用与数据都在你自己账号下，我们不代管）：<br>
        ① 点下面按钮去开放平台注册 → ② 创建一个 API Key 并复制 → ③ 回到 DSH 界面里粘贴保存。
      </div>
      <button class="primary" onclick="act('open-apikey')">去获取 API Key</button>
      <button onclick="act('open')">打开 DSH 界面</button>
    </div>

    <div class="card">
      <h2>快捷方式：改名 / 换图标</h2>
      <div style="margin-bottom:8px">
        <input type="text" id="scname" placeholder="快捷方式名称（支持中文，例如：我的DSH）">
      </div>
      <div style="margin-bottom:8px">
        <input type="text" id="scicon" placeholder="图标路径（.ico/.exe/.dll，可留空用默认）">
      </div>
      <button onclick="pickIcon()">选择图标…</button>
      <button class="primary" onclick="act('rename')">应用</button>
      <div class="muted" style="margin-top:8px">「选择图标」会弹出系统文件框（在本机弹出，不在网页里）。</div>
    </div>

    <div class="card">
      <h2>行为开关</h2>
      <div class="row"><span>应用模式窗口（无地址栏，像桌面软件）</span><b><button id="btn-appmode" onclick="toggle('appMode')">…</button></b></div>
      <div class="row"><span>关掉窗口时同时停止服务</span><b><button id="btn-kill" onclick="toggle('killHostOnExit')">…</button></b></div>
      <div class="row"><span>独立浏览器配置（不共用你平时的）</span><b><button id="btn-iso" onclick="toggle('isolatedBrowserProfile')">…</button></b></div>
      <div class="muted" style="margin-top:8px">改完立即写入 launcher\config.json，下次启动生效。</div>
    </div>
  </div>

  <div class="card" style="margin-top:16px">
    <h2>日志 <span class="muted" id="logname">(launch)</span></h2>
    <div style="margin-bottom:8px">
      <button onclick="showLog('install')">安装日志</button>
      <button onclick="showLog('launch')">启动日志</button>
      <button onclick="showLog('update')">更新日志</button>
      <button onclick="showLog('panel')">面板日志</button>
    </div>
    <pre id="log">加载中…</pre>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
function toast(msg){ const t=document.getElementById('toast'); t.textContent=msg; t.classList.add('show'); setTimeout(()=>t.classList.remove('show'), 2600); }
async function api(path, opts){ const r = await fetch(path, opts); if(!r.ok) throw new Error(await r.text()); return r.headers.get('content-type')?.includes('json') ? r.json() : r.text(); }
async function refresh(){
  try{
    const s = await api('/api/status');
    document.getElementById('node').innerHTML = s.node ? `<span class="ok">${s.node}</span>` : '<span class="bad">未安装</span>';
    document.getElementById('dsh').innerHTML = s.dsh ? `<span class="ok">${s.dsh}</span>` : '<span class="bad">未安装</span>';
    document.getElementById('running').innerHTML = s.running ? `<span class="ok">运行中 ${s.url}</span>` : '<span class="bad">未运行</span>';
    document.getElementById('prog').textContent = s.programRoot || '';
    document.getElementById('data').textContent = s.installRoot || '';
    document.getElementById('appmode').innerHTML = s.appMode ? '<span class="ok">应用模式</span>' : '浏览器标签页';
    document.getElementById('svc').textContent = s.running ? ('服务：' + s.url) : '服务：未运行';
    const b1=document.getElementById('btn-appmode'), b2=document.getElementById('btn-kill'), b3=document.getElementById('btn-iso');
    b1.textContent = s.appMode ? '已开启（点此关闭）' : '已关闭（点此开启）';
    b2.textContent = s.killHostOnExit ? '已开启（点此关闭）' : '已关闭（点此开启）';
    b3.textContent = s.isolatedBrowserProfile ? '独立配置（点此改回共用）' : '共用配置（点此改独立）';
  }catch(e){ document.getElementById('svc').textContent='面板连接异常'; }
}
async function act(name){
  const name_ = document.getElementById('scname').value.trim();
  const icon_ = document.getElementById('scicon').value.trim();
  try{
    const r = await api('/api/action', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({action:name, name:name_, icon:icon_})});
    toast(r.message || '已执行');
    setTimeout(refresh, 800);
  }catch(e){ toast('失败：'+e.message); }
}
async function pickIcon(){
  try{
    const r = await api('/api/pick-icon', {method:'POST'});
    if(r.path){ document.getElementById('scicon').value = r.path; toast('已选择图标'); }
  }catch(e){ toast('取消或失败'); }
}
async function toggle(key){
  try{ const r = await api('/api/setting', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key:key})}); toast(r.message); refresh(); }
  catch(e){ toast('失败：'+e.message); }
}
async function showLog(name){
  document.getElementById('logname').textContent = '(' + name + ')';
  try{ document.getElementById('log').textContent = await api('/api/log?name=' + name); }catch(e){ document.getElementById('log').textContent = '读取失败'; }
}
refresh(); setInterval(refresh, 4000); showLog('launch');
</script>
</body>
</html>
'@

# ── 启动监听 ──
$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    $msg = "面板启动失败：$($_.Exception.Message)"
    Write-PanelLog $msg
    Write-Host "  [×] $msg"
    Write-Host "      可能端口被占用，或系统不允许注册本地监听地址（需要管理员/URL ACL），换一个端口再试：-Port 17801" -ForegroundColor Yellow
    # 便于自动化诊断：把失败原因写到 stderr
    [Console]::Error.WriteLine($msg)
    exit 1
}

$url = "http://127.0.0.1:$Port/"
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║        DSH 控制面板已启动                 ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  地址：$url" -ForegroundColor Green
Write-Host "  （只监听本机 127.0.0.1，不对外开放；关掉这个窗口即停止面板）" -ForegroundColor DarkGray
Write-Host ""
Write-PanelLog "面板启动：$url"

if (-not $NoBrowser) { try { Start-Process $url | Out-Null } catch { } }

# 后台异步处理请求，窗口保持可关闭
$running = $true
while ($running -and $listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    if ($ctx -eq $null) { continue }

    $req = $ctx.Request
    $res = $ctx.Response
    $path = $req.Url.AbsolutePath

    try {
        if ($path -eq '/' -or $path -eq '/index.html') {
            Send-Html -Response $res -Html $page
        }
        elseif ($path -eq '/api/status') {
            $cfg = Get-Config
            $svc = Get-ServiceState
            $dataRoot = ''
            if ($cfg -and $cfg.installRoot) { $dataRoot = "$($cfg.installRoot)" }
            Send-Json -Response $res -Object ([ordered]@{
                node                   = (Get-CachedValue -Key 'node' -TtlSeconds 30 -Factory { Get-NodeVersion })
                dsh                    = (Get-CachedValue -Key 'dsh' -TtlSeconds 30 -Factory { Get-DshVersion })
                running                = $svc.Running
                port                   = $svc.Port
                url                    = $svc.Url
                programRoot            = $root
                installRoot            = $dataRoot
                appMode                = [bool]($cfg -and $cfg.appMode)
                killHostOnExit         = [bool]($cfg -and $cfg.killHostOnExit)
                isolatedBrowserProfile = [bool]($cfg -and $cfg.isolatedBrowserProfile)
            })
        }
        elseif ($path -eq '/api/log') {
            $name = $req.QueryString['name']
            if (-not $name) { $name = 'launch' }
            Send-Text -Response $res -Text (Get-LogTail -Name $name)
        }
        elseif ($path -eq '/api/setting' -and $req.HttpMethod -eq 'POST') {
            $body = ''
            $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $obj = $null
            try { $obj = $body | ConvertFrom-Json } catch { }
            $key = if ($obj) { "$($obj.key)" } else { '' }
            if ($key -notin @('appMode', 'killHostOnExit', 'isolatedBrowserProfile')) {
                Send-Json -Response $res -Object @{ ok = $false; message = "不支持的开关：$key" } -Status 400
            } else {
                $cfg = Get-Config
                $cur = $false
                if ($cfg -and (@($cfg.PSObject.Properties.Name) -contains $key)) { $cur = [bool]$cfg.$key }
                $new = -not $cur
                $okSet = Save-ConfigValue -Key $key -Value $new
                $cn = @{ appMode = '应用模式窗口'; killHostOnExit = '关窗即停服务'; isolatedBrowserProfile = '独立浏览器配置' }[$key]
                Send-Json -Response $res -Object @{ ok = $okSet; message = ("$cn 已" + $(if ($new) { '开启' } else { '关闭' }) + "（下次启动生效）") }
            }
        }
        elseif ($path -eq '/api/pick-icon' -and $req.HttpMethod -eq 'POST') {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = '选择快捷方式图标'
            $dlg.Filter = '图标 (*.ico)|*.ico|程序或图标库 (*.exe;*.dll)|*.exe;*.dll|所有文件 (*.*)|*.*'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Send-Json -Response $res -Object @{ ok = $true; path = $dlg.FileName }
            } else {
                Send-Json -Response $res -Object @{ ok = $false; path = '' }
            }
        }
        elseif ($path -eq '/api/action' -and $req.HttpMethod -eq 'POST') {
            $body = ''
            $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $obj = $null
            try { $obj = $body | ConvertFrom-Json } catch { }
            $action = if ($obj) { "$($obj.action)" } else { '' }
            $scName = if ($obj -and $obj.name) { "$($obj.name)" } else { '' }
            $scIcon = if ($obj -and $obj.icon) { "$($obj.icon)" } else { '' }
            $msg = ''
            switch ($action) {
                'install'   { if (Start-Detached -Script 'install.ps1' -ScriptArgs @('-Repair') -Visible) { $msg = '已开始安装/修复，请看弹出的进度窗口' } else { $msg = '找不到 install.ps1' } }
                'start'     { if (Start-Detached -Script 'launcher\start-dsh.ps1') { $msg = '已开始启动 DSH' } else { $msg = '找不到启动器' } }
                'update'    { if (Start-Detached -Script 'update-dsh.ps1' -ScriptArgs @() -Visible) { $msg = '已开始更新，请看弹出的窗口' } else { $msg = '找不到 update-dsh.ps1' } }
                'uninstall' { if (Start-Detached -Script 'uninstall.ps1' -ScriptArgs @() -Visible) { $msg = '已打开卸载窗口' } else { $msg = '找不到 uninstall.ps1' } }
                'rename'    {
                    $a = @('-Force', '-NonInteractive')
                    if ($scName -ne '') { $a += @('-Name', $scName) }
                    if ($scIcon -ne '') { $a += @('-IconPath', $scIcon) }
                    if (Start-Detached -Script 'shortcut.ps1' -ScriptArgs $a) { $msg = '已按填写内容创建/更新快捷方式' } else { $msg = '找不到 shortcut.ps1' }
                }
                'open'      {
                    $svc = Get-ServiceState
                    if ($svc.Running) { Start-Process $svc.Url | Out-Null; $msg = "已打开 $($svc.Url)" } else { $msg = '服务未运行，请先点「启动 DSH」' }
                }
                'open-data' {
                    $cfg = Get-Config
                    $d = if ($cfg -and $cfg.dshHome) { "$($cfg.dshHome)" } else { Join-Path $env:USERPROFILE '.dsh' }
                    if (Test-Path -LiteralPath $d) { Start-Process explorer.exe $d | Out-Null; $msg = "已打开 $d" } else { $msg = '数据目录不存在' }
                }
                'open-log'  { Start-Process explorer.exe $launcherDir | Out-Null; $msg = "已打开 $launcherDir" }
                'open-apikey' {
                    try {
                        Start-Process 'https://platform.deepseek.com/api_keys' | Out-Null
                        $msg = '已打开 DeepSeek 开放平台：注册 → 创建 API Key → 复制后回到 DSH 界面里粘贴保存'
                    } catch {
                        $msg = '打不开浏览器，请手动访问 https://platform.deepseek.com/api_keys'
                    }
                }
                default     { Send-Json -Response $res -Object @{ ok = $false; message = "未知操作：$action" } -Status 400; continue }
            }
            Send-Json -Response $res -Object @{ ok = $true; message = $msg }
        }
        else {
            Send-Text -Response $res -Text 'not found' -Status 404
        }
    } catch {
        Write-PanelLog "处理 $path 出错：$($_.Exception.Message)"
        try { Send-Text -Response $res -Text ("panel error: " + $_.Exception.Message) -Status 500 } catch { }
    }
}

try { $listener.Stop(); $listener.Close() } catch { }
Write-PanelLog "面板已退出"
exit 0
