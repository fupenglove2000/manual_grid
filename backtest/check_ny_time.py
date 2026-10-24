"""核对 GridEA 实盘用的纽约时间换算（测试器里测不到）。
把 EA 里的 NthSunday / IsUsDstGmt / IsUsDstNy / ServerToNY / NYToServer / LastFridayNY / InWeekendBlock
一比一移植过来，和 Python 的 zoneinfo（America/New_York）对比 2025～2032 年。
假设服务器时间 = 纽约 + 7 小时（FTMO：美国冬令时 GMT+2、夏令时 GMT+3），EA 实盘用 TimeTradeServer()-TimeGMT() 得到当时的偏移。
用法：python -I check_ny_time.py <输出文件>
"""
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

NY = ZoneInfo("America/New_York")
H = 3600


def to_ts(dt):  # 朴素时间 → 秒（和 MQL5 datetime 一样不带时区）
    return int((dt - datetime(1970, 1, 1)).total_seconds())


def from_ts(ts):
    return datetime(1970, 1, 1) + timedelta(seconds=ts)


def nth_sunday(year, month, nth):
    d = datetime(year, month, 1)
    dow = (d.weekday() + 1) % 7          # MQL5：0 = 周日
    add = (7 - dow) % 7 + 7 * (nth - 1)
    return to_ts(d) + add * 86400


def is_us_dst_gmt(gmt):
    y = from_ts(gmt).year
    return nth_sunday(y, 3, 2) + 7 * H <= gmt < nth_sunday(y, 11, 1) + 6 * H


def is_us_dst_ny(ny):
    y = from_ts(ny).year
    return nth_sunday(y, 3, 2) + 2 * H <= ny < nth_sunday(y, 11, 1) + 2 * H


def server_to_ny(srv, off):
    gmt = srv - off
    return gmt + (-4 * H if is_us_dst_gmt(gmt) else -5 * H)


def ny_to_server(ny, off):
    return ny - (-4 * H if is_us_dst_ny(ny) else -5 * H) + off


def sec_of_day(t):
    d = from_ts(t)
    return d.hour * H + d.minute * 60 + d.second


def last_friday_ny(ny, hour):
    dow = (from_ts(ny).weekday() + 1) % 7
    day0 = ny - sec_of_day(ny)
    back = (dow - 5 + 7) % 7
    fri = day0 - back * 86400 + hour * H
    if fri > ny:
        fri -= 7 * 86400
    return fri


def in_weekend_block(srv, off, hour):
    ny = server_to_ny(srv, off)
    fri = last_friday_ny(ny, hour)
    sun_open = fri - hour * H + 2 * 86400 + 18 * H
    return fri <= ny < sun_open


def true_ny(gmt_ts):
    return datetime.fromtimestamp(gmt_ts, timezone.utc).astimezone(NY).replace(tzinfo=None)


def server_offset(gmt_ts):  # 服务器 = 纽约 + 7 小时
    ny = true_ny(gmt_ts)
    return to_ts(ny) + 7 * H - gmt_ts


bad = []
checked = 0
start = datetime(2025, 1, 1, tzinfo=timezone.utc).timestamp()
end = datetime(2033, 1, 1, tzinfo=timezone.utc).timestamp()
g = int(start)
while g < end:                                  # 每 15 分钟一个点
    off = server_offset(g)
    srv = g + off
    ny_ea = from_ts(server_to_ny(srv, off))
    ny_ok = true_ny(g)
    if ny_ea != ny_ok:
        bad.append(f"ServerToNY 错：GMT {from_ts(g)} EA {ny_ea} 正确 {ny_ok}")
    checked += 1
    g += 900
# 每个周五 8:00 纽约 → 服务器时间（EA 的 NYToServer）应为纽约 + 7 小时；周末窗口判断
fridays = 0
d = datetime(2025, 1, 3)
while d.year < 2033:
    ny_fri = d.replace(hour=8)
    gmt = int(ny_fri.replace(tzinfo=NY).timestamp())
    off = server_offset(gmt)
    srv_ea = from_ts(ny_to_server(to_ts(ny_fri), off))
    if srv_ea != ny_fri + timedelta(hours=7):
        bad.append(f"NYToServer 错：纽约 {ny_fri} EA {srv_ea} 应为 {ny_fri + timedelta(hours=7)}")
    for delta, expect in ((-60, False), (0, True), (60, True)):          # 周五 8:00 前一分钟 / 当时 / 后一分钟
        g2 = gmt + delta
        o2 = server_offset(g2)
        if in_weekend_block(g2 + o2, o2, 8) != expect:
            bad.append(f"周末窗口错：纽约 {true_ny(g2)} 应为 {expect}")
    sun_open = ny_fri + timedelta(days=2, hours=10)                       # 周日 18:00
    for delta, expect in ((-60, True), (0, False)):
        g3 = int(sun_open.replace(tzinfo=NY).timestamp()) + delta
        o3 = server_offset(g3)
        if in_weekend_block(g3 + o3, o3, 8) != expect:
            bad.append(f"周日开盘边界错：纽约 {true_ny(g3)} 应为 {expect}")
    fridays += 1
    d += timedelta(days=7)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(f"ServerToNY 检查 {checked} 个时间点（2025～2032，每 15 分钟），周五平仓/周末窗口检查 {fridays} 个周五\n")
    f.write(f"错误 {len(bad)} 处\n")
    for b in bad[:50]:
        f.write(b + "\n")
