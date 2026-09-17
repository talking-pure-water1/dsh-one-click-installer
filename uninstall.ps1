<#
  uninstall.ps1 —— 卸载/清理 DSH 一键安装器布下的东西

  默认行为（保守）：
    - 删除桌面（及可选开始菜单）上由本安装器创建的快捷方式
    - 删除安装目录里的启动器与日志
    - **保留**你的 DSH 数据（会话/插件配置），也保留全局 dsh 包

  可选开关：
    -RemoveData      一并删除数据目录（DSH_HOME 或 ~/.dsh）——危险，会丢会话
    -RemoveGlobalDsh 卸载全局 @deepseek-ai/dsh 包
    -RestoreNpmrc    用 .npmrc.dsh-bak 还原安装前的 npm 配置
    -Yes             不询问，直接执行
    -ShortcutName    要删除的快捷方式名（默认 DSH Web）
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [string]$ShortcutName = 'DSH Web',
    [switch]$RemoveData,
    [switch]$RemoveGlobalDsh,
    [switch]$RestoreNpmrc,
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'

# 定位「已部署的程序目录」：优先读配置（安装时写入），其次取脚本所在目录
$scriptDir = $PSScriptRoot
$cfgCandidates = @(
    (Join-Path $scriptDir 'launcher\config.json'),
    (Join-Path $scriptDir 'config.json')
)
$cfg = $null
foreach ($c in $cfgCandidates) {
    if (Test-Path -LiteralPath $c) {
        try { $cfg = Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json; break } catch { }
    }
}
if ($InstallRoot -eq '') {
    if ($cfg -and $cfg.programRoot) { $InstallRoot = Split-Path "$($cfg.programRoot)" -Parent }   # app 的上一级 = 安装根
    else { $InstallRoot = $scriptDir }
}
$appDir = if ($cfg -and $cfg.programRoot) { "$($cfg.programRoot)" } else { $scriptDir }
$dataRoot = if ($cfg -and $cfg.installRoot) { "$($cfg.installRoot)" } else { $InstallRoot }
$launcherDir = if ($cfg -and $cfg.launcherDir) { "$($cfg.launcherDir)" } else { Join-Path $appDir 'launcher' }

function Say { param([string]$m, [string]$c = 'Gray') Write-Host "  $m" -ForegroundColor $c }
function Confirm-Step {
    param([string]$Question)
    if ($Yes) { return $true }
    $a = Read-Host "  $Question (Y/N)"
    return ($a -match '^[Yy]')
}

function Get-RealDesktop {
    try {
        $p = [Environment]::GetFolderPath('Desktop')
        if ($p) { return $p }
    } catch { }
    try { return (New-Object -ComObject WScript.Shell).SpecialFolders.Item('Desktop') } catch { }
    return (Join-Path $env:USERPROFILE 'Desktop')
}

Write-Host ""
Say "DSH 一键安装器 —— 卸载/清理" 'Cyan'
Say "安装目录：$InstallRoot"
Write-Host ""

# 1) 快捷方式（按名字 + 按目标扫描，避免漏掉改过名的）
$desktop = Get-RealDesktop
$startPsTarget = Join-Path $launcherDir 'start-dsh.ps1'
$sh = New-Object -ComObject WScript.Shell
$toDelete = New-Object System.Collections.ArrayList
$named = @(
    (Join-Path $desktop "$ShortcutName.lnk"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$ShortcutName.lnk"),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DSH 控制面板.lnk')
)
foreach ($f in $named) { if (Test-Path -LiteralPath $f) { [void]$toDelete.Add($f) } }
foreach ($d in @($desktop, (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.lnk -ErrorAction SilentlyContinue)) {
        try {
            $isOurs = $false
            try {
                $s = $sh.CreateShortcut($f.FullName)
                $isOurs = (("$($s.Arguments)" -match 'start-dsh\.ps1') -or ("$($s.TargetPath)" -match '启动DSH\.vbs$'))
            } catch { }
            if (-not $isOurs) {
                # COM 读不出来时（中文名 + 非中文代码页，COM 只返回空壳），直接扫文件内容
                $txt = [System.Text.Encoding]::Unicode.GetString([System.IO.File]::ReadAllBytes($f.FullName))
                $isOurs = ($txt.Contains('start-dsh.ps1') -or $txt.Contains('启动DSH.vbs'))
            }
            if ($isOurs -and -not ($toDelete -contains $f.FullName)) { [void]$toDelete.Add($f.FullName) }
        } catch { }
    }
}
foreach ($f in ($toDelete | Select-Object -Unique)) {
    if (Confirm-Step "删除快捷方式 $f ？") {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        Say "已删除：$f" 'Green'
    } else { Say "跳过：$f" 'Yellow' }
}

# 2) 数据目录（默认保留）
$dshHome = [Environment]::GetEnvironmentVariable('DSH_HOME', 'User')
if ($RemoveData) {
    $targets = @()
    if ($dshHome) { $targets += $dshHome }
    $targets += (Join-Path $env:USERPROFILE '.dsh')
    foreach ($t in $targets) {
        if ((Test-Path -LiteralPath $t) -and (Confirm-Step "删除数据目录 $t（含全部会话）？")) {
            Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
            Say "已删除数据目录：$t" 'Green'
        }
    }
    if ($dshHome -and (Confirm-Step "清除用户环境变量 DSH_HOME ？")) {
        [Environment]::SetEnvironmentVariable('DSH_HOME', $null, 'User')
        Say "已清除 DSH_HOME" 'Green'
    }
} else {
    Say "保留数据目录（如需删除请加 -RemoveData）：$(if ($dshHome) { $dshHome } else { Join-Path $env:USERPROFILE '.dsh' })" 'DarkGray'
}

# 3) 全局 dsh 包（默认保留）
if ($RemoveGlobalDsh) {
    if (Confirm-Step "卸载全局 @deepseek-ai/dsh 包？") {
        & npm uninstall -g '@deepseek-ai/dsh' 2>&1 | ForEach-Object { Say "npm: $_" 'DarkGray' }
        Say "已请求卸载全局 dsh" 'Green'
    }
} else {
    Say "保留全局 dsh 包（如需卸载请加 -RemoveGlobalDsh）" 'DarkGray'
}

# 4) 还原 npm 配置
$npmrc = Join-Path $env:USERPROFILE '.npmrc'
$bak = "$npmrc.dsh-bak"
if ($RestoreNpmrc -and (Test-Path -LiteralPath $bak)) {
    Copy-Item -LiteralPath $bak -Destination $npmrc -Force
    Say "已用备份还原 .npmrc" 'Green'
}

# 5) 删除「已部署的程序目录」（脚本自身在里面，用临时 cmd 延迟删除）
if (Test-Path -LiteralPath $appDir) {
    if (Confirm-Step "删除程序目录 $appDir ？（快捷方式会随之失效）") {
        $tmp = Join-Path $env:TEMP ("dsh-uninstall-{0}.cmd" -f (Get-Random))
        $content = "@echo off`r`ntimeout /t 2 /nobreak >nul`r`nrmdir /s /q `"$appDir`"`r`ndel `"%~f0`""
        Set-Content -LiteralPath $tmp -Value $content -Encoding ASCII
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $tmp) -WindowStyle Hidden | Out-Null
        Say "程序目录将在后台删除：$appDir" 'Green'
    } else { Say "跳过删除程序目录" 'Yellow' }
}

# 6) 安装根目录若已空（除数据外），提示可手工删除
if ($dataRoot -ne $appDir -and (Test-Path -LiteralPath $dataRoot)) {
    Say "保留数据/缓存目录：$dataRoot（里面是会话、浏览器配置、Node 缓存等）" 'DarkGray'
}

Write-Host ""
Say "卸载流程结束。" 'Cyan'
exit 0
