"""分析 GridEA 回测的测试代理日志（backtest/logs/<场景>/agent.log），逐项检查逻辑。
用法：python -I analyze_log.py <agent.log> [初始余额] [总风险%] [上限%]
检查项：
  1. 同一条开仓线任何时刻最多一张单（挂单或持仓）
  2. 每张挂单的开仓价 / 止盈 / 止损 / 手数和设计一致（按开网格推送里的区间、格数、止损独立计算）
  3. 每次挂单时 EA 记录的交易思路“已用风险”和按时间线独立重算的值一致；暂缓与恢复
  4. 停止（硬止损 / 周五平仓等）之后不再挂单，挂单都撤、该平的都平
  5. 周五平仓时间换算成纽约时间（测试器里服务器 = 纽约 + 7 小时）
  6. 每日请求次数；错误和重试
"""
import math
import re
import sys
from datetime import datetime, timedelta

ARGS = [a for a in sys.argv[1:] if not a.startswith("--out=")]
OUT = next((a[6:] for a in sys.argv[1:] if a.startswith("--out=")), None)   # --out=文件：结果追加写入（UTF-8）
LOG = ARGS[0]
INIT_BAL = float(ARGS[1]) if len(ARGS) > 1 else 100000.0
RISK_PCT = float(ARGS[2]) if len(ARGS) > 2 else 0.5
CAP_PCT = float(ARGS[3]) if len(ARGS) > 3 else 0.95
_out_lines = []


def print(*a):  # noqa: A001  —— 收集输出，最后一起写文件
    _out_lines.append(" ".join(str(x) for x in a))
CONTRACT = 100.0
WINDOW = timedelta(minutes=61)

TS = r"(\d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d)"
re_line = re.compile(TS + r"\s+(.*)$")
re_open = re.compile(r"开网格 (做多|做空) ([\d.]+)-([\d.]+) .*?｜(\d+)格.*?止损([\d.]+)｜(.*?)｜")
re_place_trade = re.compile(r"^(buy|sell) limit ([\d.]+) XAUUSD at ([\d.]+) sl: ([\d.]+) tp: ([\d.]+)")
re_place_ea = re.compile(r"^挂单 G(\d+)（.*?） 成功 #(\d+)")
re_ledger = re.compile(r"交易思路：已用 ([\d.]+)（平仓 ([\d.]+) \+ 持仓 ([\d.]+) \+ 挂单 ([\d.]+)）\+ 本单 ([\d.]+) = ([\d.]+) ≤ 上限 ([\d.]+)")
re_trig = re.compile(r"^order \[#(\d+) (buy|sell) limit")
re_deal_in = re.compile(r"^deal #\d+ (buy|sell) ([\d.]+) XAUUSD at ([\d.]+) done \(based on order #(\d+)\)")
re_tp = re.compile(r"^take profit triggered #(\d+)")
re_sl = re.compile(r"^stop loss triggered #(\d+)")
re_close = re.compile(r"^market (buy|sell) ([\d.]+) XAUUSD, close #(\d+)")
re_cancel = re.compile(r"^order canceled \[#(\d+)")
re_defer = re.compile(r"交易思路额度不足，G(\d+) 暂缓补挂：已用 ([\d.]+).*?本单 ([\d.]+) = ([\d.]+) > 上限 ([\d.]+)；(.*)$")
re_eta = re.compile(r"预计服务器时间 (\d\d:\d\d)")
re_stop = re.compile(r"^网格停止 —— (.*)$")
re_stat = re.compile(r"【统计】服务器日 (\S+) (?:截至目前)?交易请求 (\d+) 次")


def parse_time(s):
    return datetime.strptime(s, "%Y.%m.%d %H:%M:%S")


events = []
with open(LOG, encoding="utf-8-sig", errors="replace") as f:
    for raw in f:
        parts = raw.rstrip("\r\n").split("\t")
        if len(parts) < 5:
            continue
        m = re_line.search(parts[4])
        if m:
            events.append((parse_time(m.group(1)), m.group(2).strip(), parts[3]))

problems = []
notes = []
grid = None
pending_place = None           # 测试器的 "buy limit ..." 行，等下一行 EA 的 "挂单 Gk" 对上
items = {}                     # ticket -> dict(line, kind order/pos, price, vol, sl, open_t)
closed = []                    # (close_t, risk)
line_occ = {}                  # line -> set(tickets)
placements = []
deferrals = []
stop_t = None
stop_reason = None
stats = []
errors = []
max_used = 0.0


def risk_of(is_long, price, sl, vol):
    return max(0.0, (price - sl) if is_long else (sl - price)) * CONTRACT * vol


def ledger_at(t):
    c = sum(r for (ct, r) in closed if t - ct < WINDOW)
    p = sum(risk_of(grid["long"], it["price"], it["sl"], it["vol"]) for it in items.values() if it["kind"] == "pos")
    o = sum(risk_of(grid["long"], it["price"], it["sl"], it["vol"]) for it in items.values() if it["kind"] == "order")
    return c, p, o


def remove_item(tk, t, as_close):
    it = items.pop(tk, None)
    if it is None:
        return
    line_occ.get(it["line"], set()).discard(tk)
    if as_close and it["kind"] == "pos":
        closed.append((t, risk_of(grid["long"], it["price"], it["sl"], it["vol"])))


for (t, msg, src) in events:
    if "error" in msg.lower() or "failed" in msg.lower() or "失败" in msg or "暂缓（" in msg:
        errors.append(f"{t} {msg}")
    m = re_open.search(msg)
    if m:
        is_long = m.group(1) == "做多"
        lo, hi, n, sl = float(m.group(2)), float(m.group(3)), int(m.group(4)), float(m.group(5))
        lots = {int(a): float(b) for a, b in re.findall(r"G(\d+) ([\d.]+)", m.group(6))}
        step = (hi - lo) / n
        lines = [round(lo + k * step, 2) for k in range(n + 1)]
        lines[n] = hi
        kfrom, kto = (0, n - 1) if is_long else (1, n)
        risk_each = INIT_BAL * RISK_PCT / 100.0 / n
        exp_lots = {}
        for k in range(kfrom, kto + 1):
            per_lot = abs(lines[k] - sl) * CONTRACT
            exp_lots[k] = math.floor(risk_each / per_lot / 0.01 + 1e-7) * 0.01
        grid = dict(long=is_long, lo=lo, hi=hi, n=n, sl=sl, lines=lines, kfrom=kfrom, kto=kto, lots=lots)
        for k in exp_lots:
            if abs(exp_lots[k] - lots.get(k, -1)) > 1e-9:
                problems.append(f"手数与公式不符 G{k}: EA {lots.get(k)} 公式 {exp_lots[k]:.2f}")
        notes.append(f"开网格 {t}：{'做多' if is_long else '做空'} {lo}-{hi} {n}格 格距{step:.2f} 止损{sl} 手数{lots}（公式 {exp_lots}）")
        continue
    m = re_place_trade.match(msg)
    if m and src == "Trade":
        pending_place = (m.group(1), float(m.group(2)), float(m.group(3)), float(m.group(4)), float(m.group(5)))
        continue
    m = re_place_ea.match(msg)
    if m:
        k, tk = int(m.group(1)), int(m.group(2))
        if stop_t is not None:
            problems.append(f"{t} 停止后仍挂单 G{k}")
        if pending_place is None:
            problems.append(f"{t} 找不到 G{k} 对应的下单行")
            continue
        side, vol, price, sl, tp = pending_place
        pending_place = None
        exp_tp = grid["lines"][k + 1] if grid["long"] else grid["lines"][k - 1]
        bad = []
        if (side == "buy") != grid["long"]:
            bad.append("方向")
        if abs(price - grid["lines"][k]) > 0.005:
            bad.append(f"开仓价 {price} != {grid['lines'][k]}")
        if abs(tp - exp_tp) > 0.005:
            bad.append(f"止盈 {tp} != {exp_tp}")
        if abs(sl - grid["sl"]) > 0.005:
            bad.append(f"止损 {sl} != {grid['sl']}")
        if abs(vol - grid["lots"][k]) > 1e-9:
            bad.append(f"手数 {vol} != {grid['lots'][k]}")
        if bad:
            problems.append(f"{t} G{k} 参数不符：{', '.join(bad)}")
        occ = line_occ.setdefault(k, set())
        if occ:
            problems.append(f"{t} G{k} 已有单 {sorted(occ)} 时又挂了 #{tk}")
        occ.add(tk)
        items[tk] = dict(line=k, kind="order", price=price, vol=vol, sl=sl, open_t=t)
        placements.append((t, k, tk))
        continue
    m = re_ledger.search(msg)
    if m:
        used, c, p, o, r, tot, cap = map(float, m.groups())
        # EA 在挂单前计算（挂单已记入 items），所以重算时去掉刚挂的这张
        last_t, last_k, last_tk = placements[-1]
        it = items[last_tk]
        c2, p2, o2 = ledger_at(t)
        o2 -= risk_of(grid["long"], it["price"], it["sl"], it["vol"])
        if abs(c - c2) > 0.05 or abs(p - p2) > 0.05 or abs(o - o2) > 0.05:
            problems.append(f"{t} 账本不符 G{last_k}：EA 平仓{c}/持仓{p}/挂单{o}，重算 {c2:.2f}/{p2:.2f}/{o2:.2f}")
        exp_cap = INIT_BAL * CAP_PCT / 100.0
        if abs(cap - exp_cap) > 0.01 or tot > cap + 1e-6:
            problems.append(f"{t} 上限不符或超限：合计 {tot} 上限 {cap}")
        max_used = max(max_used, tot)
        continue
    m = re_trig.match(msg)
    if m:
        tk = int(m.group(1))
        if tk in items:
            items[tk]["kind"] = "pos"
        continue
    m = re_deal_in.match(msg)
    if m:
        tk = int(m.group(4))
        if tk in items and items[tk]["kind"] == "pos":
            items[tk]["price"] = float(m.group(3))     # 用实际成交价
        continue
    m = re_tp.match(msg) or re_sl.match(msg)
    if m:
        if msg.startswith("stop loss"):
            notes.append(f"{t} 服务器止损：{msg}")
        remove_item(int(m.group(1)), t, True)
        continue
    m = re_close.match(msg)
    if m:
        remove_item(int(m.group(3)), t, True)
        continue
    m = re_cancel.match(msg)
    if m:
        remove_item(int(m.group(1)), t, False)
        continue
    m = re_defer.search(msg)
    if m:
        eta = re_eta.search(m.group(6))
        deferrals.append((t, int(m.group(1)), float(m.group(4)), float(m.group(5)), eta.group(1) if eta else None))
        continue
    m = re_stop.match(msg)
    if m:
        stop_t, stop_reason = t, m.group(1)
        continue
    m = re_stat.search(msg)
    if m:
        stats.append((m.group(1), int(m.group(2))))

print(f"==== {LOG}")
for n in notes:
    print(n)
print(f"挂单次数 {len(placements)}；交易思路最高合计 {max_used:.2f}")
if deferrals:
    print("暂缓补挂：")
    for (t, k, tot, cap, eta) in deferrals:
        nxt = next(((pt, ptk) for (pt, pk, ptk) in placements if pk == k and pt > t), None)
        print(f"  {t} G{k} 合计 {tot} > {cap}，预计 {eta}；实际补挂 {nxt[0] if nxt else '没有再挂'}")
else:
    print("暂缓补挂：没有发生")
if stop_t:
    ny = stop_t - timedelta(hours=7)
    print(f"停止：{stop_t}（纽约 {ny:%Y-%m-%d %a %H:%M:%S}）—— {stop_reason}")
    left = [f"#{tk} G{it['line']} {it['kind']}" for tk, it in items.items()]
    print(f"  停止后剩余：{left if left else '无（挂单全撤、持仓全平或按规则保留）'}")
else:
    print("停止：测试期间没有停止")
print("每日请求：" + "，".join(f"{d} {n} 次" for d, n in stats))
print("报错/重试：" + ("无" if not errors else ""))
for e in errors:
    print("  " + e)
print("问题：" + ("无" if not problems else ""))
for p in problems:
    print("  " + p)
print("")
text = "\n".join(_out_lines) + "\n"
if OUT:
    with open(OUT, "a", encoding="utf-8") as f:
        f.write(text)
else:
    sys.stdout.buffer.write(text.encode("utf-8"))
