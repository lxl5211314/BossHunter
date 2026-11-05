# BossHunter 每日自动任务：采集 -> 评分 -> 自动确认投递
# Windows 计划任务 BossHunter-DailyMorning 每天 09:00 调用。
# 只投 BOSS 平台、只投校招/应届池（采集过滤在 config.yaml 的 search.filters）。
# 自动投递数量 = throttle.daily_limit - 今日已投，评分门槛 = scoring.threshold。

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
$Log = Join-Path $LogDir ("daily_" + $Today + ".log")
$DoneFlag = Join-Path $LogDir ("daily_done_" + $Today + ".flag")

function Write-Log([string]$Message) {
    $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Message
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

function Test-Port([int]$Port) {
    return (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)
}

if (Test-Path -LiteralPath $DoneFlag) {
    Write-Log "今日任务已完成（存在标记文件），跳过"
    exit 0
}

Write-Log "===== 每日采集+评分+自动投递开始 ====="

# 1) 确保专用 Chrome 的 CDP 9222 在线
if (-not (Test-Port 9222)) {
    Write-Log "Chrome 9222 未监听，尝试拉起专用 Chrome"
    if (Test-Path -LiteralPath $Chrome) {
        Start-Process -FilePath $Chrome -ArgumentList @(
            "--remote-debugging-port=9222",
            "--user-data-dir=$ChromeProfile",
            "https://www.zhipin.com/web/geek/jobs"
        )
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-Port 9222) { break }
        }
    } else {
        Write-Log "找不到 Chrome: $Chrome"
    }
} else {
    Write-Log "Chrome 9222 已在监听"
}

# 2) 确保运行时(3456)和工作台(8686)在线
& $Python -m bosshunter.main connect 2>&1 | Out-File -LiteralPath $Log -Append -Encoding utf8
if ($LASTEXITCODE -ne 0) { Write-Log "connect 退出码 $LASTEXITCODE" }

# 8686 允许多进程同时监听，残留实例会让「页面查 A、任务跑在 B」，先清干净再起一个
$webProcs = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -like '*bosshunter.main web*' })
if ($webProcs.Count -gt 0) {
    Write-Log ("清理已有工作台进程：" + (($webProcs | ForEach-Object { $_.ProcessId }) -join ','))
    $webProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
}
Write-Log "启动工作台 8686"
Start-Process -FilePath $Python -ArgumentList @("-m", "bosshunter.main", "web", "--no-open") -WorkingDirectory $RepoRoot -WindowStyle Hidden
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 1000
    if (Test-Port 8686) { break }
}
if (-not (Test-Port 8686)) {
    Write-Log "工作台启动失败，本次任务结束"
    exit 1
}

# 3) 采集（关键词/城市/校招过滤全部来自 config.yaml）
Write-Log "开始采集"
& $Python -m bosshunter.main scrape 2>&1 | Out-File -LiteralPath $Log -Append -Encoding utf8
$scrapeCode = $LASTEXITCODE
Write-Log "采集结束，退出码 $scrapeCode"

# 4) AI 评分
Write-Log "开始评分"
& $Python -m bosshunter.main score 2>&1 | Out-File -LiteralPath $Log -Append -Encoding utf8
$scoreCode = $LASTEXITCODE
Write-Log "评分结束，退出码 $scoreCode"

# 5) 自动确认 + 投递（等价于人工勾选后确认）
Write-Log "开始自动投递"
& $Python (Join-Path $RepoRoot "scripts\auto_deliver.py") --max 40 2>&1 | Out-File -LiteralPath $Log -Append -Encoding utf8
$deliverCode = $LASTEXITCODE
Write-Log "自动投递结束，退出码 $deliverCode"

# 6) 记录额度（投递在 web 进程里异步执行，这里只确认任务已提交）
try {
    $wb = Invoke-RestMethod http://127.0.0.1:8686/api/workbench -TimeoutSec 10
    Write-Log ("投递任务 task=" + $wb.task.id + " status=" + $wb.task.status + " 今日已投=" + $wb.send_quota.sent + "/" + $wb.send_quota.daily_limit)
} catch {
    Write-Log ("读取工作台状态失败：" + $_.Exception.Message)
}

if ($scoreCode -eq 0 -and $deliverCode -eq 0) {
    Set-Content -LiteralPath $DoneFlag -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8
    Write-Log "===== 每日任务完成 ====="
    exit 0
}

Write-Log "===== 每日任务有步骤失败，未写完成标记（计划任务会自动重试） ====="
exit 1
