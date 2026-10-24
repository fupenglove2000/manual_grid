"""逐小时打印 H1 的开高低收（服务器时间）。
用法：python -I show_hours.py <csv> <起始 yyyy-mm-dd HH> <结束 yyyy-mm-dd HH>
"""
import csv
import sys
from datetime import datetime

path = sys.argv[1]
t0 = datetime.strptime(sys.argv[2], "%Y-%m-%d %H")
t1 = datetime.strptime(sys.argv[3], "%Y-%m-%d %H")
with open(path, newline="", encoding="ascii") as f:
    for r in csv.DictReader(f):
        t = datetime.strptime(r["time"], "%Y.%m.%d %H:%M")
        if t0 <= t <= t1:
            print(f"{t:%m-%d %a %H:%M}  O {float(r['open']):8.2f}  H {float(r['high']):8.2f}  "
                  f"L {float(r['low']):8.2f}  C {float(r['close']):8.2f}")
