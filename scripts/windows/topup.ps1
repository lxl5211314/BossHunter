# BossHunter 当日补投：21:45 检查今日是否投满，没投满就再补一轮
# 计划任务 BossHunter-TopUp 每天 21:45 调用。

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = "D:\aaa_boss"
$Python = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$LogDir = Join-Path $RepoRoot "data\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir ("topup_" + (Get-Date -Format "yyyyMMdd") + ".log")

function Write-Log([string]$Message) {
    $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Message
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

function Test-Port([int]$Port) {
    return (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)
}

if (-not (Test-Port 8686)) {
    Write-Log "工作台未监听，启动 web"
    Start-Process -FilePath $Python -ArgumentList @("-m", "bosshunter.main", "web", "--no-open") -WorkingDirectory $RepoRoot -WindowStyle Hidden
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 1000
        if (Test-Port 8686) { break }
    }
}
if (-not (Test-Port 8686)) {
    Write-Log "工作台启动失败，退出"
    exit 1
}

try {
    $wb = Invoke-RestMethod http://127.0.0.1:8686/api/workbench -TimeoutSec 10
} catch {
    Write-Log ("读取工作台失败：" + $_.Exception.Message)
    exit 1
}

if ($wb.task -and $wb.task.status -eq "running") {
    Write-Log ("已有投递任务在跑（" + $wb.task.id + "），跳过补投")
    exit 0
}

$sent = [int]$wb.send_quota.sent
$limit = [int]$wb.send_quota.daily_limit
$remaining = [int]$wb.send_quota.remaining
Write-Log ("当前 " + $sent + "/" + $limit + "，剩余额度 " + $remaining)

if ($remaining -le 0) {
    Write-Log "今日额度已满"
    exit 0
}

& $Python (Join-Path $RepoRoot "scripts\auto_deliver.py") 2>&1 | Out-File -LiteralPath $Log -Append -Encoding utf8
Write-Log ("补投执行结束，退出码 " + $LASTEXITCODE)
exit 0
