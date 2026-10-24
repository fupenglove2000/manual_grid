"""浏览导出的 XAUUSD H1 数据，帮助挑选回测场景。
用法：python -I scan_h1.py <GridEA_XAUUSD_H1.csv>
输出：每周的高低点和波动、ATR(120)、候选的震荡周 / 急跌段。时间都是服务器时间（= 纽约 + 7 小时）。
"""
import csv
import sys
from datetime import datetime


def load(path):
    rows = []
    with open(path, newline="", encoding="ascii") as f:
        for r in csv.DictReader(f):
            rows.append({
                "t": datetime.strptime(r["time"], "%Y.%m.%d %H:%M"),
                "o": float(r["open"]), "h": float(r["high"]),
                "l": float(r["low"]), "c": float(r["close"]),
            })
    return rows


def atr_sma(rows, n=120):
    """MT5 内置 ATR：真实波幅的简单平均"""
    tr = []
    for i, r in enumerate(rows):
        pc = rows[i - 1]["c"] if i else r["o"]
        tr.append(max(r["h"] - r["l"], abs(r["h"] - pc), abs(r["l"] - pc)))
    out = [None] * len(rows)
    s = 0.0
    for i, v in enumerate(tr):
        s += v
        if i >= n:
            s -= tr[i - n]
        if i >= n - 1:
            out[i] = s / n
    return out


def main():
    rows = load(sys.argv[1])
    atr = atr_sma(rows)
    print(f"bars={len(rows)} first={rows[0]['t']} last={rows[-1]['t']}")
    # 按 ISO 周汇总：周一到周五 15:00 前（周五平仓前）的区间、穿越中线次数
    weeks = {}
    for i, r in enumerate(rows):
        y, w, _ = r["t"].isocalendar()
        weeks.setdefault((y, w), []).append(i)
    print("\nweek       start             hi       lo     range  mid-cross  ATR120(start)  fri15close")
    for key in sorted(weeks):
        idx = [i for i in weeks[key] if not (rows[i]["t"].weekday() == 4 and rows[i]["t"].hour >= 15)]
        if len(idx) < 20:
            continue
        hi = max(rows[i]["h"] for i in idx)
        lo = min(rows[i]["l"] for i in idx)
        mid = (hi + lo) / 2
        cross = sum(1 for a, b in zip(idx, idx[1:]) if (rows[a]["c"] - mid) * (rows[b]["c"] - mid) < 0)
        a0 = atr[idx[0]]
        fri = [i for i in weeks[key] if rows[i]["t"].weekday() == 4 and rows[i]["t"].hour == 15]
        fc = rows[fri[0]]["o"] if fri else float("nan")
        print(f"{key[0]}-W{key[1]:02d}  {rows[idx[0]]['t']:%Y-%m-%d %H:%M}  {hi:8.2f} {lo:8.2f} {hi - lo:7.2f}  {cross:5d}"
              f"     {a0 if a0 else float('nan'):8.2f}     {fc:8.2f}")
    # 急跌段：48 小时内从高点下跌超过 150 的位置
    print("\nsharp drops (>150 within 48h):")
    last = None
    for i in range(len(rows)):
        j_end = min(len(rows), i + 48)
        lo = min(rows[j]["l"] for j in range(i, j_end))
        if rows[i]["h"] - lo > 150 and (last is None or (rows[i]["t"] - last).days >= 5):
            jl = min(range(i, j_end), key=lambda j: rows[j]["l"])
            print(f"  from {rows[i]['t']:%Y-%m-%d %H:%M} high {rows[i]['h']:.2f} -> {rows[jl]['t']:%Y-%m-%d %H:%M} low {rows[jl]['l']:.2f}")
            last = rows[i]["t"]


if __name__ == "__main__":
    main()
