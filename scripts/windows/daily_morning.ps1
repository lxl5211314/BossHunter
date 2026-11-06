# BossHunter 每日自动任务：采集 -> 评分 -> 自动确认投递
# 由 Windows 计划任务 BossHunter-DailyMorning 每天 09:00 调用。
# 关键：整个链路用「分离进程」跑 scripts\run_daily.py，本脚本自己很快退出，
#       因此即使计划任务控制台被系统杀掉（历史 0xC000013A），链路仍继续跑完。
# 只投 BOSS 平台、只投校招/应届池（采集阶段已按 config.yaml search.filters 过滤）。
# 自动投递上限 = 剩余额度（throttle.daily_limit - 今日已投），上午取 --max 40。

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
    Write-Log "今日任务已完成，退出（完成标记存在）"
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

# 2) 确保 Browser Runtime(3456) 与工作台(8686) 在线
& $Python -m bosshunter.main connect 2>&1 | Out-File -LiteralPath $Log -Append -Encoding utf8
if ($LASTEXITCODE -ne 0) { Write-Log "connect 退出码 $LASTEXITCODE" }

# 8686：若有历史 web 实例，全部清理后单实例启动（避免双实例导致任务/页面不同步）
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
    Write-Log "工作台启动失败，退出（计划任务将重试）"
    exit 1
}

# 3) 关键改动：以分离进程启动整条链路（采集->评分->自动投递），
#    本 PowerShell 随即退出，避免控制台被杀连累链路。
Write-Log "以分离进程启动 run_daily.py（采集->评分->自动投递 max=40）"
Start-Process -FilePath $Python -ArgumentList @(Join-Path $RepoRoot "scripts\run_daily.py", "--max", "40") -WorkingDirectory $RepoRoot -WindowStyle Hidden

# 4) 短暂等待后读取工作台状态，记录任务 id（投递是异步的，此处只确认已提交）
Start-Sleep -Seconds 20
try {
    $wb = Invoke-RestMethod http://127.0.0.1:8686/api/workbench -TimeoutSec 10
    $taskId = $wb.task.id
    $taskStatus = $wb.task.status
    $sent = $wb.send_quota.sent
    $limit = $wb.send_quota.daily_limit
    Write-Log ("投递已提交 task=" + $taskId + " status=" + $taskStatus + " 今日已投=" + $sent + "/" + $limit)
} catch {
    Write-Log ("读取工作台状态失败：" + $_.Exception.Message)
}

# 5) 不写完成标记（链路在 run_daily.py 里自管）；让计划任务正常退出。
Write-Log "===== 调度完成（run_daily.py 继续后台运行）====="
exit 0
