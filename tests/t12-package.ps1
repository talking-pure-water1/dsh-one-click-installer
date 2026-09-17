# 验收 12：打包质量 —— 精简版内容干净、维护版含测试，且精简版真的能装
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$packer = Join-Path $Root 'pack-release.ps1'
$outDir = Join-Path $Root '_verify_pack'
$sandbox = Join-Path $Root '_verify_pack_install'
$desktop = [Environment]::GetFolderPath('Desktop')
$scName = 'DSH打包测试'
$lnk = Join-Path $desktop "$scName.lnk"

foreach ($d in @($outDir, $sandbox)) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }

$problems = @()
try {
    # 1) 生成两种包到临时目录
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $packer -IncludeDev -OutDir $outDir 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { $problems += "打包脚本退出码 $LASTEXITCODE" }

    $slim = Get-ChildItem -LiteralPath $outDir -Filter '*_发布版_*.zip' | Select-Object -First 1
    $dev  = Get-ChildItem -LiteralPath $outDir -Filter '*_维护版_*.zip' | Select-Object -First 1
    if (-not $slim) { $problems += "没有生成精简版" } 
    if (-not $dev)  { $problems += "没有生成维护版" }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # 2) 精简版内容断言
    if ($slim) {
        $z = [System.IO.Compression.ZipFile]::OpenRead($slim.FullName)
        $names = $z.Entries | ForEach-Object { $_.FullName }
        $z.Dispose()

        $mustHave = @(
            'install.ps1', 'shortcut.ps1', 'update-dsh.ps1', 'uninstall.ps1', 'panel.ps1',
            '安装DSH（初次使用点击这里就好啦⭐️）.cmd', '修复.cmd', '卸载.cmd', '更新DSH.cmd', '改名换图标.cmd', '启动面板（第二次及以后使用点击这个就好啦❀）.cmd',
            'launcher\start-dsh.ps1', 'assets\dsh.ico', '分发说明.txt'
        )
        foreach ($m in $mustHave) {
            if (-not ($names | Where-Object { $_ -like "*$m" })) { $problems += "精简版缺少：$m" }
        }
        $mustNotHave = @('tests\', 'pack-release', '打包发布', '测试报告', 'config.json', '.log')
        foreach ($m in $mustNotHave) {
            $hit = $names | Where-Object { $_ -like "*$m*" }
            if ($hit) { $problems += "精简版混入了不该有的东西：$($hit -join ', ')" }
        }
        Write-Host "      精简版：$($names.Count) 个条目，$([math]::Round($slim.Length/1KB,1)) KB" -ForegroundColor DarkGray
    }

    # 3) 维护版要包含测试与打包脚本
    if ($dev) {
        $z = [System.IO.Compression.ZipFile]::OpenRead($dev.FullName)
        $names = $z.Entries | ForEach-Object { $_.FullName }
        $z.Dispose()
        foreach ($m in @('tests\run-all.ps1', 'pack-release.ps1')) {
            if (-not ($names | Where-Object { $_ -like "*$m" })) { $problems += "维护版缺少：$m" }
        }
        Write-Host "      维护版：$($names.Count) 个条目，$([math]::Round($dev.Length/1KB,1)) KB" -ForegroundColor DarkGray
    }

    # 4) 解压精简版，真的跑一次安装（验证「精简版也能装上」）
    if ($slim) {
        $extract = Join-Path $outDir 'extract'
        Expand-Archive -LiteralPath $slim.FullName -DestinationPath $extract -Force
        # zip 内的顶层文件夹名 = 打包源目录的目录名（仓库名可能和工具包名不同，不能写死）
        $topName = Split-Path $Root -Leaf
        $pkgRoot = Join-Path $extract $topName
        if (-not (Test-Path -LiteralPath $pkgRoot)) {
            $cand = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
            if ($cand) { $pkgRoot = $cand.FullName }
        }
        $installer = Join-Path $pkgRoot 'install.ps1'
        if (-not (Test-Path -LiteralPath $installer)) {
            $problems += "精简版解压后找不到 install.ps1"
        } else {
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer,
                   '-InstallRoot', $sandbox, '-SkipNode', '-SkipDsh', '-SkipDshHome', '-NoStart',
                   '-NonInteractive', '-NoEnvChange', '-ShortcutName', $scName)
            $instOut = & powershell.exe @a 2>&1 | Out-String
            if (-not (Test-Path -LiteralPath (Join-Path $sandbox 'app\launcher\start-dsh.ps1'))) {
                $problems += "用精简版安装后，部署目录里没有启动器"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $sandbox 'app\panel.ps1'))) {
                $problems += "用精简版安装后，部署目录里没有面板"
            }
            if (-not (Test-Path -LiteralPath $lnk)) { $problems += "用精简版安装没有创建快捷方式" }
        }
    }
} finally {
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
    foreach ($d in @($outDir, $sandbox)) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

if ($problems.Count -eq 0) {
    Write-Host "PASS 打包质量：精简版干净且可安装，维护版含测试与打包脚本" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 打包质量：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    $sid = try { (Get-Process -Id $PID).SessionId } catch { '?' }
    Write-Host "       [环境] 会话=$sid 交互式=$([Environment]::UserInteractive) 桌面=$desktop 存在=$(Test-Path -LiteralPath $desktop)" -ForegroundColor DarkGray
    if ($instOut) {
        Write-Host "       [精简版安装输出]" -ForegroundColor DarkGray
        $instOut.Trim() -split "`r?`n" | Select-Object -First 40 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    }
    if ($out) {
        Write-Host "       [打包脚本输出]" -ForegroundColor DarkGray
        $out.Trim() -split "`r?`n" | Select-Object -First 15 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    }
    exit 1
}
