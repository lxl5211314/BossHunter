# -*- coding: utf-8 -*-
"""每日一次链路编排：采集 -> 评分 -> 自动确认投递（前 max 份）。

由 scripts/windows/daily_morning.ps1 以「分离进程」方式启动（Start-Process），
因此即使计划任务的 PowerShell 控制台被终止（历史 0xC000013A 问题），
本进程也不受影响，链路继续跑完。也可手动运行：
    .venv/Scripts/python.exe scripts/run_daily.py [--max N] [--only scrape|score|deliver]
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PYTHON = ROOT / ".venv" / "Scripts" / "python.exe"
LOG_DIR = ROOT / "data" / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)


def log(msg: str) -> None:
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line, flush=True)
    with open(LOG_DIR / f"run_daily_{datetime.now():%Y%m%d}.log", "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def run_step(name: str, args: list[str]) -> int:
    log(f"===== {name} 开始 =====")
    cmd = [str(PYTHON), "-m", "bosshunter.main", *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    if out:
        log(out[-3000:])
    if err:
        log(f"[{name} stderr] {err[-1500:]}")
    log(f"===== {name} 结束 exit={proc.returncode} =====")
    return proc.returncode


def deliver(max_n: int) -> int:
    log(f"===== 自动投递 开始 (max={max_n}) =====")
    proc = subprocess.run(
        [str(PYTHON), str(ROOT / "scripts" / "auto_deliver.py"), "--max", str(max_n)],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    out = (proc.stdout or "").strip()
    if out:
        log(out[-3000:])
    log(f"===== 自动投递 结束 exit={proc.returncode} =====")
    return proc.returncode


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max", type=int, default=40, help="上午自动投递上限（默认 40）")
    ap.add_argument("--only", default="", choices=["", "scrape", "score", "deliver"])
    args = ap.parse_args()

    code = 0
    if args.only in ("", "scrape"):
        code = run_step("采集", ["scrape"])
        if code != 0:
            log("采集失败，提前结束（计划任务会重试）")
            return 1
    if args.only in ("", "score"):
        code = run_step("评分", ["score"])
        if code != 0:
            log("评分失败，提前结束")
            return 1
    if args.only in ("", "deliver"):
        code = deliver(args.max)

    if code == 0:
        log("===== 链路全部成功 =====")
    else:
        log(f"===== 链路结束但有非零退出码 {code} =====")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
