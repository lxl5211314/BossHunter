# -*- coding: utf-8 -*-
"""自动确认并投递：把评分达标、状态为 ready 的岗位按分数从高到低
提交给工作台的 /api/workbench/deliver 接口（等价于人工勾选后点“确认投递”）。

只投 BOSS 平台、只投校招/应届池（采集阶段已过滤），每日上限读 throttle.daily_limit。
用法：python scripts/auto_deliver.py [--max N] [--threshold X] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "bosshunter.db"
CONFIG = ROOT / "config.yaml"
API = "http://127.0.0.1:8686/api/workbench/deliver"

COMPLETED = ("sent", "replied", "resume_sent", "needs_resume", "follow_up_sent")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max", type=int, default=0, help="本次最多投递数，0=按每日剩余额度")
    ap.add_argument("--threshold", type=float, default=-1, help="覆盖评分门槛")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cfg = yaml.safe_load(CONFIG.read_text(encoding="utf-8")) or {}
    throttle = cfg.get("throttle") or {}
    daily_limit = int(throttle.get("daily_limit") or 60)
    threshold = float(
        args.threshold
        if args.threshold >= 0
        else (cfg.get("scoring") or {}).get("threshold", 70)
    )

    db = sqlite3.connect(DB)
    db.row_factory = sqlite3.Row
    sent_today = db.execute(
        "SELECT COUNT(*) n FROM jobs WHERE deleted_at IS NULL "
        "AND status IN (%s) AND date(updated_at,'localtime')=date('now','localtime')"
        % ",".join("?" * len(COMPLETED)),
        COMPLETED,
    ).fetchone()["n"]
    remaining = daily_limit - sent_today
    print(f"今日已投 {sent_today} / 上限 {daily_limit}，剩余 {remaining}（评分门槛 {threshold:g}）")
    if remaining <= 0:
        print("今日额度已用完，跳过")
        return 0
    quota = remaining if args.max <= 0 else min(args.max, remaining)

    rows = db.execute(
        "SELECT substr(id,1,18) sid, id, score, company, title, salary FROM jobs "
        "WHERE deleted_at IS NULL AND status='ready' AND score >= ? "
        "ORDER BY score DESC LIMIT ?",
        (threshold, quota),
    ).fetchall()
    if not rows:
        print("没有可投递的 ready 岗位")
        return 0

    print(f"准备投递 {len(rows)} 个岗位：")
    for r in rows:
        print(f"  {r['score']:>3}  {r['company']} | {r['title']} | {r['salary']}")

    if args.dry_run:
        print("dry-run，不发送")
        return 0

    payload = json.dumps(
        {"job_ids": [r["id"] for r in rows], "direct_send": False},
        ensure_ascii=False,
    ).encode("utf-8")
    req = urllib.request.Request(
        API, data=payload, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", "replace")
            print(f"HTTP {resp.status}: {body[:800]}")
            return 0
    except Exception as exc:  # noqa: BLE001
        detail = ""
        if hasattr(exc, "read"):
            detail = exc.read().decode("utf-8", "replace")
        print(f"投递请求失败: {exc} {detail}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
