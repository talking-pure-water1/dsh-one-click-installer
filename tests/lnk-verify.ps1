# .lnk 校验小工具（t5 / t11 共用，点源引入）
#
# 为什么不用 WScript.Shell 回读：
#   WScript.Shell 的 CreateShortcut / Save 全程走系统 ANSI 代码页。在非中文系统（如 en-US /
#   代码页 1252）上，含中文的路径会被压成 "??????"：
#     - Save()  → 报 "Unable to save shortcut"
#     - 读取时  → 根本找不到该文件，却**不报错**，只返回一个各属性全空的空壳对象
#   （产品侧已经规避了写入问题：先存成纯 ASCII 临时名，再用 Move-Item 改成真名。
#     但「读」这一侧没法绕，所以校验改成直接解析 .lnk 文件内容。）
#
# .lnk 里的目标路径、参数、工作目录、图标等字符串都以 UTF-16LE 存放，还可能有 ANSI 副本，
# 两种都扫一遍即可，与系统代码页无关。

function Get-LnkRawText {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [PSCustomObject]@{
        Size    = $bytes.Length
        Unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
        Ansi    = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
    }
}

function Test-LnkContains {
    param(
        [Parameter(Mandatory = $true)]$Lnk,
        [Parameter(Mandatory = $true)][string]$Needle
    )
    if ($null -eq $Lnk) { return $false }
    $opt = [System.StringComparison]::OrdinalIgnoreCase
    return (($Lnk.Unicode.IndexOf($Needle, $opt) -ge 0) -or ($Lnk.Ansi.IndexOf($Needle, $opt) -ge 0))
}

# 列出桌面/开始菜单里指向 DSH 启动器的快捷方式（同样不依赖 COM 读取）
function Get-DshShortcuts {
    param([string]$Desktop = '')
    if ($Desktop -eq '') { $Desktop = [Environment]::GetFolderPath('Desktop') }
    $found = @()
    foreach ($d in @($Desktop, (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.lnk -ErrorAction SilentlyContinue)) {
            try {
                if (Test-LnkContains (Get-LnkRawText -Path $f.FullName) 'start-dsh.ps1') { $found += $f.FullName }
            } catch { }
        }
    }
    return $found
}
