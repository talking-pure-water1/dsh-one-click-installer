# 验收 9：应用模式（app 窗口）—— 必须能探测到浏览器、模式开关正确
$Root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $Root 'launcher\start-dsh.ps1'

$a = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps -ProbeBrowser 2>&1 | Out-String
$b = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps -ProbeBrowser -NoAppMode 2>&1 | Out-String

$problems = @()
if ($a -notmatch 'appMode=True') { $problems += "默认未启用应用模式" }
if ($b -notmatch 'appMode=False') { $problems += "-NoAppMode 未生效" }
if ($a -notmatch 'browser=(\S+)') {
    $problems += "没有报告浏览器探测结果"
} else {
    $name = $Matches[1]
    if ($name -eq 'none') {
        Write-Host "      （本机未找到 Edge/Chrome/Brave/Vivaldi，将退回普通标签页——不算失败）" -ForegroundColor DarkGray
    } else {
        if ($a -notmatch 'path="([^"]*)"') { $problems += "没有给出浏览器路径" }
        else {
            $path = $Matches[1]
            if ($path -eq '' -or -not (Test-Path -LiteralPath $path)) { $problems += "报告的浏览器路径不存在：$path" }
            else { Write-Host "      探测到浏览器：$name（$path）" -ForegroundColor DarkGray }
        }
    }
}

if ($problems.Count -eq 0) {
    Write-Host "PASS 应用模式：浏览器探测正常，app 开关可开可关" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL 应用模式：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    exit 1
}
