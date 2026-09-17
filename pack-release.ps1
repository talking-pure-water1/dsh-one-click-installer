<#
  pack-release.ps1 —— 生成分发包

  两种包：
    1)【精简版·给用户】默认产物：只含「装完能用」必需的东西
       入口：安装DSH（初次使用点击这里就好啦⭐️）.cmd / 修复.cmd / 卸载.cmd / 更新DSH.cmd / 改名换图标.cmd / 启动面板（第二次及以后使用点击这个就好啦❀）.cmd
       逻辑：install.ps1 / shortcut.ps1 / update-dsh.ps1 / uninstall.ps1 / panel.ps1
       资源：launcher\（启动器）、assets\dsh.ico（图标）、README、分发说明.txt
       不含：tests\（验收测试）、pack-release.*（打包脚本）等维护者才用的东西
    2)【维护版·给自己】加 -IncludeDev：在精简版基础上再加 tests\ 与打包脚本，
       方便复跑验收、再次打包。

  都会自动剔除本机运行产物（日志、config.json、serving-url.txt、app-profile 等）。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File pack-release.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File pack-release.ps1 -IncludeDev
  产物（默认输出到工具包上一级目录）：
    DSH一键安装_发布版_日期.zip    （精简，给用户）
    DSH一键安装_维护版_日期.zip    （完整，给自己）
#>
[CmdletBinding()]
param(
    [switch]$IncludeDev,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$folderName = Split-Path $src -Leaf
if ($OutDir -eq '') { $OutDir = Split-Path $src -Parent }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ── 用户包白名单 ──
$userFiles = @(
    'install.ps1', 'shortcut.ps1', 'update-dsh.ps1', 'uninstall.ps1', 'panel.ps1',
    '安装DSH（初次使用点击这里就好啦⭐️）.cmd', '修复.cmd', '卸载.cmd', '更新DSH.cmd', '改名换图标.cmd', '启动面板（第二次及以后使用点击这个就好啦❀）.cmd',
    'README_给小白的使用说明.md'
)
$userDirs = @('launcher', 'assets')

# ── 维护者额外内容（仅 -IncludeDev）──
$devFiles = @('pack-release.ps1', '打包发布.cmd')
$devDirs = @('tests')

# ── 永远排除：本机运行产物 ──
$excludeFiles = @(
    'install.log', 'launcher\config.json', 'launcher\launch.log', 'launcher\update.log',
    'launcher\panel.log', 'launcher\serving-url.txt', 'launcher\dsh-stdout.log', 'launcher\dsh-stderr.log'
)
$excludeDirPatterns = @('app-profile', '_verify')

function Copy-One {
    param([string]$Rel, [string]$StageFolder)
    $from = Join-Path $src $Rel
    if (-not (Test-Path -LiteralPath $from)) { Write-Host "    缺少（跳过）：$Rel" -ForegroundColor DarkYellow; return 0 }
    $to = Join-Path $StageFolder $Rel
    if (Test-Path -LiteralPath $from -PathType Container) {
        New-Item -ItemType Directory -Path $to -Force | Out-Null
        Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
        return @(Get-ChildItem -LiteralPath $to -Recurse -File).Count
    } else {
        $dir = Split-Path $to -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $from -Destination $to -Force
        return 1
    }
}

function New-Package {
    param([string]$Kind)   # user | dev
    $stamp = Get-Date -Format 'yyyyMMdd'
    $zipName = if ($Kind -eq 'user') { "${folderName}_发布版_$stamp.zip" } else { "${folderName}_维护版_$stamp.zip" }
    $zipPath = Join-Path $OutDir $zipName

    $staging = Join-Path $env:TEMP ("dsh-pack-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $stageFolder = Join-Path $staging $folderName
    New-Item -ItemType Directory -Path $stageFolder -Force | Out-Null

    Write-Host ""
    Write-Host "  ── 生成$(if ($Kind -eq 'user') { '精简版（给用户）' } else { '维护版（含测试）' }) ──" -ForegroundColor Cyan
    $count = 0
    foreach ($f in $userFiles) { $count += Copy-One -Rel $f -StageFolder $stageFolder }
    foreach ($d in $userDirs)  { $count += Copy-One -Rel $d -StageFolder $stageFolder }
    if ($Kind -eq 'dev') {
        foreach ($f in $devFiles) { $count += Copy-One -Rel $f -StageFolder $stageFolder }
        foreach ($d in $devDirs)  { $count += Copy-One -Rel $d -StageFolder $stageFolder }
    }

    # 用户说明书兜底：仓库版把说明放在 docs\ 下（文件名与工具包不同），
    # 包里统一成同一个文件名，免得打出来的包少了说明书。
    $guide = Join-Path $stageFolder 'README_给小白的使用说明.md'
    if (-not (Test-Path -LiteralPath $guide)) {
        foreach ($cand in @('docs\使用说明.md', 'README.md')) {
            $p = Join-Path $src $cand
            if (Test-Path -LiteralPath $p) {
                Copy-Item -LiteralPath $p -Destination $guide -Force
                $count++
                Write-Host "    说明书取自：$cand" -ForegroundColor DarkGray
                break
            }
        }
    }

    # 兜底清理：万一目录里混进了运行产物
    foreach ($pat in $excludeDirPatterns) {
        Get-ChildItem -LiteralPath $stageFolder -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$pat*" } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
    }
    foreach ($rel in $excludeFiles) {
        $p = Join-Path $stageFolder $rel
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    Get-ChildItem -LiteralPath $stageFolder -Recurse -File -Filter *.log -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

    # 分发说明
    if ($Kind -eq 'user') {
        $note = @"
【DSH 一键安装 · 精简版】

怎么用：
  1. 解压到任意位置（桌面 / D 盘都行）
  2. 【第一次】双击「安装DSH（初次使用点击这里就好啦⭐️）.cmd」；
     中途会问快捷方式的名字和图标，不想改就一路按回车
  3. 装好后会自动打开 DSH 窗口，桌面出现你命名的快捷方式
  4. 【第二次及以后】用桌面上那个快捷方式就行；
     想改设置/看日志/更新/卸载，就双击「启动面板（第二次及以后使用点击这个就好啦❀）.cmd」
  5. 装完这个文件夹就能删掉 —— 程序已复制到安装目录，快捷方式照样能用

第一次使用：进入界面后自己填 DeepSeek API Key（到 https://platform.deepseek.com 注册创建）。

日常维护：开始菜单搜索「DSH 控制面板」（安装/启动/更新/改名换图标/卸载/看日志都在里面）。
详细说明见 README_给小白的使用说明.md。
打包时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
    } else {
        $note = @"
【DSH 一键安装 · 维护版】

= 精简版全部内容，外加：
  - tests\            验收测试（run-all.ps1 一键跑；加 -Network 可测在线装 Node）
  - pack-release.ps1  重新打包脚本（加 -IncludeDev 生成维护版）
  - 打包发布.cmd       上面脚本的双击入口

本包不含任何本机运行日志与配置，可直接转发。
打包时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
    }
    Set-Content -LiteralPath (Join-Path $stageFolder '分发说明.txt') -Value $note -Encoding UTF8

    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path $stageFolder -DestinationPath $zipPath -CompressionLevel Optimal
    Remove-Item -LiteralPath $staging -Recurse -Force

    $size = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
    $z = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $n = $z.Entries.Count
    $z.Dispose()
    Write-Host "  [√] $zipPath" -ForegroundColor Green
    Write-Host "      大小 $size KB，共 $n 个条目" -ForegroundColor DarkGray
    return $zipPath
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Write-Host ""
Write-Host "  打包源目录：$src" -ForegroundColor White

$userZip = New-Package -Kind 'user'
if ($IncludeDev) { [void](New-Package -Kind 'dev') }

Write-Host ""
Write-Host "  精简版内容一览：" -ForegroundColor Cyan
$z = [System.IO.Compression.ZipFile]::OpenRead($userZip)
$z.Entries | Sort-Object FullName | ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor DarkGray }
$z.Dispose()
Write-Host ""
Write-Host "  用户包不含 tests\ 与打包脚本；需要它们请加 -IncludeDev 生成维护版。" -ForegroundColor Yellow
Write-Host ""
exit 0
