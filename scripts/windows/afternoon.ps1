# BossHunter 下午投递：13:30 起把当天剩余额度里最多 20 份发出去
# 不重复采集/评分，只做投递；由计划任务 BossHunter-Afternoon 每天 13:30 触发
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = "D:\aaa_boss"
$Python = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$Chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$ChromeProfile = Join-Path $env:LOCALAPPDATA "BossHunterChrome"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$LogDir = Join-Path $RepoRoot "data\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Today = Get-Date -Format "yyyyMMdd"
$Log = Join-Path $LogDir ("afternoon_" + $Today + ".log")

function Write-Log([string]$Message) {
    $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Message
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

function Test-Port([int]$Port) {
    return (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)
}

Write-Log "===== 下午投递开始 ====="

if (-not (Test-Port 9222)) {
    Write-Log "Chrome 9222 未监听，尝试启动专用 Chrome"
    if (Test-Path -LiteralPath $Chrome) {
        Start-Process -FilePath $Chrome -ArgumentList @(
            "--remote-debugging-port=9222",
            "--user-data-dir=$ChromeProfile"
        )
        Start-Sleep -Seconds 8
    }
}

if (-not (Test-Port 8686)) {
    Write-Log "工作台未启动，拉起单实例 web"
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -like "*bosshunter.main web*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process -FilePath $Python -ArgumentList "-m","bosshunter.main","web","--no-open" -WorkingDirectory $RepoRoot -WindowStyle Hidden
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Port 8686) { break }
    }
}

if (-not (Test-Port 8686)) {
    Write-Log "工作台启动失败，退出"
    exit 1
}

try {
    $wb = Invoke-RestMethod http://127.0.0.1:8686/api/workbench -TimeoutSec 10
    if ($wb.task -and $wb.task.status -eq "running") {
        Write-Log ("已有投递任务在跑：" + $wb.task.id + "，跳过")
        exit 0
    }
    Write-Log ("当前已投 " + $wb.send_quota.sent + "/" + $wb.send_quota.daily_limit + "，剩余 " + $wb.send_quota.remaining)
    if ($wb.send_quota.remaining -le 0) {
        Write-Log "今日额度已满，跳过"
        exit 0
    }
} catch {
    Write-Log ("读取工作台失败：" + $_.Exception.Message)
}

& $Python (Join-Path $RepoRoot "scripts\auto_deliver.py") --max 20 2>&1 | Out-File -LiteralPath $Log -Append -Encoding utf8
$code = $LASTEXITCODE
Write-Log "下午投递提交结束，退出码 $code"

try {
    $wb2 = Invoke-RestMethod http://127.0.0.1:8686/api/workbench -TimeoutSec 10
    Write-Log ("task=" + $wb2.task.id + " status=" + $wb2.task.status + " 今日已投=" + $wb2.send_quota.sent + "/" + $wb2.send_quota.daily_limit)
} catch {}

exit $code
