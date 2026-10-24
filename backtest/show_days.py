"""按天打印 H1 的高低收，帮助确定网格区间。
用法：python -I show_days.py <csv> <起始日 yyyy-mm-dd> <结束日 yyyy-mm-dd>
"""
import csv
import sys
from datetime import datetime

path, d0, d1 = sys.argv[1], sys.argv[2], sys.argv[3]
start = datetime.strptime(d0, "%Y-%m-%d")
end = datetime.strptime(d1, "%Y-%m-%d")
days = {}
with open(path, newline="", encoding="ascii") as f:
    for r in csv.DictReader(f):
        t = datetime.strptime(r["time"], "%Y.%m.%d %H:%M")
        if start <= t < end:
            days.setdefault(t.date(), []).append((t, float(r["high"]), float(r["low"]), float(r["close"])))
for d in sorted(days):
    bars = days[d]
    hi = max(b[1] for b in bars)
    lo = min(b[2] for b in bars)
    closes = " ".join(f"{b[3]:.0f}" for b in bars[::3])   # 每 3 小时一个收盘价
    print(f"{d} {d:%a} hi {hi:8.2f} lo {lo:8.2f} | closes/3h: {closes}")
