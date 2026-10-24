"""汇总日志里的“额度不足暂缓”：每一段连续暂缓只取第一条，再找这一格之后的实际补挂时间。
用法：python -I defer_summary.py <agent.log> <输出文件>
"""
import re
import sys
from datetime import datetime, timedelta

re_ts = re.compile(r"(\d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d)\s+(.*)$")
re_defer = re.compile(r"交易思路额度不足，G(\d+) 暂缓补挂：(.*)$")
re_place = re.compile(r"挂单 G(\d+)（.*?） 成功 #(\d+)")
re_tp = re.compile(r"止盈 G(\d+) @([\d.]+)")
episodes, places, tps, last_seen = [], [], [], {}
with open(sys.argv[1], encoding="utf-8-sig", errors="replace") as f:
    for raw in f:
        p = raw.rstrip("\r\n").split("\t")
        if len(p) < 5:
            continue
        m = re_ts.search(p[4])
        if not m:
            continue
        t = datetime.strptime(m.group(1), "%Y.%m.%d %H:%M:%S")
        msg = m.group(2)
        d = re_defer.search(msg)
        if d:
            k = int(d.group(1))
            if k not in last_seen or t - last_seen[k] > timedelta(seconds=5):
                episodes.append((t, k, d.group(2), 0))
            last_seen[k] = t
            episodes[-1] = episodes[-1][:3] + (episodes[-1][3] + 1,) if episodes and episodes[-1][1] == k else episodes[-1]
            continue
        pl = re_place.search(msg)
        if pl:
            places.append((t, int(pl.group(1))))
        tp = re_tp.search(msg)
        if tp:
            tps.append((t, int(tp.group(1))))
with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write(f"暂缓段数 {len(episodes)}\n")
    for (t, k, text, cnt) in episodes:
        prev_tp = max((x for x in tps if x[1] == k and x[0] <= t), default=None)
        nxt = next((pt for (pt, pk) in places if pk == k and pt > t), None)
        out.write(f"{t} G{k}（这一格上次止盈 {prev_tp[0] if prev_tp else '-'}，本段日志 {cnt} 行）\n    {text}\n    实际补挂：{nxt}\n")
